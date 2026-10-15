-- CF-29: persist OutputLine.unit_cost → project_line_financials on calculator apply.

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
  v_line_id uuid;
  v_unit_cost numeric;
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
      )
      RETURNING id INTO v_line_id;

      IF v_elem ? 'unit_cost'
         AND NULLIF(trim(COALESCE(v_elem->>'unit_cost', '')), '') IS NOT NULL THEN
        v_unit_cost := (v_elem->>'unit_cost')::numeric;
        IF v_unit_cost IS NOT NULL AND v_unit_cost >= 0 THEN
          INSERT INTO data.project_line_financials (project_line_id, tenant_id, unit_cost_cents)
          VALUES (
            v_line_id,
            v_version.tenant_id,
            ROUND(v_unit_cost * 100)::integer
          )
          ON CONFLICT (project_line_id) DO UPDATE
          SET unit_cost_cents = EXCLUDED.unit_cost_cents,
              updated_at = now();
        END IF;
      END IF;

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
GRANT EXECUTE ON FUNCTION api.apply_calculator_lines(uuid, jsonb, jsonb, text, uuid, uuid, uuid, uuid) TO service_role;
