-- CF-19 follow-up: harden cost copy; cover copy_project_lines + apply_price_sheet;
-- fix upsert client_op_id retry so a crashed first attempt still seeds cost.

-- ---------------------------------------------------------------------------
-- 1. Harden DEFINER copy (tenant match + catalog binding)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.copy_catalog_cost_to_line(
  p_line_id uuid,
  p_catalog_item_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_line_tenant uuid;
  v_line_catalog uuid;
  v_cost_tenant uuid;
  v_cost integer;
BEGIN
  IF p_line_id IS NULL OR p_catalog_item_id IS NULL THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.project_line_financials WHERE project_line_id = p_line_id
  ) THEN
    RETURN;
  END IF;

  SELECT l.tenant_id, l.catalog_item_id
  INTO v_line_tenant, v_line_catalog
  FROM data.project_lines l
  WHERE l.id = p_line_id;

  IF v_line_tenant IS NULL THEN
    RETURN;
  END IF;

  IF v_line_catalog IS NOT NULL
     AND v_line_catalog IS DISTINCT FROM p_catalog_item_id THEN
    RETURN;
  END IF;

  SELECT f.tenant_id, f.unit_cost_cents
  INTO v_cost_tenant, v_cost
  FROM data.catalog_item_financials f
  WHERE f.catalog_item_id = p_catalog_item_id;

  IF v_cost IS NULL OR v_cost_tenant IS DISTINCT FROM v_line_tenant THEN
    RETURN;
  END IF;

  INSERT INTO data.project_line_financials (project_line_id, tenant_id, unit_cost_cents)
  VALUES (p_line_id, v_line_tenant, v_cost)
  ON CONFLICT (project_line_id) DO NOTHING;
END;
$$;

