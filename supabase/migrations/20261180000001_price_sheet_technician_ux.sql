-- Price sheet technician UX:
-- 1) commercial.pricing.edit on member default + backfill custom matrices
-- 2) Allow commercial_document_lines SET NULL of source_project_line_id
-- 3) assert_price_sheet_mutable on structure writers (not CloseOut actuals)
-- 4) create_quote_waiver blocked when quote/amendment is active
-- 5) quote_issued_warning respects valid_until

-- =============================================================================
-- 1. get_role_permissions: member default includes commercial.pricing.edit
-- =============================================================================
CREATE OR REPLACE FUNCTION data.get_role_permissions(
  p_role              text,
  p_custom_perms      jsonb DEFAULT NULL
)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_viewer_base  text[] := ARRAY[
    'storage.view', 'calendar.view', 'email.view', 'invoices.view',
    'members.view', 'sites.view', 'settings.view',
    'attendance.view_own', 'labor_calendar.view',
    'employees.directory.view',
    'assets.view',
    'recruitment.view'
  ];
  v_member_base  text[] := ARRAY[
    'storage.upload', 'calendar.edit', 'email.send', 'invoices.edit',
    'attendance.punch_own', 'absences.request',
    'ai.use',
    'employees.directory.view', 'employees.view',
    'assets.view',
    'recruitment.view',
    'field_service.reports.publish',
    'field_service.reports.regenerate',
    'field_service.reports.share',
    'field_service.reports.preview_as_customer',
    'contacts.portal.manage',
    'commercial.pricing.edit'
  ];
  v_manager_base text[] := ARRAY[
    'storage.delete', 'calendar.manage', 'email.manage', 'invoices.manage',
    'members.invite', 'sites.create', 'settings.manage', 'permissions.manage',
    'attendance.view_all', 'attendance.adjust', 'attendance.approve',
    'attendance.export', 'attendance.devices.manage',
    'labor_calendar.manage', 'absences.approve',
    'ai.configure', 'ai.tools.write',
    'employees.directory.view', 'employees.view', 'employees.manage',
    'employees.private.view', 'employees.private.manage', 'employees.private.reveal',
    'employees.skills.manage',
    'employees.lifecycle.view', 'employees.lifecycle.manage',
    'employees.contracts.view', 'employees.contracts.manage',
    'compliance.requirements.manage',
    'compliance.certifications.view', 'compliance.certifications.manage',
    'assets.view', 'assets.manage',
    'assets.employee_assignments.view', 'assets.employee_assignments.manage',
    'recruitment.view', 'recruitment.manage', 'recruitment.interview',
    'field_service.reports.publish',
    'field_service.reports.regenerate',
    'field_service.reports.share',
    'field_service.reports.revoke',
    'field_service.reports.preview_as_customer',
    'contacts.portal.manage',
    'commercial.pricing.edit'
  ];
  v_accumulated  text[] := '{}';
BEGIN
  IF p_role = 'owner' THEN
    RETURN ARRAY['*'];
  END IF;

  IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'viewer' THEN
    v_accumulated := v_accumulated ||
      ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'viewer'));
  ELSE
    v_accumulated := v_accumulated || v_viewer_base;
  END IF;

  IF p_role IN ('member', 'manager') THEN
    IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'member' THEN
      v_accumulated := v_accumulated ||
        ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'member'));
    ELSE
      v_accumulated := v_accumulated || v_member_base;
    END IF;
  END IF;

  IF p_role = 'manager' THEN
    IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'manager' THEN
      v_accumulated := v_accumulated ||
        ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'manager'));
    ELSE
      v_accumulated := v_accumulated || v_manager_base;
    END IF;
  END IF;

  RETURN ARRAY(SELECT DISTINCT unnest(v_accumulated));
END;
$$;

GRANT EXECUTE ON FUNCTION data.get_role_permissions(text, jsonb)
  TO authenticated, supabase_auth_admin;

-- Backfill: append commercial.pricing.edit to existing custom member matrices.
UPDATE data.tenants t
SET metadata = jsonb_set(
  COALESCE(t.metadata, '{}'::jsonb),
  '{role_permissions,member}',
  COALESCE(t.metadata -> 'role_permissions' -> 'member', '[]'::jsonb)
    || '["commercial.pricing.edit"]'::jsonb,
  true
)
WHERE t.metadata ? 'role_permissions'
  AND t.metadata -> 'role_permissions' ? 'member'
  AND jsonb_typeof(t.metadata -> 'role_permissions' -> 'member') = 'array'
  AND NOT (
    EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text(t.metadata -> 'role_permissions' -> 'member') AS p(val)
      WHERE p.val = 'commercial.pricing.edit'
    )
  );

