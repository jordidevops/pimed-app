-- CF-29 fase 2: taules de calculadora, columnes d'origen, RPCs publish/apply.
-- La RPC apply_calculator_lines és service_role (D7); l'Edge passa p_actor_user_id.

-- =============================================================================
-- Columnes d'origen a les dues taules de línies
-- =============================================================================
ALTER TABLE data.project_lines
  ADD COLUMN IF NOT EXISTS line_origin text
    CHECK (line_origin IS NULL OR line_origin IN ('manual','habit','calculator','ai_sheet','copy')),
  ADD COLUMN IF NOT EXISTS calculator_definition_id uuid,
  ADD COLUMN IF NOT EXISTS calculator_version_id uuid,
  ADD COLUMN IF NOT EXISTS calculator_line_key text,
  ADD COLUMN IF NOT EXISTS source_run_id uuid;

ALTER TABLE data.commercial_document_lines
  ADD COLUMN IF NOT EXISTS line_origin text
    CHECK (line_origin IS NULL OR line_origin IN ('manual','habit','calculator','ai_sheet','copy')),
  ADD COLUMN IF NOT EXISTS calculator_definition_id uuid,
  ADD COLUMN IF NOT EXISTS calculator_version_id uuid,
  ADD COLUMN IF NOT EXISTS calculator_line_key text,
  ADD COLUMN IF NOT EXISTS source_run_id uuid;

CREATE INDEX IF NOT EXISTS idx_project_lines_calculator_def
  ON data.project_lines (project_id, calculator_definition_id)
  WHERE line_origin = 'calculator';

CREATE INDEX IF NOT EXISTS idx_cdl_calculator_def
  ON data.commercial_document_lines (document_id, calculator_definition_id)
  WHERE line_origin = 'calculator';