REVOKE ALL ON FUNCTION data.copy_catalog_cost_to_line(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.copy_catalog_cost_to_line(uuid, uuid)
  TO authenticated, service_role;

-- Copy a source line's cost snapshot (DEFINER). No-op if target already has cost.
CREATE OR REPLACE FUNCTION data.copy_line_cost_to_line(
  p_source_line_id uuid,
  p_target_line_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_source_tenant uuid;
  v_target_tenant uuid;
  v_cost integer;
BEGIN
  IF p_source_line_id IS NULL OR p_target_line_id IS NULL THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.project_line_financials WHERE project_line_id = p_target_line_id
  ) THEN
    RETURN;
  END IF;

  SELECT l.tenant_id INTO v_target_tenant
  FROM data.project_lines l
  WHERE l.id = p_target_line_id;
  IF v_target_tenant IS NULL THEN
    RETURN;
  END IF;

  SELECT f.tenant_id, f.unit_cost_cents
  INTO v_source_tenant, v_cost
  FROM data.project_line_financials f
  WHERE f.project_line_id = p_source_line_id;

  IF v_cost IS NULL OR v_source_tenant IS DISTINCT FROM v_target_tenant THEN
    RETURN;
  END IF;

  INSERT INTO data.project_line_financials (project_line_id, tenant_id, unit_cost_cents)
  VALUES (p_target_line_id, v_target_tenant, v_cost)
  ON CONFLICT (project_line_id) DO NOTHING;
END;
$$;

REVOKE ALL ON FUNCTION data.copy_line_cost_to_line(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.copy_line_cost_to_line(uuid, uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. upsert_project_line — idempotent retry still seeds cost
-- ---------------------------------------------------------------------------
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
  v_is_insert      boolean := false;
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

  PERFORM data.assert_price_sheet_mutable(p_project_id);

  IF p_client_op_id IS NOT NULL THEN
    SELECT id INTO v_id
    FROM data.project_lines
    WHERE tenant_id = v_tenant_id
      AND client_op_id = p_client_op_id;
    IF v_id IS NOT NULL THEN
      PERFORM data.copy_catalog_cost_to_line(
        v_id,
        COALESCE(
          p_catalog_item_id,
          (SELECT catalog_item_id FROM data.project_lines WHERE id = v_id)
        )
      );
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
    v_is_insert := true;
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

  IF v_is_insert AND p_catalog_item_id IS NOT NULL THEN
    PERFORM data.copy_catalog_cost_to_line(v_id, p_catalog_item_id);
  END IF;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_project_line(
  uuid, uuid, uuid, text, text, text, text, numeric, numeric, numeric, numeric, int, text, uuid
) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. copy_project_lines — source cost snapshot, else catalog
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.copy_project_lines(
  p_source_project_id uuid,
  p_target_project_id uuid,
  p_mode text DEFAULT 'append',
  p_client_op_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant_id uuid;
  v_source data.projects%ROWTYPE;
  v_target data.projects%ROWTYPE;
  v_can_price boolean;
  v_mode text := lower(COALESCE(p_mode, 'append'));
  v_op_id uuid;
  v_existing jsonb;
  v_line record;
  v_catalog data.catalog_items%ROWTYPE;
  v_pos int := 0;
  v_line_id uuid;
  v_line_ids uuid[] := '{}';
  v_skipped jsonb := '[]'::jsonb;
  v_copied int := 0;
  v_unit_price numeric;
  v_discount numeric;
  v_tax numeric;
  v_kind text;
  v_name text;
  v_description text;
  v_unit text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  IF v_mode NOT IN ('append', 'replace') THEN
    RAISE EXCEPTION 'invalid_mode' USING ERRCODE = 'P0001';
  END IF;

  IF p_source_project_id IS NULL OR p_target_project_id IS NULL THEN
    RAISE EXCEPTION 'project_required' USING ERRCODE = 'P0001';
  END IF;

  IF p_source_project_id = p_target_project_id THEN
    RAISE EXCEPTION 'source_equals_target' USING ERRCODE = 'P0001';
  END IF;

  SELECT tenant_id INTO v_tenant_id
  FROM data.projects
  WHERE id = p_target_project_id;

  IF v_tenant_id IS NULL OR NOT (data.jwt_user_tenants() ? v_tenant_id::text) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;

  v_target := data.assert_tenant_project(p_target_project_id, v_tenant_id);
  v_source := data.assert_tenant_project(p_source_project_id, v_tenant_id);

  SELECT result, id INTO v_existing, v_op_id
  FROM data.price_sheet_ops
  WHERE tenant_id = v_tenant_id AND client_op_id = p_client_op_id;

  IF v_op_id IS NOT NULL THEN
    RETURN v_existing || jsonb_build_object('status', 'duplicate');
  END IF;

  PERFORM data.assert_price_sheet_mutable(p_target_project_id);

  v_can_price := data.can_edit_commercial_pricing(v_tenant_id, v_target.site_id);

  IF v_mode = 'replace' THEN
    DELETE FROM data.project_lines
    WHERE project_id = p_target_project_id AND tenant_id = v_tenant_id;
    v_pos := 0;
  ELSE
    SELECT COALESCE(MAX(position), -1) + 1 INTO v_pos
    FROM data.project_lines
    WHERE project_id = p_target_project_id AND tenant_id = v_tenant_id;
  END IF;

  FOR v_line IN
    SELECT *
    FROM data.project_lines
    WHERE project_id = p_source_project_id AND tenant_id = v_tenant_id
    ORDER BY position, created_at
  LOOP
    v_catalog := NULL::data.catalog_items;

    IF v_line.catalog_item_id IS NOT NULL THEN
      SELECT * INTO v_catalog
      FROM data.catalog_items
      WHERE id = v_line.catalog_item_id AND tenant_id = v_tenant_id;
    END IF;

    IF v_line.catalog_item_id IS NULL THEN
      IF NOT v_can_price THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
          'name', v_line.name,
          'reason', 'free_line_requires_pricing_edit'
        ));
        CONTINUE;
      END IF;
      IF COALESCE(v_line.unit_price, 0) <= 0 THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
          'name', v_line.name,
          'reason', 'zero_price_free_line'
        ));
        CONTINUE;
      END IF;
      v_kind := v_line.kind::text;
      v_name := v_line.name;
      v_description := v_line.description;
      v_unit := COALESCE(v_line.unit, 'u');
      v_unit_price := v_line.unit_price;
      v_discount := COALESCE(v_line.discount_pct, 0);
      v_tax := COALESCE(v_line.tax_rate, 21);
    ELSE
      IF v_catalog.id IS NULL THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
          'name', v_line.name,
          'reason', 'catalog_item_missing'
        ));
        CONTINUE;
      END IF;
      v_kind := v_catalog.kind::text;
      v_name := v_catalog.name;
      v_description := v_catalog.description;
      v_unit := v_catalog.unit;
      IF v_can_price THEN
        v_unit_price := v_line.unit_price;
        v_discount := COALESCE(v_line.discount_pct, 0);
        v_tax := COALESCE(v_line.tax_rate, v_catalog.tax_rate);
      ELSE
        v_unit_price := v_catalog.unit_price;
        v_discount := 0;
        v_tax := v_catalog.tax_rate;
      END IF;
    END IF;

    INSERT INTO data.project_lines (
      tenant_id, project_id, catalog_item_id, kind, name, description,
      unit, quantity, unit_price, discount_pct, tax_rate, position
    ) VALUES (
      v_tenant_id,
      p_target_project_id,
      v_line.catalog_item_id,
      v_kind::data.catalog_item_kind,
      v_name,
      v_description,
      v_unit,
      v_line.quantity,
      v_unit_price,
      v_discount,
      v_tax,
      v_pos
    ) RETURNING id INTO v_line_id;

    -- Prefer source line cost snapshot; else catalog default.
    PERFORM data.copy_line_cost_to_line(v_line.id, v_line_id);
    IF v_line.catalog_item_id IS NOT NULL THEN
      PERFORM data.copy_catalog_cost_to_line(v_line_id, v_line.catalog_item_id);
    END IF;

    v_line_ids := array_append(v_line_ids, v_line_id);
    v_copied := v_copied + 1;
    v_pos := v_pos + 1;
  END LOOP;

  v_existing := jsonb_build_object(
    'status', 'created',
    'mode', v_mode,
    'copied', v_copied,
    'line_ids', to_jsonb(v_line_ids),
    'skipped', v_skipped,
    'quote_warning', data.quote_issued_warning(p_target_project_id)
  );

  INSERT INTO data.price_sheet_ops (
    tenant_id, client_op_id, kind, project_id, result
  ) VALUES (
    v_tenant_id, p_client_op_id, 'copy_project_lines', p_target_project_id, v_existing
  );

  RETURN v_existing;