-- get_tenant_role_permissions defaults: member includes commercial.pricing.edit
CREATE OR REPLACE FUNCTION api.get_tenant_role_permissions(
  p_tenant_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id       uuid;
  v_custom_perms    jsonb;
  v_updated_at      timestamptz;
  v_updated_by      uuid;

  v_viewer_default  text[] := ARRAY[
    'storage.view', 'calendar.view', 'email.view', 'invoices.view',
    'members.view', 'sites.view', 'settings.view',
    'employees.directory.view', 'assets.view', 'recruitment.view'
  ];
  v_member_default  text[] := ARRAY[
    'storage.upload', 'calendar.edit', 'email.send', 'invoices.edit',
    'ai.use',
    'employees.directory.view', 'employees.view',
    'assets.view', 'recruitment.view',
    'field_service.reports.publish',
    'field_service.reports.regenerate',
    'field_service.reports.share',
    'field_service.reports.preview_as_customer',
    'contacts.portal.manage',
    'attendance.punch_own', 'absences.request',
    'commercial.pricing.edit'
  ];
  v_manager_default text[] := ARRAY[
    'storage.delete', 'calendar.manage', 'email.manage', 'invoices.manage',
    'members.invite', 'sites.create', 'settings.manage', 'permissions.manage',
    'ai.configure', 'ai.tools.write',
    'employees.directory.view', 'employees.view', 'employees.manage',
    'employees.private.view', 'employees.private.manage', 'employees.private.reveal',
    'employees.skills.manage',
    'employees.lifecycle.view', 'employees.lifecycle.manage',
    'employees.contracts.view', 'employees.contracts.manage',
    'compliance.requirements.manage',
    'compliance.certifications.view', 'compliance.certifications.manage',
    'assets.view', 'assets.manage',
    'assets.employee_assignments.view', 'assets.employee_assignments.manage',
    'recruitment.view', 'recruitment.manage', 'recruitment.interview',
    'field_service.reports.publish',
    'field_service.reports.regenerate',
    'field_service.reports.share',
    'field_service.reports.revoke',
    'field_service.reports.preview_as_customer',
    'contacts.portal.manage',
    'commercial.pricing.edit',
    'attendance.approve'
  ];
BEGIN
  v_tenant_id := COALESCE(p_tenant_id, data.active_tenant_id());

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'No active tenant: pass p_tenant_id or set x-tenant-id header';
  END IF;

  IF NOT (data.jwt_user_tenants() ? v_tenant_id::text) THEN
    RAISE EXCEPTION 'Access denied for tenant %', v_tenant_id;
  END IF;

  SELECT
    t.metadata -> 'role_permissions',
    (t.metadata ->> 'permissions_updated_at')::timestamptz,
    (t.metadata ->> 'permissions_updated_by')::uuid
  INTO v_custom_perms, v_updated_at, v_updated_by
  FROM data.tenants t
  WHERE t.id = v_tenant_id;

  RETURN jsonb_build_object(
    'current_customization', COALESCE(v_custom_perms, '{}'::jsonb),
    'defaults', jsonb_build_object(
      'viewer',  to_jsonb(v_viewer_default),
      'member',  to_jsonb(v_member_default),
      'manager', to_jsonb(v_manager_default)
    ),
    'effective', jsonb_build_object(
      'owner',   to_jsonb(ARRAY['*']),
      'manager', to_jsonb(data.get_role_permissions('manager', v_custom_perms)),
      'member',  to_jsonb(data.get_role_permissions('member',  v_custom_perms)),
      'viewer',  to_jsonb(data.get_role_permissions('viewer',  v_custom_perms))
    ),
    'updated_at', to_jsonb(v_updated_at),
    'updated_by', to_jsonb(v_updated_by)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_tenant_role_permissions(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_tenant_role_permissions(uuid) TO authenticated;

-- =============================================================================
-- 2. Immutable lines: allow ON DELETE SET NULL of source_project_line_id
-- =============================================================================
CREATE OR REPLACE FUNCTION data.trg_commercial_document_lines_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_status text;
BEGIN
  SELECT status INTO v_status
  FROM data.commercial_documents
  WHERE id = COALESCE(NEW.document_id, OLD.document_id);

  IF v_status IS DISTINCT FROM 'draft' THEN
    IF TG_OP = 'UPDATE'
       AND NEW.source_project_line_id IS NULL
       AND OLD.source_project_line_id IS NOT NULL
       AND (to_jsonb(NEW) - 'source_project_line_id')
           IS NOT DISTINCT FROM (to_jsonb(OLD) - 'source_project_line_id')
    THEN
      RETURN NEW;
    END IF;

    RAISE EXCEPTION 'commercial_document_lines_immutable'
      USING ERRCODE = 'P0001';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

-- =============================================================================
-- 3. Price sheet lock while quote/amendment is issued and not expired
-- =============================================================================
CREATE OR REPLACE FUNCTION data.assert_price_sheet_mutable(p_project_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path = data
AS $$
BEGIN
  IF p_project_id IS NULL THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM data.commercial_documents d
    WHERE d.project_id = p_project_id
      AND d.doc_type IN ('quote', 'quote_amendment')
      AND d.status = 'issued'
      AND (d.valid_until IS NULL OR d.valid_until >= now())
  ) THEN
    RAISE EXCEPTION 'price_sheet_locked:quote_in_progress'
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.assert_price_sheet_mutable(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.assert_price_sheet_mutable(uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION data.assert_price_sheet_mutable(uuid) IS
  'Blocks structural price-sheet mutations while a quote or amendment is issued and not past valid_until.';

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
        AND (d.valid_until IS NULL OR d.valid_until >= now())
    )
    THEN jsonb_build_object(
      'quote_issued', true,
      'message', 'issued_quote_exists'
    )
    ELSE jsonb_build_object('quote_issued', false)
  END;
$$;

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

  PERFORM data.assert_price_sheet_mutable(p_project_id);

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

CREATE OR REPLACE FUNCTION api.delete_project_line(p_line_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_project_id uuid;
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT project_id INTO v_project_id
  FROM data.project_lines
  WHERE id = p_line_id AND tenant_id = v_tenant_id;

  IF v_project_id IS NOT NULL THEN
    PERFORM data.assert_price_sheet_mutable(v_project_id);
  END IF;

  DELETE FROM data.project_lines
  WHERE id        = p_line_id
    AND tenant_id = v_tenant_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.delete_project_line(uuid) TO authenticated;

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

  PERFORM data.assert_price_sheet_mutable(p_project_id);

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

-- Patch copy_project_lines / apply_price_sheet: insert assert after duplicate check.
-- Full REPLACE of both functions with assert added.

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

-- =============================================================================
-- 4. Waiver blocked when quote/amendment is active
-- =============================================================================
CREATE OR REPLACE FUNCTION api.create_quote_waiver(
  p_project_id uuid,
  p_legal_text text,
  p_work_description text,
  p_signature jsonb,
  p_client_op_id uuid,
  p_device text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_project data.projects%ROWTYPE;
  v_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF NULLIF(trim(p_work_description), '') IS NULL THEN
    RAISE EXCEPTION 'work_description_required' USING ERRCODE = 'P0001';
  END IF;
  IF NULLIF(trim(p_legal_text), '') IS NULL THEN
    RAISE EXCEPTION 'legal_text_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_project.tenant_id::text) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;
  IF v_project.client_id IS NULL THEN
    RAISE EXCEPTION 'project_client_required' USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM data.commercial_documents d
    WHERE d.project_id = p_project_id
      AND d.doc_type IN ('quote', 'quote_amendment')
      AND (
        d.status IN ('accepted', 'signed')
        OR (
          d.status = 'issued'
          AND (d.valid_until IS NULL OR d.valid_until >= now())
        )
      )
  ) THEN
    RAISE EXCEPTION 'waiver_blocked:quote_active'
      USING ERRCODE = 'P0001';
  END IF;

  SELECT id INTO v_id
  FROM data.quote_waivers
  WHERE tenant_id = v_project.tenant_id AND client_op_id = p_client_op_id;
  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  INSERT INTO data.quote_waivers (
    tenant_id, project_id, client_id, legal_text, work_description,
    signature, device, client_op_id, created_by
  ) VALUES (
    v_project.tenant_id, p_project_id, v_project.client_id,
    p_legal_text, p_work_description, p_signature, p_device,
    p_client_op_id, v_uid
  ) RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.create_quote_waiver(uuid, text, text, jsonb, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_quote_waiver(uuid, text, text, jsonb, uuid, text)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
