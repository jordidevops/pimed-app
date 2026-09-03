/*
  Migració: document_content_blocks
  ─────────────────────────────────
  Sistema de Blocs de Contingut per a plantilles de documents (HTML i DOCX).

  Implementa el mateix patró "plataforma vs tenant" que document_templates:
  - tenant_id IS NULL + is_platform_default = true  → bloc de sistema (llegit per tothom)
  - tenant_id IS NOT NULL + is_platform_default = false → bloc propi del tenant

  Resum de canvis:
  1. Enum data.block_type: PAGE_HEADER, PAGE_FOOTER, DOCUMENT_HEADER, DOCUMENT_FOOTER, CUSTOM
  2. Enum data.block_format: HTML, TEXT
  3. Taula data.document_content_blocks (RLS inclosa)
  4. Columna default_block_mapping JSONB a data.document_templates
  5. Vista api.document_content_blocks
  6. RPCs: api.create_content_block, api.update_content_block,
           api.delete_content_block, api.clone_content_block
  7. Grants service_role
*/

-- =============================================================================
-- 1. Enums
-- =============================================================================

DO $$ BEGIN
  CREATE TYPE data.block_type AS ENUM (
    'PAGE_HEADER',
    'PAGE_FOOTER',
    'DOCUMENT_HEADER',
    'DOCUMENT_FOOTER',
    'CUSTOM'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE data.block_format AS ENUM (
    'HTML',
    'TEXT'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- =============================================================================
-- 2. Taula document_content_blocks
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.document_content_blocks (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid        REFERENCES data.tenants(id) ON DELETE CASCADE,
  name                text        NOT NULL CHECK (length(trim(name)) > 0),
  block_type          data.block_type NOT NULL,
  format              data.block_format NOT NULL DEFAULT 'HTML',
  content             text        NOT NULL DEFAULT '',
  is_platform_default boolean     NOT NULL DEFAULT false,
  cloned_from_id      uuid        REFERENCES data.document_content_blocks(id) ON DELETE SET NULL,
  is_active           boolean     NOT NULL DEFAULT true,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),

  -- XOR: bloc de sistema O bloc de tenant, mai ambdós ni cap
  CONSTRAINT chk_content_block_owner CHECK (
    (tenant_id IS NOT NULL AND is_platform_default = false)
    OR
    (tenant_id IS NULL     AND is_platform_default = true)
  )
);

-- Índexs
CREATE INDEX IF NOT EXISTS idx_content_blocks_tenant
  ON data.document_content_blocks (tenant_id)
  WHERE tenant_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_content_blocks_platform
  ON data.document_content_blocks (block_type, format)
  WHERE is_platform_default = true AND is_active = true;

CREATE INDEX IF NOT EXISTS idx_content_blocks_tenant_type
  ON data.document_content_blocks (tenant_id, block_type)
  WHERE is_active = true;

-- Trigger updated_at
CREATE OR REPLACE FUNCTION data.set_content_block_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_content_block_updated_at ON data.document_content_blocks;
CREATE TRIGGER trg_content_block_updated_at
  BEFORE UPDATE ON data.document_content_blocks
  FOR EACH ROW EXECUTE FUNCTION data.set_content_block_updated_at();

-- =============================================================================
-- 3. RLS per a document_content_blocks
-- =============================================================================

ALTER TABLE data.document_content_blocks ENABLE ROW LEVEL SECURITY;

-- SELECT: blocs de sistema visibles per a tots els autenticats;
--         blocs propis només als membres del tenant.
CREATE POLICY "content_blocks: select"
  ON data.document_content_blocks FOR SELECT TO authenticated
  USING (
    is_platform_default = true
    OR (
      tenant_id IS NOT NULL
      AND data.jwt_user_tenants() ? tenant_id::text
    )
  );

-- INSERT: només blocs propis; cal rol owner o manager global
CREATE POLICY "content_blocks: insert"
  ON data.document_content_blocks FOR INSERT TO authenticated
  WITH CHECK (
    tenant_id IS NOT NULL
    AND data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- UPDATE: només blocs propis; owner o manager
CREATE POLICY "content_blocks: update"
  ON data.document_content_blocks FOR UPDATE TO authenticated
  USING (
    tenant_id IS NOT NULL
    AND data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  )
  WITH CHECK (
    tenant_id IS NOT NULL
    AND data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- DELETE: només blocs propis; owner o manager
CREATE POLICY "content_blocks: delete"
  ON data.document_content_blocks FOR DELETE TO authenticated
  USING (
    tenant_id IS NOT NULL
    AND data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- =============================================================================
-- 4. Columna default_block_mapping a document_templates
-- =============================================================================

ALTER TABLE data.document_templates
  ADD COLUMN IF NOT EXISTS default_block_mapping jsonb NOT NULL DEFAULT '{}';

COMMENT ON COLUMN data.document_templates.default_block_mapping IS
  'Mapejat de tipus de bloc a uuid del bloc seleccionat.
   Estructura: {
     "page_header": "uuid",
     "page_footer": "uuid",
     "document_header": "uuid",
     "document_footer": "uuid",
     "custom_block_<slug>": "uuid"
   }
   La clau ha de coincidir amb el type de bloc en minúscules (PAGE_HEADER → page_header).
   Les claus custom_ son lliures i han de coincidir amb etiquetes {{ custom_block_xxx }}
   dins la plantilla HTML.';

-- =============================================================================
-- 5. Vista api.document_content_blocks
-- =============================================================================

CREATE OR REPLACE VIEW api.document_content_blocks
  WITH (security_invoker = true)
AS
SELECT
  b.id,
  b.tenant_id,
  b.name,
  b.block_type::text     AS block_type,
  b.format::text         AS format,
  b.content,
  b.is_platform_default,
  b.cloned_from_id,
  b.is_active,
  b.created_at,
  b.updated_at
FROM data.document_content_blocks b;

GRANT SELECT ON api.document_content_blocks TO authenticated;
GRANT SELECT ON api.document_content_blocks TO service_role;

-- =============================================================================
-- 6. RPCs
-- =============================================================================

-- ─── 6.1  create_content_block ───────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.create_content_block(
  p_tenant_id    uuid,
  p_name         text,
  p_block_type   text,
  p_format       text    DEFAULT 'HTML',
  p_content      text    DEFAULT '',
  p_is_active    boolean DEFAULT true
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_block data.document_content_blocks%ROWTYPE;
BEGIN
  -- Validació d'accés
  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'Access denied: owner or manager role required';
  END IF;

  INSERT INTO data.document_content_blocks (
    tenant_id, name, block_type, format, content, is_platform_default, is_active
  ) VALUES (
    p_tenant_id,
    p_name,
    p_block_type::data.block_type,
    p_format::data.block_format,
    p_content,
    false,
    p_is_active
  )
  RETURNING * INTO v_block;

  RETURN row_to_json(v_block);
END;
$$;

-- ─── 6.2  update_content_block ───────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.update_content_block(
  p_block_id  uuid,
  p_tenant_id uuid,
  p_name      text    DEFAULT NULL,
  p_content   text    DEFAULT NULL,
  p_is_active boolean DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_block data.document_content_blocks%ROWTYPE;
BEGIN
  -- Validació d'accés
  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'Access denied: owner or manager role required';
  END IF;

  UPDATE data.document_content_blocks
  SET
    name       = COALESCE(p_name, name),
    content    = COALESCE(p_content, content),
    is_active  = COALESCE(p_is_active, is_active),
    updated_at = now()
  WHERE id = p_block_id
    AND tenant_id = p_tenant_id
  RETURNING * INTO v_block;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Content block % not found or not accessible for tenant %', p_block_id, p_tenant_id;
  END IF;

  RETURN row_to_json(v_block);
END;
$$;

-- ─── 6.3  delete_content_block ───────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.delete_content_block(
  p_block_id  uuid,
  p_tenant_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'Access denied: owner or manager role required';
  END IF;

  DELETE FROM data.document_content_blocks
  WHERE id = p_block_id
    AND tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Content block % not found or not accessible for tenant %', p_block_id, p_tenant_id;
  END IF;
END;
$$;

-- ─── 6.4  clone_content_block ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.clone_content_block(
  p_source_block_id uuid,
  p_tenant_id       uuid,
  p_name            text DEFAULT NULL   -- Si NULL, usa 'Còpia de <nom original>'
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_source data.document_content_blocks%ROWTYPE;
  v_new    data.document_content_blocks%ROWTYPE;
  v_name   text;
BEGIN
  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'Access denied: owner or manager role required';
  END IF;

  -- Comprovar que la font és accessible: sistema o del propi tenant
  SELECT * INTO v_source
  FROM data.document_content_blocks
  WHERE id = p_source_block_id
    AND is_active = true
    AND (
      is_platform_default = true
      OR tenant_id = p_tenant_id
    );

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Source block % not found or not accessible', p_source_block_id;
  END IF;

  v_name := COALESCE(p_name, 'Còpia de ' || v_source.name);

  INSERT INTO data.document_content_blocks (
    tenant_id, name, block_type, format, content,
    is_platform_default, cloned_from_id, is_active
  ) VALUES (
    p_tenant_id,
    v_name,
    v_source.block_type,
    v_source.format,
    v_source.content,
    false,
    p_source_block_id,
    true
  )
  RETURNING * INTO v_new;

  RETURN row_to_json(v_new);
END;
$$;

-- ─── 6.5  update_template_block_mapping ─────────────────────────────────────
-- Desa el mapeig de blocs d'una plantilla. Valida que la plantilla pertanyi
-- al tenant i que tots els UUIDs del mapeig existeixin i siguin accessibles.

CREATE OR REPLACE FUNCTION api.update_template_block_mapping(
  p_template_id   uuid,
  p_tenant_id     uuid,
  p_block_mapping jsonb  -- {"page_header": "uuid", "page_footer": "uuid", ...}
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_template  data.document_templates%ROWTYPE;
  v_block_id  uuid;
  v_key       text;
  v_val       text;
BEGIN
  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'Access denied: owner or manager role required';
  END IF;

  -- La plantilla ha de ser del tenant (no es pot mapejar una plantilla de sistema
  -- directament — cal clonar-la primer).
  SELECT * INTO v_template
  FROM data.document_templates
  WHERE id = p_template_id
    AND tenant_id = p_tenant_id
    AND is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Template % not found or not owned by tenant %', p_template_id, p_tenant_id;
  END IF;

  -- Validar que cada UUID del mapeig és accessible (sistema o del propi tenant)
  FOR v_key, v_val IN
    SELECT key, value::text FROM jsonb_each_text(p_block_mapping)
  LOOP
    IF v_val IS NOT NULL AND v_val <> 'null' THEN
      BEGIN
        v_block_id := v_val::uuid;
      EXCEPTION WHEN others THEN
        RAISE EXCEPTION 'Valor invàlid per a la clau %: % no és un UUID vàlid', v_key, v_val;
      END;

      IF NOT EXISTS (
        SELECT 1 FROM data.document_content_blocks
        WHERE id = v_block_id
          AND is_active = true
          AND (is_platform_default = true OR tenant_id = p_tenant_id)
      ) THEN
        RAISE EXCEPTION 'Bloc % (clau: %) no trobat o no accessible per al tenant', v_block_id, v_key;
      END IF;
    END IF;
  END LOOP;

  UPDATE data.document_templates
  SET
    default_block_mapping = p_block_mapping,
    updated_at            = now()
  WHERE id = p_template_id
    AND tenant_id = p_tenant_id
  RETURNING * INTO v_template;

  RETURN row_to_json(v_template);
END;
$$;

-- =============================================================================
-- 7. Grants
-- =============================================================================

GRANT EXECUTE ON FUNCTION api.create_content_block(uuid, text, text, text, text, boolean)
  TO authenticated;
GRANT EXECUTE ON FUNCTION api.update_content_block(uuid, uuid, text, text, boolean)
  TO authenticated;
GRANT EXECUTE ON FUNCTION api.delete_content_block(uuid, uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION api.clone_content_block(uuid, uuid, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION api.update_template_block_mapping(uuid, uuid, jsonb)
  TO authenticated;

GRANT EXECUTE ON FUNCTION api.create_content_block(uuid, text, text, text, text, boolean)
  TO service_role;
GRANT EXECUTE ON FUNCTION api.update_content_block(uuid, uuid, text, text, boolean)
  TO service_role;
GRANT EXECUTE ON FUNCTION api.delete_content_block(uuid, uuid)
  TO service_role;
GRANT EXECUTE ON FUNCTION api.clone_content_block(uuid, uuid, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION api.update_template_block_mapping(uuid, uuid, jsonb)
  TO service_role;

GRANT SELECT, INSERT, UPDATE, DELETE
  ON data.document_content_blocks TO service_role;