-- =============================================================================
-- Catàleg de plataforma
-- =============================================================================
CREATE TABLE IF NOT EXISTS data.calculator_catalog (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug                text NOT NULL UNIQUE,
  target_archetypes   text[] NOT NULL DEFAULT '{}',
  catalog_version     int NOT NULL DEFAULT 1 CHECK (catalog_version > 0),
  definition          jsonb NOT NULL,
  tags                text[] NOT NULL DEFAULT '{}',
  is_active           boolean NOT NULL DEFAULT true,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE data.calculator_catalog IS
  'Biblioteca CF-29 de calculadores de plataforma (sense preus reals).';

ALTER TABLE data.calculator_catalog ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "calculator_catalog: select active" ON data.calculator_catalog;
CREATE POLICY "calculator_catalog: select active"
  ON data.calculator_catalog FOR SELECT TO authenticated
  USING (is_active);

-- Escriptura només service_role / migracions (sense policy INSERT per authenticated)

-- =============================================================================
-- Definicions de tenant
-- =============================================================================
CREATE TABLE IF NOT EXISTS data.calculator_definitions (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                   uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  name                        text NOT NULL,
  description                 text,
  status                      text NOT NULL DEFAULT 'draft'
                              CHECK (status IN ('draft','incomplete','active','archived')),
  draft_definition            jsonb NOT NULL DEFAULT '{"schema_version":1,"parameters":[],"lines":[]}'::jsonb,
  published_version_id        uuid,
  cloned_from_catalog_id      uuid REFERENCES data.calculator_catalog(id) ON DELETE SET NULL,
  cloned_from_catalog_version int,
  tags                        text[] NOT NULL DEFAULT '{}',
  created_by                  uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_calculator_definitions_tenant
  ON data.calculator_definitions (tenant_id, status);

DROP TRIGGER IF EXISTS trg_calculator_definitions_updated_at ON data.calculator_definitions;
CREATE TRIGGER trg_calculator_definitions_updated_at
  BEFORE UPDATE ON data.calculator_definitions
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

ALTER TABLE data.calculator_definitions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "calculator_definitions: select tenant" ON data.calculator_definitions;
CREATE POLICY "calculator_definitions: select tenant"
  ON data.calculator_definitions FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS "calculator_definitions: write owner manager" ON data.calculator_definitions;
CREATE POLICY "calculator_definitions: write owner manager"
  ON data.calculator_definitions FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- =============================================================================
-- Versions immutables
-- =============================================================================
CREATE TABLE IF NOT EXISTS data.calculator_versions (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  definition_id    uuid NOT NULL REFERENCES data.calculator_definitions(id) ON DELETE CASCADE,
  tenant_id        uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  version_number   int NOT NULL CHECK (version_number > 0),
  definition       jsonb NOT NULL,
  content_hash     text NOT NULL,
  published_at     timestamptz NOT NULL DEFAULT now(),
  published_by     uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  UNIQUE (definition_id, version_number)
);

CREATE INDEX IF NOT EXISTS idx_calculator_versions_tenant
  ON data.calculator_versions (tenant_id, definition_id);

ALTER TABLE data.calculator_definitions
  DROP CONSTRAINT IF EXISTS calculator_definitions_published_version_id_fkey;
ALTER TABLE data.calculator_definitions
  ADD CONSTRAINT calculator_definitions_published_version_id_fkey
  FOREIGN KEY (published_version_id) REFERENCES data.calculator_versions(id) ON DELETE SET NULL;

ALTER TABLE data.project_lines
  DROP CONSTRAINT IF EXISTS project_lines_calculator_definition_id_fkey;
ALTER TABLE data.project_lines
  ADD CONSTRAINT project_lines_calculator_definition_id_fkey
  FOREIGN KEY (calculator_definition_id) REFERENCES data.calculator_definitions(id) ON DELETE SET NULL;
ALTER TABLE data.project_lines
  DROP CONSTRAINT IF EXISTS project_lines_calculator_version_id_fkey;
ALTER TABLE data.project_lines
  ADD CONSTRAINT project_lines_calculator_version_id_fkey
  FOREIGN KEY (calculator_version_id) REFERENCES data.calculator_versions(id) ON DELETE SET NULL;

ALTER TABLE data.commercial_document_lines
  DROP CONSTRAINT IF EXISTS cdl_calculator_definition_id_fkey;
ALTER TABLE data.commercial_document_lines
  ADD CONSTRAINT cdl_calculator_definition_id_fkey
  FOREIGN KEY (calculator_definition_id) REFERENCES data.calculator_definitions(id) ON DELETE SET NULL;
ALTER TABLE data.commercial_document_lines
  DROP CONSTRAINT IF EXISTS cdl_calculator_version_id_fkey;
ALTER TABLE data.commercial_document_lines
  ADD CONSTRAINT cdl_calculator_version_id_fkey
  FOREIGN KEY (calculator_version_id) REFERENCES data.calculator_versions(id) ON DELETE SET NULL;

CREATE OR REPLACE FUNCTION data.trg_calculator_version_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'calculator_version_immutable' USING ERRCODE = 'integrity_constraint_violation';
END;
$$;

DROP TRIGGER IF EXISTS trg_calculator_version_immutable ON data.calculator_versions;
CREATE TRIGGER trg_calculator_version_immutable
  BEFORE UPDATE OR DELETE ON data.calculator_versions
  FOR EACH ROW EXECUTE FUNCTION data.trg_calculator_version_immutable();

ALTER TABLE data.calculator_versions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "calculator_versions: select tenant" ON data.calculator_versions;
CREATE POLICY "calculator_versions: select tenant"
  ON data.calculator_versions FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

-- =============================================================================
-- Cases
-- =============================================================================
CREATE TABLE IF NOT EXISTS data.calculator_cases (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  definition_id   uuid NOT NULL REFERENCES data.calculator_definitions(id) ON DELETE CASCADE,
  tenant_id       uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  name            text NOT NULL,
  params          jsonb NOT NULL DEFAULT '{}'::jsonb,
  expected_lines  jsonb NOT NULL DEFAULT '[]'::jsonb,
  last_result     text NOT NULL DEFAULT 'unrun'
                  CHECK (last_result IN ('unrun','pass','fail')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_calculator_cases_definition
  ON data.calculator_cases (definition_id);

ALTER TABLE data.calculator_cases ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "calculator_cases: select tenant" ON data.calculator_cases;
CREATE POLICY "calculator_cases: select tenant"
  ON data.calculator_cases FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS "calculator_cases: write owner manager" ON data.calculator_cases;
CREATE POLICY "calculator_cases: write owner manager"
  ON data.calculator_cases FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- =============================================================================
-- Runs
-- =============================================================================
CREATE TABLE IF NOT EXISTS data.calculator_runs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  version_id      uuid NOT NULL REFERENCES data.calculator_versions(id) ON DELETE RESTRICT,
  definition_id   uuid NOT NULL REFERENCES data.calculator_definitions(id) ON DELETE RESTRICT,
  params          jsonb NOT NULL DEFAULT '{}'::jsonb,
  destination     text NOT NULL CHECK (destination IN ('project','document')),
  project_id      uuid REFERENCES data.projects(id) ON DELETE CASCADE,
  document_id     uuid REFERENCES data.commercial_documents(id) ON DELETE CASCADE,
  lines_hash      text NOT NULL,
  client_op_id    uuid NOT NULL,
  created_by      uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, client_op_id),
  CHECK (
    (destination = 'project' AND project_id IS NOT NULL AND document_id IS NULL)
    OR (destination = 'document' AND document_id IS NOT NULL AND project_id IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_calculator_runs_target_project
  ON data.calculator_runs (project_id) WHERE project_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_calculator_runs_target_document
  ON data.calculator_runs (document_id) WHERE document_id IS NOT NULL;

ALTER TABLE data.project_lines
  DROP CONSTRAINT IF EXISTS project_lines_source_run_id_fkey;
ALTER TABLE data.project_lines
  ADD CONSTRAINT project_lines_source_run_id_fkey
  FOREIGN KEY (source_run_id) REFERENCES data.calculator_runs(id) ON DELETE SET NULL;

ALTER TABLE data.commercial_document_lines
  DROP CONSTRAINT IF EXISTS cdl_source_run_id_fkey;
ALTER TABLE data.commercial_document_lines
  ADD CONSTRAINT cdl_source_run_id_fkey
  FOREIGN KEY (source_run_id) REFERENCES data.calculator_runs(id) ON DELETE SET NULL;

ALTER TABLE data.calculator_runs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "calculator_runs: select tenant" ON data.calculator_runs;
CREATE POLICY "calculator_runs: select tenant"
  ON data.calculator_runs FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );
-- Escriptura només via RPC service_role

-- =============================================================================
-- API views
-- =============================================================================
CREATE OR REPLACE VIEW api.calculator_definitions
  WITH (security_invoker = true)
AS
SELECT *
FROM data.calculator_definitions
WHERE tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.calculator_versions
  WITH (security_invoker = true)
AS
SELECT *
FROM data.calculator_versions
WHERE tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.calculator_cases
  WITH (security_invoker = true)
AS
SELECT *
FROM data.calculator_cases
WHERE tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.calculator_runs
  WITH (security_invoker = true)
AS
SELECT *
FROM data.calculator_runs
WHERE tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.calculator_catalog
  WITH (security_invoker = true)
AS
SELECT id, slug, target_archetypes, catalog_version, definition, tags, is_active, created_at, updated_at
FROM data.calculator_catalog
WHERE is_active;

GRANT SELECT ON api.calculator_definitions TO authenticated;
GRANT SELECT ON api.calculator_versions TO authenticated;
GRANT SELECT ON api.calculator_cases TO authenticated;
GRANT SELECT ON api.calculator_runs TO authenticated;
GRANT SELECT ON api.calculator_catalog TO authenticated;

-- Vista project_lines amb columnes d'origen (manté total_with_tax en dos passos)
CREATE OR REPLACE VIEW api.project_lines
  WITH (security_invoker = true)
AS
SELECT
  pl.id,
  pl.tenant_id,
  pl.project_id,
  pl.catalog_item_id,
  pl.kind,
  pl.name,
  pl.description,
  pl.unit,
  pl.quantity,
  pl.unit_price,
  pl.discount_pct,
  pl.tax_rate,
  pl.position,
  pl.notes,
  pl.created_at,
  pl.updated_at,
  data.line_net(pl.quantity, pl.unit_price, pl.discount_pct) AS subtotal,
  (
    data.line_net(pl.quantity, pl.unit_price, pl.discount_pct)
    + ROUND(
        data.line_net(pl.quantity, pl.unit_price, pl.discount_pct) * pl.tax_rate / 100,
        2
      )
  ) AS total_with_tax,
  ci.name AS catalog_item_name,
  ci.sku  AS catalog_item_sku,
  pl.client_op_id,
  pl.source_quote_line_id,
  pl.line_origin,
  pl.calculator_definition_id,
  pl.calculator_version_id,
  pl.calculator_line_key,
  pl.source_run_id
FROM data.project_lines pl
LEFT JOIN data.catalog_items ci ON ci.id = pl.catalog_item_id
WHERE pl.tenant_id = data.active_tenant_id();

GRANT SELECT ON api.project_lines TO authenticated;

-- =============================================================================
-- Helpers de permís (actor explícit per service_role)
-- =============================================================================
CREATE OR REPLACE FUNCTION data.can_edit_commercial_pricing_as(
  p_tenant_id uuid,
  p_site_id uuid,
  p_user_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_role text;
BEGIN
  IF p_user_id IS NULL OR p_tenant_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT tm.role INTO v_role
  FROM data.tenant_members tm
  WHERE tm.tenant_id = p_tenant_id
    AND tm.user_id = p_user_id
    AND tm.is_active
    AND (tm.site_id IS NULL OR p_site_id IS NULL OR tm.site_id = p_site_id)
  ORDER BY CASE WHEN tm.role IN ('owner','manager') THEN 0 ELSE 1 END
  LIMIT 1;

  IF v_role IN ('owner', 'manager') THEN
    RETURN true;
  END IF;

  RETURN COALESCE(
    data.member_has_live_permission(
      p_tenant_id, p_user_id, 'commercial.pricing.edit', p_site_id
    ),
    false
  );
END;
$$;

REVOKE ALL ON FUNCTION data.can_edit_commercial_pricing_as(uuid, uuid, uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION data.assert_calculator_owner_manager(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_role text;
BEGIN
  v_role := data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
END;
$$;

-- =============================================================================
-- Normalitzar tags (D16)
-- =============================================================================
CREATE OR REPLACE FUNCTION data.normalize_calculator_tags(p_tags text[])
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(
    ARRAY(
      SELECT DISTINCT lower(btrim(t))
      FROM unnest(COALESCE(p_tags, '{}'::text[])) AS t
      WHERE btrim(t) <> ''
      ORDER BY 1
      LIMIT 8
    ),
    '{}'::text[]
  );
$$;

-- =============================================================================
-- Publish version
-- =============================================================================
CREATE OR REPLACE FUNCTION api.publish_calculator_version(
  p_definition_id uuid,
  p_content_hash text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_def data.calculator_definitions%ROWTYPE;
  v_next int;
  v_version_id uuid;
  v_hash text;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_active_tenant' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_calculator_owner_manager(v_tenant_id);

  SELECT * INTO v_def
  FROM data.calculator_definitions
  WHERE id = p_definition_id AND tenant_id = v_tenant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'calculator_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT COALESCE(MAX(version_number), 0) + 1 INTO v_next
  FROM data.calculator_versions
  WHERE definition_id = p_definition_id;

  v_hash := COALESCE(
    NULLIF(btrim(p_content_hash), ''),
    encode(sha256(convert_to(v_def.draft_definition::text, 'UTF8')), 'hex')
  );

  INSERT INTO data.calculator_versions (
    definition_id, tenant_id, version_number, definition, content_hash, published_by
  ) VALUES (
    p_definition_id, v_tenant_id, v_next, v_def.draft_definition, v_hash, auth.uid()
  )
  RETURNING id INTO v_version_id;

  UPDATE data.calculator_definitions
  SET published_version_id = v_version_id,
      updated_at = now()
  WHERE id = p_definition_id;

  PERFORM data.log_audit_event(
    v_tenant_id,
    auth.uid(),
    NULL,
    'CALCULATOR_PUBLISHED',
    'calculator_definition',
    p_definition_id,
    jsonb_build_object('version_id', v_version_id, 'version_number', v_next)
  );

  RETURN v_version_id;
END;
$$;

REVOKE ALL ON FUNCTION api.publish_calculator_version(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.publish_calculator_version(uuid, text) TO authenticated;

-- =============================================================================
-- Activate (requereix versió publicada + cas pass; validació completa a fase 4)
-- =============================================================================
CREATE OR REPLACE FUNCTION api.set_calculator_status(
  p_definition_id uuid,
  p_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_def data.calculator_definitions%ROWTYPE;
  v_pass int;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_active_tenant' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_calculator_owner_manager(v_tenant_id);

  IF p_status NOT IN ('draft','incomplete','active','archived') THEN
    RAISE EXCEPTION 'invalid_status' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_def
  FROM data.calculator_definitions
  WHERE id = p_definition_id AND tenant_id = v_tenant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'calculator_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_status = 'active' THEN
    IF v_def.published_version_id IS NULL THEN
      RAISE EXCEPTION 'calculator_not_published' USING ERRCODE = 'P0001';
    END IF;
    SELECT COUNT(*) INTO v_pass
    FROM data.calculator_cases
    WHERE definition_id = p_definition_id AND last_result = 'pass';
    IF v_pass < 1 THEN
      RAISE EXCEPTION 'calculator_case_required' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  UPDATE data.calculator_definitions
  SET status = p_status, updated_at = now()
  WHERE id = p_definition_id;

  PERFORM data.log_audit_event(
    v_tenant_id,
    auth.uid(),
    NULL,
    CASE p_status
      WHEN 'active' THEN 'CALCULATOR_ACTIVATED'
      WHEN 'archived' THEN 'CALCULATOR_ARCHIVED'
      ELSE 'CALCULATOR_STATUS_CHANGED'
    END,
    'calculator_definition',
    p_definition_id,
    jsonb_build_object('status', p_status)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.set_calculator_status(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_calculator_status(uuid, text) TO authenticated;

-- =============================================================================
-- Apply lines (service_role only)
-- =============================================================================
CREATE OR REPLACE FUNCTION api.apply_calculator_lines(
  p_version_id uuid,
  p_params jsonb,
  p_lines jsonb,
  p_lines_hash text,
  p_client_op_id uuid,
  p_actor_user_id uuid,
  p_project_id uuid DEFAULT NULL,
  p_document_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_version data.calculator_versions%ROWTYPE;
  v_def data.calculator_definitions%ROWTYPE;
  v_run data.calculator_runs%ROWTYPE;
  v_project data.projects%ROWTYPE;
  v_doc data.commercial_documents%ROWTYPE;
  v_destination text;
  v_site_id uuid;
  v_elem jsonb;
  v_pos int;
  v_price numeric;
  v_qty numeric;
  v_disc numeric;
  v_tax numeric;
  v_net numeric;
  v_tax_amt numeric;
  v_allow_zero boolean;
  v_kind text;
  v_name text;
BEGIN
  IF p_actor_user_id IS NULL OR p_client_op_id IS NULL OR p_version_id IS NULL THEN
    RAISE EXCEPTION 'invalid_args' USING ERRCODE = '22023';
  END IF;

  IF (p_project_id IS NULL) = (p_document_id IS NULL) THEN
    RAISE EXCEPTION 'destination_xor' USING ERRCODE = '22023';
  END IF;

  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' THEN
    RAISE EXCEPTION 'lines_required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_version FROM data.calculator_versions WHERE id = p_version_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'calculator_version_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_def
  FROM data.calculator_definitions
  WHERE id = v_version.definition_id AND tenant_id = v_version.tenant_id;
  IF NOT FOUND OR v_def.status <> 'active' THEN
    RAISE EXCEPTION 'calculator_not_active' USING ERRCODE = 'P0001';
  END IF;

  -- Idempotència
  SELECT * INTO v_run
  FROM data.calculator_runs
  WHERE tenant_id = v_version.tenant_id AND client_op_id = p_client_op_id;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'status', 'duplicate',
      'run_id', v_run.id,
      'lines_hash', v_run.lines_hash
    );
  END IF;

  IF p_project_id IS NOT NULL THEN
    v_destination := 'project';
    SELECT * INTO v_project FROM data.projects WHERE id = p_project_id;
    IF NOT FOUND OR v_project.tenant_id <> v_version.tenant_id THEN
      RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'no_data_found';
    END IF;
    PERFORM data.assert_price_sheet_mutable(p_project_id);
    v_site_id := v_project.site_id;
  ELSE
    v_destination := 'document';
    SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
    IF NOT FOUND OR v_doc.tenant_id <> v_version.tenant_id THEN
      RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
    END IF;
    IF v_doc.status <> 'draft' OR v_doc.project_id IS NOT NULL THEN
      RAISE EXCEPTION 'document_not_mutable' USING ERRCODE = 'P0001';
    END IF;
    v_site_id := v_doc.site_id;
  END IF;

  IF NOT data.can_edit_commercial_pricing_as(v_version.tenant_id, v_site_id, p_actor_user_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  INSERT INTO data.calculator_runs (
    tenant_id, version_id, definition_id, params, destination,
    project_id, document_id, lines_hash, client_op_id, created_by
  ) VALUES (
    v_version.tenant_id, p_version_id, v_def.id, COALESCE(p_params, '{}'::jsonb),
    v_destination,
    p_project_id, p_document_id, p_lines_hash, p_client_op_id, p_actor_user_id
  )
  RETURNING * INTO v_run;

  IF v_destination = 'project' THEN
    DELETE FROM data.project_lines
    WHERE project_id = p_project_id
      AND tenant_id = v_version.tenant_id
      AND line_origin = 'calculator'
      AND calculator_definition_id = v_def.id;

    SELECT COALESCE(MAX(position), -1) + 1 INTO v_pos
    FROM data.project_lines
    WHERE project_id = p_project_id AND tenant_id = v_version.tenant_id;

    FOR v_elem IN SELECT value FROM jsonb_array_elements(p_lines)
    LOOP
      v_name := NULLIF(trim(COALESCE(v_elem->>'name', '')), '');
      IF v_name IS NULL THEN
        RAISE EXCEPTION 'name_required' USING ERRCODE = '22023';
      END IF;
      v_price := COALESCE((v_elem->>'unit_price')::numeric, 0);
      v_allow_zero := COALESCE((v_elem->>'allow_zero_price')::boolean, false);
      IF v_price < 0 OR (v_price = 0 AND NOT v_allow_zero) THEN
        RAISE EXCEPTION 'zero_price_not_allowed' USING ERRCODE = 'P0001';
      END IF;
      v_kind := COALESCE(NULLIF(v_elem->>'kind', ''), 'service');
      IF v_kind NOT IN ('product', 'service') THEN
        v_kind := 'service';
      END IF;

      INSERT INTO data.project_lines (
        tenant_id, project_id, kind, name, description, unit,
        quantity, unit_price, discount_pct, tax_rate, position,
        line_origin, calculator_definition_id, calculator_version_id,
        calculator_line_key, source_run_id
      ) VALUES (
        v_version.tenant_id, p_project_id,
        v_kind::data.catalog_item_kind,
        v_name,
        NULLIF(v_elem->>'description', ''),
        COALESCE(NULLIF(v_elem->>'unit', ''), 'u'),
        COALESCE((v_elem->>'quantity')::numeric, 1),
        v_price,
        COALESCE((v_elem->>'discount_pct')::numeric, 0),
        COALESCE((v_elem->>'tax_rate')::numeric, 21),
        v_pos,
        'calculator', v_def.id, p_version_id,
        NULLIF(v_elem->>'key', ''), v_run.id
      );
      v_pos := v_pos + 1;
    END LOOP;
  ELSE
    DELETE FROM data.commercial_document_lines
    WHERE document_id = p_document_id
      AND tenant_id = v_version.tenant_id
      AND line_origin = 'calculator'
      AND calculator_definition_id = v_def.id;

    SELECT COALESCE(MAX(position), -1) + 1 INTO v_pos
    FROM data.commercial_document_lines
    WHERE document_id = p_document_id AND tenant_id = v_version.tenant_id;

    FOR v_elem IN SELECT value FROM jsonb_array_elements(p_lines)
    LOOP
      v_name := NULLIF(trim(COALESCE(v_elem->>'name', '')), '');
      IF v_name IS NULL THEN
        RAISE EXCEPTION 'name_required' USING ERRCODE = '22023';
      END IF;
      v_price := COALESCE((v_elem->>'unit_price')::numeric, 0);
      v_allow_zero := COALESCE((v_elem->>'allow_zero_price')::boolean, false);
      IF v_price < 0 OR (v_price = 0 AND NOT v_allow_zero) THEN
        RAISE EXCEPTION 'zero_price_not_allowed' USING ERRCODE = 'P0001';
      END IF;
      v_kind := COALESCE(NULLIF(v_elem->>'kind', ''), 'service');
      IF v_kind NOT IN ('product', 'service') THEN
        v_kind := 'service';
      END IF;
      v_qty := COALESCE((v_elem->>'quantity')::numeric, 1);
      v_disc := COALESCE((v_elem->>'discount_pct')::numeric, 0);
      v_tax := COALESCE((v_elem->>'tax_rate')::numeric, 21);
      v_net := data.line_net(v_qty, v_price, v_disc);
      v_tax_amt := ROUND(v_net * v_tax / 100, 2);

      INSERT INTO data.commercial_document_lines (
        tenant_id, document_id, kind, name, description, unit,
        quantity, unit_price, discount_pct, tax_rate,
        line_subtotal, line_tax, line_total, position,
        line_origin, calculator_definition_id, calculator_version_id,
        calculator_line_key, source_run_id
      ) VALUES (
        v_version.tenant_id, p_document_id,
        v_kind::data.catalog_item_kind,
        v_name,
        NULLIF(v_elem->>'description', ''),
        COALESCE(NULLIF(v_elem->>'unit', ''), 'u'),
        v_qty, v_price, v_disc, v_tax,
        v_net, v_tax_amt, v_net + v_tax_amt, v_pos,
        'calculator', v_def.id, p_version_id,
        NULLIF(v_elem->>'key', ''), v_run.id
      );
      v_pos := v_pos + 1;
    END LOOP;

    PERFORM data.recompute_orphan_quote_totals(p_document_id);
  END IF;

  RETURN jsonb_build_object(
    'status', 'ok',
    'run_id', v_run.id,
    'lines_hash', v_run.lines_hash,
    'definition_id', v_def.id,
    'version_id', p_version_id
  );
END;
$$;

REVOKE ALL ON FUNCTION api.apply_calculator_lines(uuid, jsonb, jsonb, text, uuid, uuid, uuid, uuid) FROM PUBLIC;
-- Només service_role
GRANT EXECUTE ON FUNCTION api.apply_calculator_lines(uuid, jsonb, jsonb, text, uuid, uuid, uuid, uuid) TO service_role;
