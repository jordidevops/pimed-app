-- Entity Timeline — plantilles de comentari (Fase 2)

CREATE TABLE data.entity_comment_templates (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  entity_type       text,
  title             text NOT NULL,
  body              text NOT NULL,
  default_is_task   boolean NOT NULL DEFAULT false,
  sort_order        integer NOT NULL DEFAULT 0,
  is_active         boolean NOT NULL DEFAULT true,
  created_by        uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT entity_comment_templates_title_not_empty
    CHECK (length(trim(title)) > 0),
  CONSTRAINT entity_comment_templates_body_not_empty
    CHECK (length(trim(body)) > 0),
  CONSTRAINT entity_comment_templates_entity_type_check
    CHECK (
      entity_type IS NULL
      OR entity_type IN ('employee', 'contact', 'project', 'document')
    )
);

CREATE INDEX idx_entity_comment_templates_tenant
  ON data.entity_comment_templates (tenant_id, sort_order, title)
  WHERE is_active = true;

CREATE TRIGGER trg_entity_comment_templates_updated_at
  BEFORE UPDATE ON data.entity_comment_templates
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

ALTER TABLE data.entity_comment_templates ENABLE ROW LEVEL SECURITY;

CREATE POLICY entity_comment_templates_select ON data.entity_comment_templates
  FOR SELECT TO authenticated
  USING (tenant_id = data.active_tenant_id());

CREATE POLICY entity_comment_templates_insert ON data.entity_comment_templates
  FOR INSERT TO authenticated
  WITH CHECK (
    tenant_id = data.active_tenant_id()
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

CREATE POLICY entity_comment_templates_update ON data.entity_comment_templates
  FOR UPDATE TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  )
  WITH CHECK (
    tenant_id = data.active_tenant_id()
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

CREATE POLICY entity_comment_templates_delete ON data.entity_comment_templates
  FOR DELETE TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON data.entity_comment_templates TO authenticated;

-- -----------------------------------------------------------------------------
-- RPCs
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.list_entity_comment_templates(
  p_entity_type text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF auth.uid() IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(
      jsonb_build_object(
        'id', t.id,
        'entity_type', t.entity_type,
        'title', t.title,
        'body', t.body,
        'default_is_task', t.default_is_task,
        'sort_order', t.sort_order
      )
      ORDER BY t.sort_order, t.title
    )
    FROM data.entity_comment_templates t
    WHERE t.tenant_id = v_tenant_id
      AND t.is_active = true
      AND (
        t.entity_type IS NULL
        OR p_entity_type IS NULL
        OR t.entity_type = p_entity_type
      )
  ), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION api.upsert_entity_comment_template(
  p_title           text,
  p_body            text,
  p_id              uuid DEFAULT NULL,
  p_entity_type     text DEFAULT NULL,
  p_default_is_task boolean DEFAULT false,
  p_sort_order      integer DEFAULT 0
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_id        uuid;
BEGIN
  IF auth.uid() IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF nullif(trim(p_title), '') IS NULL OR nullif(trim(p_body), '') IS NULL THEN
    RAISE EXCEPTION 'validation_failed' USING ERRCODE = '22023';
  END IF;

  IF p_entity_type IS NOT NULL
     AND p_entity_type NOT IN ('employee', 'contact', 'project', 'document') THEN
    RAISE EXCEPTION 'invalid_entity_type' USING ERRCODE = '22023';
  END IF;

  IF p_id IS NOT NULL THEN
    UPDATE data.entity_comment_templates
    SET
      entity_type = p_entity_type,
      title = trim(p_title),
      body = trim(p_body),
      default_is_task = coalesce(p_default_is_task, false),
      sort_order = coalesce(p_sort_order, 0)
    WHERE id = p_id
      AND tenant_id = v_tenant_id
    RETURNING id INTO v_id;

    IF v_id IS NULL THEN
      RAISE EXCEPTION 'not_found' USING ERRCODE = 'P0002';
    END IF;
  ELSE
    INSERT INTO data.entity_comment_templates (
      tenant_id, entity_type, title, body, default_is_task, sort_order, created_by
    ) VALUES (
      v_tenant_id,
      p_entity_type,
      trim(p_title),
      trim(p_body),
      coalesce(p_default_is_task, false),
      coalesce(p_sort_order, 0),
      auth.uid()
    )
    RETURNING id INTO v_id;
  END IF;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.delete_entity_comment_template(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF auth.uid() IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  DELETE FROM data.entity_comment_templates
  WHERE id = p_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found' USING ERRCODE = 'P0002';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_entity_comment_templates(text) TO authenticated;
GRANT EXECUTE ON FUNCTION api.upsert_entity_comment_template(text, text, uuid, text, boolean, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION api.delete_entity_comment_template(uuid) TO authenticated;
