-- CF-23: link pricing templates (serveis habituals) to visit checklists

CREATE TABLE IF NOT EXISTS data.pricing_template_checklists (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  template_id           uuid NOT NULL REFERENCES data.pricing_templates(id) ON DELETE CASCADE,
  checklist_template_id uuid NOT NULL REFERENCES data.checklist_templates(id) ON DELETE CASCADE,
  position              int  NOT NULL DEFAULT 0,
  created_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_pricing_template_checklist UNIQUE (template_id, checklist_template_id)
);

CREATE INDEX IF NOT EXISTS idx_pricing_template_checklists_template
  ON data.pricing_template_checklists (template_id, position);

ALTER TABLE data.pricing_template_checklists ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "pricing_template_checklists: select tenant"
  ON data.pricing_template_checklists;
CREATE POLICY "pricing_template_checklists: select tenant"
  ON data.pricing_template_checklists FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS "pricing_template_checklists: write owner/manager"
  ON data.pricing_template_checklists;
CREATE POLICY "pricing_template_checklists: write owner/manager"
  ON data.pricing_template_checklists FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON data.pricing_template_checklists TO authenticated;

CREATE OR REPLACE VIEW api.pricing_template_checklists
WITH (security_invoker = true) AS
SELECT * FROM data.pricing_template_checklists;

GRANT SELECT ON api.pricing_template_checklists TO authenticated;

-- Replace checklist links for a pricing template
CREATE OR REPLACE FUNCTION api.save_pricing_template_checklists(
  p_template_id uuid,
  p_checklist_template_ids uuid[]
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id uuid;
  v_uid uuid := auth.uid();
  v_id uuid;
  v_pos int := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT tenant_id INTO v_tenant_id
  FROM data.pricing_templates
  WHERE id = p_template_id;

  IF v_tenant_id IS NULL OR NOT (data.jwt_user_tenants() ? v_tenant_id::text) THEN
    RAISE EXCEPTION 'pricing_template_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;

  IF NOT (
    (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'permission_denied' USING ERRCODE = 'P0001';
  END IF;

  DELETE FROM data.pricing_template_checklists
  WHERE template_id = p_template_id;

  IF p_checklist_template_ids IS NULL THEN
    RETURN;
  END IF;

  FOREACH v_id IN ARRAY p_checklist_template_ids LOOP
    IF v_id IS NULL THEN
      CONTINUE;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM data.checklist_templates
      WHERE id = v_id
        AND tenant_id = v_tenant_id
        AND is_active
        AND NOT is_archived
    ) THEN
      CONTINUE;
    END IF;
    INSERT INTO data.pricing_template_checklists (
      tenant_id, template_id, checklist_template_id, position
    ) VALUES (
      v_tenant_id, p_template_id, v_id, v_pos
    )
    ON CONFLICT (template_id, checklist_template_id) DO UPDATE
      SET position = EXCLUDED.position;
    v_pos := v_pos + 1;
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION api.save_pricing_template_checklists(uuid, uuid[]) TO authenticated;

-- Extend apply_pricing_template to also apply linked checklists
CREATE OR REPLACE FUNCTION api.apply_pricing_template(
  p_project_id   uuid,
  p_template_id  uuid,
  p_quantities   jsonb DEFAULT '{}'::jsonb,
  p_discount_pct numeric DEFAULT NULL,
  p_client_op_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid;
  v_uid uuid := auth.uid();
  v_app_id uuid;
  v_item record;
  v_catalog data.catalog_items%ROWTYPE;
  v_qty numeric;
  v_discount numeric;
  v_line_id uuid;
  v_line_ids uuid[] := '{}';
  v_pos int := 0;
  v_cl record;
  v_run_ids uuid[] := '{}';
  v_run_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT tenant_id INTO v_tenant_id
  FROM data.projects
  WHERE id = p_project_id;

  IF v_tenant_id IS NULL OR NOT (data.jwt_user_tenants() ? v_tenant_id::text) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;

  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT id INTO v_app_id
  FROM data.pricing_template_applications
  WHERE tenant_id = v_tenant_id AND client_op_id = p_client_op_id;

  IF v_app_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'application_id', v_app_id,
      'status', 'duplicate',
      'line_ids', '[]'::jsonb,
      'checklist_run_ids', '[]'::jsonb
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.pricing_templates
    WHERE id = p_template_id AND tenant_id = v_tenant_id AND is_active
  ) THEN
    RAISE EXCEPTION 'pricing_template_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_discount_pct IS NOT NULL
     AND p_discount_pct <> 0
     AND NOT data.can_edit_commercial_pricing(v_tenant_id) THEN
    RAISE EXCEPTION 'permission_denied:commercial.pricing.edit'
      USING ERRCODE = 'P0001';
  END IF;

  SELECT COALESCE(MAX(position), -1) + 1 INTO v_pos
  FROM data.project_lines
  WHERE project_id = p_project_id;

  FOR v_item IN
    SELECT *
    FROM data.pricing_template_items
    WHERE template_id = p_template_id AND tenant_id = v_tenant_id
    ORDER BY position, created_at
  LOOP
    SELECT * INTO v_catalog
    FROM data.catalog_items
    WHERE id = v_item.catalog_item_id AND tenant_id = v_tenant_id AND is_active;

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    v_qty := COALESCE(
      (p_quantities ->> v_item.id::text)::numeric,
      v_item.default_quantity,
      1
    );
    v_discount := COALESCE(p_discount_pct, v_item.default_discount_pct, 0);

    INSERT INTO data.project_lines (
      tenant_id, project_id, catalog_item_id, kind, name, description,
      unit, quantity, unit_price, discount_pct, tax_rate, position
    ) VALUES (
      v_tenant_id,
      p_project_id,
      v_catalog.id,
      v_catalog.kind,
      v_catalog.name,
      v_catalog.description,
      v_catalog.unit,
      v_qty,
      v_catalog.unit_price,
      v_discount,
      v_catalog.tax_rate,
      v_pos
    ) RETURNING id INTO v_line_id;

    v_line_ids := array_append(v_line_ids, v_line_id);
    v_pos := v_pos + 1;
  END LOOP;

  INSERT INTO data.pricing_template_applications (
    tenant_id, project_id, template_id, client_op_id, applied_by
  ) VALUES (
    v_tenant_id, p_project_id, p_template_id, p_client_op_id, v_uid
  ) RETURNING id INTO v_app_id;

  -- Apply linked visit checklists (skip soft failures so lines still land)
  FOR v_cl IN
    SELECT checklist_template_id
    FROM data.pricing_template_checklists
    WHERE template_id = p_template_id AND tenant_id = v_tenant_id
    ORDER BY position, created_at
  LOOP
    BEGIN
      v_run_id := api.apply_checklist_to_project(p_project_id, v_cl.checklist_template_id, NULL);
      IF v_run_id IS NOT NULL THEN
        v_run_ids := array_append(v_run_ids, v_run_id);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'pricing_template checklist skip: %', SQLERRM;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'application_id', v_app_id,
    'status', 'created',
    'line_ids', to_jsonb(v_line_ids),
    'checklist_run_ids', to_jsonb(v_run_ids)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.apply_pricing_template(uuid, uuid, jsonb, numeric, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.apply_pricing_template(uuid, uuid, jsonb, numeric, uuid)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
