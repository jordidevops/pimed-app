-- CF-1 follow-up: commercial.pricing.edit also honours the project's site role.
-- apply_pricing_template rejected discounts for site managers because
-- can_edit_commercial_pricing only inspected JWT global_role.

DROP FUNCTION IF EXISTS data.can_edit_commercial_pricing(uuid);

CREATE FUNCTION data.can_edit_commercial_pricing(
  p_tenant_id uuid,
  p_site_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_claims jsonb;
  v_role text;
  v_site_role text;
BEGIN
  IF auth.uid() IS NULL OR p_tenant_id IS NULL THEN
    RETURN false;
  END IF;

  v_claims := data.jwt_user_tenants() -> p_tenant_id::text;
  v_role := v_claims ->> 'global_role';
  IF v_role IN ('owner', 'manager') THEN
    RETURN true;
  END IF;

  IF p_site_id IS NOT NULL THEN
    v_site_role := v_claims -> 'sites' ->> p_site_id::text;
    IF v_site_role IN ('owner', 'manager') THEN
      RETURN true;
    END IF;
  END IF;

  RETURN COALESCE(
    data.member_has_live_permission(
      p_tenant_id, auth.uid(), 'commercial.pricing.edit', p_site_id
    ),
    false
  );
END;
$$;

REVOKE ALL ON FUNCTION data.can_edit_commercial_pricing(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.can_edit_commercial_pricing(uuid, uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION data.can_edit_commercial_pricing(uuid, uuid) IS
  'Owner/manager global, owner/manager del site del document, o concessió live commercial.pricing.edit.';

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
  v_site_id uuid;
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

  SELECT tenant_id, site_id INTO v_tenant_id, v_site_id
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
     AND NOT data.can_edit_commercial_pricing(v_tenant_id, v_site_id) THEN
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

CREATE OR REPLACE FUNCTION api.upsert_project_line(
  p_project_id       uuid,
  p_line_id          uuid       DEFAULT NULL,
  p_catalog_item_id  uuid       DEFAULT NULL,
  p_kind             text       DEFAULT 'service',
  p_name             text       DEFAULT '',
  p_description      text       DEFAULT NULL,
  p_unit             text       DEFAULT 'u',
  p_quantity         numeric    DEFAULT 1,
  p_unit_price       numeric    DEFAULT 0,
  p_discount_pct     numeric    DEFAULT 0,
  p_tax_rate         numeric    DEFAULT 21.00,
  p_position         int        DEFAULT 0,
  p_notes            text       DEFAULT NULL,
  p_client_op_id     uuid       DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_id             uuid;
  v_tenant_id      uuid := data.active_tenant_id();
  v_site_id        uuid;
  v_existing       data.project_lines%ROWTYPE;
  v_catalog        data.catalog_items%ROWTYPE;
  v_needs_pricing  boolean := false;
  v_can_price      boolean;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT site_id INTO v_site_id
  FROM data.projects
  WHERE id = p_project_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'project % not found in active tenant %',
      p_project_id, v_tenant_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF p_client_op_id IS NOT NULL THEN
    SELECT id INTO v_id
    FROM data.project_lines
    WHERE tenant_id = v_tenant_id
      AND client_op_id = p_client_op_id;
    IF v_id IS NOT NULL THEN
      RETURN v_id;
    END IF;
  END IF;

  IF p_catalog_item_id IS NOT NULL THEN
    SELECT * INTO v_catalog
    FROM data.catalog_items
    WHERE id = p_catalog_item_id AND tenant_id = v_tenant_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'catalog item % not found in active tenant %',
        p_catalog_item_id, v_tenant_id
        USING ERRCODE = 'no_data_found';
    END IF;
  END IF;

  IF p_line_id IS NOT NULL THEN
    SELECT * INTO v_existing
    FROM data.project_lines
    WHERE id = p_line_id
      AND tenant_id = v_tenant_id
      AND project_id = p_project_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'project line % not found', p_line_id
        USING ERRCODE = 'no_data_found';
    END IF;

    IF v_existing.unit_price IS DISTINCT FROM p_unit_price
       OR v_existing.discount_pct IS DISTINCT FROM p_discount_pct
       OR v_existing.tax_rate IS DISTINCT FROM p_tax_rate THEN
      v_needs_pricing := true;
    END IF;
  ELSE
    IF p_catalog_item_id IS NULL THEN
      v_needs_pricing := true;
    ELSE
      IF p_unit_price IS DISTINCT FROM v_catalog.unit_price
         OR p_tax_rate IS DISTINCT FROM v_catalog.tax_rate
         OR COALESCE(p_discount_pct, 0) <> 0 THEN
        v_needs_pricing := true;
      END IF;
    END IF;
  END IF;

  IF v_needs_pricing THEN
    v_can_price := data.can_edit_commercial_pricing(v_tenant_id, v_site_id);
    IF NOT v_can_price THEN
      RAISE EXCEPTION 'permission_denied:commercial.pricing.edit'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;

  IF p_line_id IS NULL THEN
    INSERT INTO data.project_lines (
      tenant_id, project_id, catalog_item_id, kind, name, description,
      unit, quantity, unit_price, discount_pct, tax_rate, position, notes,
      client_op_id
    ) VALUES (
      v_tenant_id,
      p_project_id,
      p_catalog_item_id,
      p_kind::data.catalog_item_kind,
      p_name,
      p_description,
      p_unit,
      p_quantity,
      p_unit_price,
      p_discount_pct,
      p_tax_rate,
      p_position,
      p_notes,
      p_client_op_id
    ) RETURNING id INTO v_id;
  ELSE
    UPDATE data.project_lines SET
      catalog_item_id = p_catalog_item_id,
      kind            = p_kind::data.catalog_item_kind,
      name            = p_name,
      description     = p_description,
      unit            = p_unit,
      quantity        = p_quantity,
      unit_price      = p_unit_price,
      discount_pct    = p_discount_pct,
      tax_rate        = p_tax_rate,
      position        = p_position,
      notes           = p_notes,
      client_op_id    = COALESCE(p_client_op_id, client_op_id),
      updated_at      = now()
    WHERE id         = p_line_id
      AND tenant_id  = v_tenant_id
      AND project_id = p_project_id
    RETURNING id INTO v_id;
  END IF;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_project_line(
  uuid, uuid, uuid, text, text, text, text, numeric, numeric, numeric, numeric, int, text, uuid
) TO authenticated;

NOTIFY pgrst, 'reload schema';