END;
$$;

REVOKE ALL ON FUNCTION api.copy_project_lines(uuid, uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.copy_project_lines(uuid, uuid, text, uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. apply_price_sheet — catalog cost on insert
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.apply_price_sheet(
  p_project_id uuid,
  p_lines jsonb,
  p_mode text DEFAULT 'append',
  p_checklist_template_id uuid DEFAULT NULL,
  p_client_op_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant_id uuid;
  v_project data.projects%ROWTYPE;
  v_can_price boolean;
  v_mode text := lower(COALESCE(p_mode, 'append'));
  v_op_id uuid;
  v_existing jsonb;
  v_elem jsonb;
  v_pos int := 0;
  v_line_id uuid;
  v_line_ids uuid[] := '{}';
  v_skipped jsonb := '[]'::jsonb;
  v_inserted int := 0;
  v_catalog data.catalog_items%ROWTYPE;
  v_catalog_id uuid;
  v_kind text;
  v_name text;
  v_description text;
  v_unit text;
  v_qty numeric;
  v_unit_price numeric;
  v_discount numeric;
  v_tax numeric;
  v_run_id uuid;
  v_run_ids uuid[] := '{}';
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  IF v_mode NOT IN ('append', 'replace') THEN
    RAISE EXCEPTION 'invalid_mode' USING ERRCODE = 'P0001';
  END IF;

  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' THEN
    RAISE EXCEPTION 'lines_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT tenant_id INTO v_tenant_id
  FROM data.projects
  WHERE id = p_project_id;

  IF v_tenant_id IS NULL OR NOT (data.jwt_user_tenants() ? v_tenant_id::text) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;

  v_project := data.assert_tenant_project(p_project_id, v_tenant_id);

  SELECT result, id INTO v_existing, v_op_id
  FROM data.price_sheet_ops
  WHERE tenant_id = v_tenant_id AND client_op_id = p_client_op_id;

  IF v_op_id IS NOT NULL THEN
    RETURN v_existing || jsonb_build_object('status', 'duplicate');
  END IF;

  PERFORM data.assert_price_sheet_mutable(p_project_id);

  v_can_price := data.can_edit_commercial_pricing(v_tenant_id, v_project.site_id);

  IF v_mode = 'replace' THEN
    DELETE FROM data.project_lines
    WHERE project_id = p_project_id AND tenant_id = v_tenant_id;
    v_pos := 0;
  ELSE
    SELECT COALESCE(MAX(position), -1) + 1 INTO v_pos
    FROM data.project_lines
    WHERE project_id = p_project_id AND tenant_id = v_tenant_id;
  END IF;

  FOR v_elem IN SELECT value FROM jsonb_array_elements(p_lines)
  LOOP
    v_catalog := NULL::data.catalog_items;
    v_catalog_id := NULLIF(v_elem->>'catalog_item_id', '')::uuid;
    v_qty := COALESCE((v_elem->>'quantity')::numeric, 1);
    IF v_qty < 0 THEN
      v_qty := 0;
    END IF;

    IF v_catalog_id IS NOT NULL THEN
      SELECT * INTO v_catalog
      FROM data.catalog_items
      WHERE id = v_catalog_id AND tenant_id = v_tenant_id AND is_active;
      IF NOT FOUND THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
          'name', COALESCE(v_elem->>'name', v_catalog_id::text),
          'reason', 'catalog_item_missing'
        ));
        CONTINUE;
      END IF;

      v_kind := v_catalog.kind::text;
      v_name := v_catalog.name;
      v_description := COALESCE(v_elem->>'description', v_catalog.description);
      v_unit := v_catalog.unit;
      IF v_can_price THEN
        v_unit_price := COALESCE((v_elem->>'unit_price')::numeric, v_catalog.unit_price);
        v_discount := COALESCE((v_elem->>'discount_pct')::numeric, 0);
        v_tax := COALESCE((v_elem->>'tax_rate')::numeric, v_catalog.tax_rate);
      ELSE
        v_unit_price := v_catalog.unit_price;
        v_discount := 0;
        v_tax := v_catalog.tax_rate;
      END IF;
    ELSE
      IF NOT v_can_price THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
          'name', COALESCE(v_elem->>'name', ''),
          'reason', 'free_line_requires_pricing_edit'
        ));
        CONTINUE;
      END IF;
      v_name := NULLIF(trim(COALESCE(v_elem->>'name', '')), '');
      IF v_name IS NULL THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
          'name', '',
          'reason', 'name_required'
        ));
        CONTINUE;
      END IF;
      v_unit_price := COALESCE((v_elem->>'unit_price')::numeric, 0);
      IF v_unit_price <= 0 THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
          'name', v_name,
          'reason', 'zero_price_free_line'
        ));
        CONTINUE;
      END IF;
      v_kind := COALESCE(NULLIF(v_elem->>'kind', ''), 'service');
      v_description := v_elem->>'description';
      v_unit := COALESCE(NULLIF(v_elem->>'unit', ''), 'u');
      v_discount := COALESCE((v_elem->>'discount_pct')::numeric, 0);
      v_tax := COALESCE((v_elem->>'tax_rate')::numeric, 21);
      v_catalog_id := NULL;
    END IF;

    INSERT INTO data.project_lines (
      tenant_id, project_id, catalog_item_id, kind, name, description,
      unit, quantity, unit_price, discount_pct, tax_rate, position
    ) VALUES (
      v_tenant_id,
      p_project_id,
      v_catalog_id,
      v_kind::data.catalog_item_kind,
      v_name,
      v_description,
      v_unit,
      v_qty,
      v_unit_price,
      v_discount,
      v_tax,
      v_pos
    ) RETURNING id INTO v_line_id;

    IF v_catalog_id IS NOT NULL THEN
      PERFORM data.copy_catalog_cost_to_line(v_line_id, v_catalog_id);
    END IF;

    v_line_ids := array_append(v_line_ids, v_line_id);
    v_inserted := v_inserted + 1;
    v_pos := v_pos + 1;
  END LOOP;

  IF p_checklist_template_id IS NOT NULL THEN
    BEGIN
      v_run_id := api.apply_checklist_to_project(p_project_id, p_checklist_template_id, NULL);
      IF v_run_id IS NOT NULL THEN
        v_run_ids := array_append(v_run_ids, v_run_id);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
        'name', p_checklist_template_id::text,
        'reason', 'checklist_apply_failed',
        'detail', SQLERRM
      ));
    END;
  END IF;

  v_existing := jsonb_build_object(
    'status', 'created',
    'mode', v_mode,
    'inserted', v_inserted,
    'line_ids', to_jsonb(v_line_ids),
    'skipped', v_skipped,
    'checklist_run_ids', to_jsonb(v_run_ids),
    'quote_warning', data.quote_issued_warning(p_project_id)
  );

  INSERT INTO data.price_sheet_ops (
    tenant_id, client_op_id, kind, project_id, result
  ) VALUES (
    v_tenant_id, p_client_op_id, 'apply_price_sheet', p_project_id, v_existing
  );

  RETURN v_existing;
END;
$$;

REVOKE ALL ON FUNCTION api.apply_price_sheet(uuid, jsonb, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.apply_price_sheet(uuid, jsonb, text, uuid, uuid)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
