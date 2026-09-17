-- Quote composer: search/clone past jobs, save OS as habitual pack, batch apply price sheet.
-- Does not change apply_pricing_template semantics (append + live catalog PVP).
-- Quote-issued drift stays a warning in the JSON payload; no new server block
-- (upsert_project_line does not gate on issued quotes).

CREATE TABLE IF NOT EXISTS data.price_sheet_ops (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  client_op_id uuid NOT NULL,
  kind         text NOT NULL CHECK (kind IN ('copy_project_lines', 'apply_price_sheet')),
  project_id   uuid NOT NULL REFERENCES data.projects(id) ON DELETE CASCADE,
  result       jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, client_op_id)
);

CREATE INDEX IF NOT EXISTS idx_price_sheet_ops_project
  ON data.price_sheet_ops (tenant_id, project_id);

ALTER TABLE data.price_sheet_ops ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "price_sheet_ops: select tenant" ON data.price_sheet_ops;
CREATE POLICY "price_sheet_ops: select tenant"
  ON data.price_sheet_ops FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text);

COMMENT ON TABLE data.price_sheet_ops IS
  'Idempotency receipts for copy_project_lines and apply_price_sheet (client_op_id).';

CREATE OR REPLACE FUNCTION data.quote_issued_warning(p_project_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = data
AS $$
  SELECT CASE
    WHEN EXISTS (
      SELECT 1
      FROM data.commercial_documents d
      WHERE d.project_id = p_project_id
        AND d.doc_type IN ('quote', 'quote_amendment')
        AND d.status = 'issued'
    )
    THEN jsonb_build_object(
      'quote_issued', true,
      'message', 'issued_quote_exists'
    )
    ELSE jsonb_build_object('quote_issued', false)
  END;
$$;

CREATE OR REPLACE FUNCTION data.assert_tenant_project(
  p_project_id uuid,
  p_tenant_id uuid
)
RETURNS data.projects
LANGUAGE plpgsql
STABLE
SET search_path = data
AS $$
DECLARE
  v_project data.projects%ROWTYPE;
BEGIN
  SELECT * INTO v_project
  FROM data.projects
  WHERE id = p_project_id AND tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;

  RETURN v_project;
END;
$$;

CREATE OR REPLACE FUNCTION api.search_jobs_for_pricing(
  p_query text DEFAULT NULL,
  p_client_id uuid DEFAULT NULL,
  p_exclude_project_id uuid DEFAULT NULL,
  p_completed_only boolean DEFAULT false,
  p_from timestamptz DEFAULT NULL,
  p_to timestamptz DEFAULT NULL,
  p_limit int DEFAULT 30
)
RETURNS TABLE (
  id uuid,
  name text,
  status text,
  client_id uuid,
  client_display_name text,
  site_id uuid,
  updated_at timestamptz,
  created_at timestamptz,
  line_count int,
  subtotal numeric,
  same_client boolean
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_q text := NULLIF(trim(COALESCE(p_query, '')), '');
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 30), 1), 50);
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY
  SELECT
    p.id,
    p.name::text,
    p.status::text,
    p.client_id,
    COALESCE(NULLIF(trim(c.display_name), ''), NULLIF(trim(c.legal_name), ''), '')::text AS client_display_name,
    p.site_id,
    p.updated_at,
    p.created_at,
    agg.line_count,
    agg.subtotal,
    (p_client_id IS NOT NULL AND p.client_id IS NOT DISTINCT FROM p_client_id) AS same_client
  FROM data.projects p
  LEFT JOIN data.contacts c
    ON c.id = p.client_id AND c.tenant_id = p.tenant_id
  INNER JOIN LATERAL (
    SELECT
      COUNT(*)::int AS line_count,
      COALESCE(SUM(
        pl.quantity * pl.unit_price * (1 - COALESCE(pl.discount_pct, 0) / 100)
      ), 0) AS subtotal
    FROM data.project_lines pl
    WHERE pl.project_id = p.id AND pl.tenant_id = p.tenant_id
  ) agg ON agg.line_count > 0
  WHERE p.tenant_id = v_tenant_id
    AND p.type IN ('work_order', 'maintenance')
    AND (p_exclude_project_id IS NULL OR p.id <> p_exclude_project_id)
    AND (NOT COALESCE(p_completed_only, false) OR p.status = 'completed')
    AND (p_client_id IS NULL OR p.client_id = p_client_id)
    AND (p_from IS NULL OR p.updated_at >= p_from)
    AND (p_to IS NULL OR p.updated_at <= p_to)
    AND (
      v_q IS NULL
      OR p.name ILIKE '%' || v_q || '%'
      OR COALESCE(c.display_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(c.legal_name, '') ILIKE '%' || v_q || '%'
      OR EXISTS (
        SELECT 1
        FROM data.project_lines pl2
        WHERE pl2.project_id = p.id
          AND pl2.tenant_id = p.tenant_id
          AND pl2.name ILIKE '%' || v_q || '%'
      )
    )
  ORDER BY
    (p_client_id IS NOT NULL AND p.client_id IS NOT DISTINCT FROM p_client_id) DESC,
    p.updated_at DESC
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION api.search_jobs_for_pricing(text, uuid, uuid, boolean, timestamptz, timestamptz, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.search_jobs_for_pricing(text, uuid, uuid, boolean, timestamptz, timestamptz, int)
  TO authenticated;

COMMENT ON FUNCTION api.search_jobs_for_pricing IS
  'Cerca OS amb línies de preu (no només completed). Exclou l''OS actual. Filtre completed opcional.';

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

COMMENT ON FUNCTION api.copy_project_lines IS
  'Copia línies d''una OS a una altra. Sense commercial.pricing.edit: PVP de catàleg i omet línies lliures. Mai preu 0 en línia lliure.';

CREATE OR REPLACE FUNCTION api.create_pricing_template_from_project(
  p_project_id uuid,
  p_name text,
  p_category text DEFAULT NULL,
  p_unmatched_mode text DEFAULT 'skip'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant_id uuid;
  v_project data.projects%ROWTYPE;
  v_role text;
  v_mode text := lower(COALESCE(p_unmatched_mode, 'skip'));
  v_line record;
  v_catalog_id uuid;
  v_tpl_id uuid;
  v_pos int := 0;
  v_item_count int := 0;
  v_skipped jsonb := '[]'::jsonb;
  v_created_catalog uuid[] := '{}';
  v_cl uuid;
  v_cl_pos int := 0;
  v_checklist_ids uuid[] := '{}';
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  IF NULLIF(trim(COALESCE(p_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'name_required' USING ERRCODE = 'P0001';
  END IF;

  IF v_mode NOT IN ('skip', 'create_catalog') THEN
    RAISE EXCEPTION 'invalid_unmatched_mode' USING ERRCODE = 'P0001';
  END IF;

  SELECT tenant_id INTO v_tenant_id
  FROM data.projects
  WHERE id = p_project_id;

  IF v_tenant_id IS NULL OR NOT (data.jwt_user_tenants() ? v_tenant_id::text) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;

  v_role := data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role';
  IF v_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:owner_or_manager' USING ERRCODE = 'P0001';
  END IF;

  v_project := data.assert_tenant_project(p_project_id, v_tenant_id);

  INSERT INTO data.pricing_templates (
    tenant_id, name, description, category, is_active
  ) VALUES (
    v_tenant_id,
    trim(p_name),
    'Desat des de ' || v_project.name,
    NULLIF(trim(COALESCE(p_category, '')), ''),
    true
  ) RETURNING id INTO v_tpl_id;

  FOR v_line IN
    SELECT *
    FROM data.project_lines
    WHERE project_id = p_project_id AND tenant_id = v_tenant_id
    ORDER BY position, created_at
  LOOP
    v_catalog_id := NULL;

    IF v_line.catalog_item_id IS NOT NULL THEN
      SELECT id INTO v_catalog_id
      FROM data.catalog_items
      WHERE id = v_line.catalog_item_id AND tenant_id = v_tenant_id AND is_active;
    END IF;

    IF v_catalog_id IS NULL THEN
      SELECT id INTO v_catalog_id
      FROM data.catalog_items
      WHERE tenant_id = v_tenant_id
        AND is_active
        AND kind = v_line.kind
        AND lower(trim(name)) = lower(trim(v_line.name))
      ORDER BY updated_at DESC
      LIMIT 1;
    END IF;

    IF v_catalog_id IS NULL AND v_mode = 'create_catalog' THEN
      INSERT INTO data.catalog_items (
        tenant_id, kind, name, description, unit, unit_price, tax_rate, category
      ) VALUES (
        v_tenant_id,
        v_line.kind,
        v_line.name,
        v_line.description,
        COALESCE(v_line.unit, 'u'),
        GREATEST(COALESCE(v_line.unit_price, 0), 0),
        COALESCE(v_line.tax_rate, 21),
        NULLIF(trim(COALESCE(p_category, '')), '')
      ) RETURNING id INTO v_catalog_id;
      v_created_catalog := array_append(v_created_catalog, v_catalog_id);
    END IF;

    IF v_catalog_id IS NULL THEN
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
        'name', v_line.name,
        'reason', 'unmatched_catalog'
      ));
      CONTINUE;
    END IF;

    INSERT INTO data.pricing_template_items (
      template_id, tenant_id, catalog_item_id, default_quantity,
      prompt_quantity, default_discount_pct, position
    ) VALUES (
      v_tpl_id,
      v_tenant_id,
      v_catalog_id,
      GREATEST(COALESCE(v_line.quantity, 1), 0),
      false,
      0,
      v_pos
    );

    v_item_count := v_item_count + 1;
    v_pos := v_pos + 1;
  END LOOP;

  IF v_item_count = 0 THEN
    DELETE FROM data.pricing_templates WHERE id = v_tpl_id AND tenant_id = v_tenant_id;
    RAISE EXCEPTION 'no_catalog_lines_to_save' USING ERRCODE = 'P0001';
  END IF;

  FOR v_cl IN
    SELECT DISTINCT cr.template_id
    FROM data.checklist_runs cr
    JOIN data.checklist_templates ct ON ct.id = cr.template_id
    WHERE cr.project_id = p_project_id
      AND cr.tenant_id = v_tenant_id
      AND cr.status <> 'superseded'
      AND ct.tenant_id = v_tenant_id
    ORDER BY 1
  LOOP
    INSERT INTO data.pricing_template_checklists (
      tenant_id, template_id, checklist_template_id, position
    ) VALUES (
      v_tenant_id, v_tpl_id, v_cl, v_cl_pos
    )
    ON CONFLICT (template_id, checklist_template_id) DO NOTHING;
    v_checklist_ids := array_append(v_checklist_ids, v_cl);
    v_cl_pos := v_cl_pos + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'template_id', v_tpl_id,
    'item_count', v_item_count,
    'skipped', v_skipped,
    'created_catalog_ids', to_jsonb(v_created_catalog),
    'checklist_template_ids', to_jsonb(v_checklist_ids)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.create_pricing_template_from_project(uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_pricing_template_from_project(uuid, text, text, text)
  TO authenticated;

COMMENT ON FUNCTION api.create_pricing_template_from_project IS
  'Desa un servei habitual des d''una OS: línies mapejades a catàleg + checklists dels runs. Owner/manager. No service_role.';

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

COMMENT ON FUNCTION api.apply_price_sheet IS
  'Aplica un full de preus (append/replace) i opcionalment una checklist. Sense pricing.edit: només PVP de catàleg. Mai inserix línia lliure a 0 €.';

NOTIFY pgrst, 'reload schema';
