-- CF-27 / Sales 2 (SQL): invoices.review / invoices.export + assert helper.
-- Gates invoice DEFINER RPCs with active_tenant_id + permission.

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
    'invoices.review', 'invoices.export',
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
    'commercial.pricing.edit',
    'commercial.costs.view'
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

CREATE OR REPLACE FUNCTION api.update_tenant_role_permissions(
  p_permissions jsonb,
  p_tenant_id   uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id   uuid;
  v_global_role text;
  v_role_key    text;
  v_perm_key    text;
  v_old_perms   jsonb;

  v_valid_keys  text[] := ARRAY[
    'storage.view', 'storage.upload', 'storage.delete', 'storage.manage',
    'calendar.view', 'calendar.edit', 'calendar.manage',
    'email.view', 'email.send', 'email.manage',
    'invoices.view', 'invoices.edit', 'invoices.manage',
    'invoices.review', 'invoices.export',
    'members.view', 'members.invite', 'members.manage',
    'sites.view', 'sites.create', 'sites.manage',
    'settings.view', 'settings.manage',
    'permissions.manage',
    'ai.use', 'ai.configure', 'ai.tools.write',
    'employees.directory.view', 'employees.view', 'employees.manage',
    'employees.private.view', 'employees.private.manage', 'employees.private.reveal', 'employees.skills.manage',
    'employees.lifecycle.view', 'employees.lifecycle.manage',
    'employees.contracts.view', 'employees.contracts.manage', 'employees.contracts.approve',
    'employees.compensation.view', 'employees.compensation.edit',
    'compliance.requirements.manage',
    'compliance.certifications.view', 'compliance.certifications.manage',
    'compliance.medical_clearance.view', 'compliance.medical_clearance.manage',
    'assets.view', 'assets.manage',
    'assets.employee_assignments.view', 'assets.employee_assignments.manage',
    'recruitment.view', 'recruitment.manage', 'recruitment.interview', 'recruitment.rights',
    'field_service.reports.publish', 'field_service.reports.regenerate',
    'field_service.reports.share', 'field_service.reports.revoke',
    'field_service.reports.preview_as_customer',
    'contacts.portal.manage',
    'commercial.pricing.edit',
    'commercial.costs.view',
    'attendance.punch_own', 'attendance.approve', 'absences.request'
  ];
  v_valid_roles text[] := ARRAY['viewer', 'member', 'manager'];
BEGIN
  v_tenant_id := COALESCE(p_tenant_id, data.active_tenant_id());

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'No active tenant: pass p_tenant_id or set x-tenant-id header';
  END IF;

  IF jsonb_typeof(p_permissions) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'p_permissions must be a JSON object';
  END IF;

  v_global_role := data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role';
  IF COALESCE(v_global_role, '') <> 'owner' THEN
    RAISE EXCEPTION 'Only tenant owners can modify role permissions';
  END IF;

  FOR v_role_key IN SELECT jsonb_object_keys(p_permissions)
  LOOP
    IF NOT (v_role_key = ANY(v_valid_roles)) THEN
      RAISE EXCEPTION 'Invalid role key: %. Valid roles are: viewer, member, manager', v_role_key;
    END IF;

    IF jsonb_typeof(p_permissions -> v_role_key) <> 'array' THEN
      RAISE EXCEPTION 'Permissions for role % must be an array', v_role_key;
    END IF;

    FOR v_perm_key IN
      SELECT jsonb_array_elements_text(p_permissions -> v_role_key)
    LOOP
      IF NOT (v_perm_key = ANY(v_valid_keys)) THEN
        RAISE EXCEPTION 'Invalid permission key: ''%''. Check permissions.ts ALL_PERMISSION_KEYS', v_perm_key;
      END IF;
    END LOOP;
  END LOOP;

  SELECT metadata -> 'role_permissions'
  INTO v_old_perms
  FROM data.tenants
  WHERE id = v_tenant_id;

  UPDATE data.tenants
  SET metadata = COALESCE(metadata, '{}') || jsonb_build_object(
    'role_permissions',       p_permissions,
    'permissions_updated_at', now(),
    'permissions_updated_by', auth.uid()
  )
  WHERE id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tenant % not found', v_tenant_id;
  END IF;

  PERFORM data.log_audit_event(
    v_tenant_id,
    auth.uid(),
    NULL,
    'ROLE_PERMISSIONS_UPDATED',
    'tenant',
    v_tenant_id,
    jsonb_build_object(
      'old', COALESCE(v_old_perms, '{}'::jsonb),
      'new', p_permissions
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION api.update_tenant_role_permissions(jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_tenant_role_permissions(jsonb, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION data.assert_invoice_permission(
  p_tenant_id uuid,
  p_permission text
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF COALESCE(auth.role(), '') = 'service_role' THEN
    RETURN;
  END IF;
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_tenant_id IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  IF data.active_tenant_id() IS DISTINCT FROM p_tenant_id THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'P0001';
  END IF;
  IF NOT COALESCE(data.jwt_has_permission(p_tenant_id, p_permission), false) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'P0001';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.assert_invoice_permission(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.assert_invoice_permission(uuid, text)
  TO authenticated, service_role;

-- Gate write RPCs (recreate thin wrappers calling assert at start).
-- Patch by replacing function bodies' auth checks with permission asserts.

CREATE OR REPLACE FUNCTION api.create_invoice_draft_from_delivery_notes(
  p_delivery_note_ids uuid[],
  p_client_op_id uuid,
  p_issued_on date DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant uuid := data.active_tenant_id();
  v_existing uuid;
  v_client uuid;
  v_project uuid;
  v_projects uuid[] := ARRAY[]::uuid[];
  v_invoice_id uuid;
  v_dn data.commercial_documents%ROWTYPE;
  v_first data.commercial_documents%ROWTYPE;
  v_id_item uuid;
  v_sorted uuid[];
  v_pos int := 0;
  v_line record;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_invoice_permission(v_tenant, 'invoices.edit');
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_delivery_note_ids IS NULL OR cardinality(p_delivery_note_ids) = 0 THEN
    RAISE EXCEPTION 'invoice_delivery_notes_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT id INTO v_existing
  FROM data.commercial_documents
  WHERE tenant_id = v_tenant
    AND client_op_id = p_client_op_id;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  SELECT ARRAY_AGG(DISTINCT x ORDER BY x)
  INTO v_sorted
  FROM unnest(p_delivery_note_ids) AS x;

  PERFORM 1
  FROM data.commercial_documents d
  WHERE d.id = ANY (v_sorted)
  ORDER BY d.id
  FOR UPDATE;

  FOREACH v_id_item IN ARRAY v_sorted LOOP
    SELECT * INTO v_dn FROM data.commercial_documents WHERE id = v_id_item;
    IF NOT FOUND
       OR v_dn.tenant_id IS DISTINCT FROM v_tenant
       OR NOT (data.jwt_user_tenants() ? v_dn.tenant_id::text) THEN
      RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
    END IF;
    IF v_dn.doc_type IS DISTINCT FROM 'delivery_note'
       OR v_dn.status NOT IN ('issued', 'signed', 'accepted')
       OR v_dn.client_id IS NULL THEN
      RAISE EXCEPTION 'invoice_delivery_invalid' USING ERRCODE = 'P0001';
    END IF;
    IF data.delivery_note_is_invoiced(v_dn.id) THEN
      RAISE EXCEPTION 'delivery_already_invoiced' USING ERRCODE = 'P0001';
    END IF;
    IF v_client IS NULL THEN
      v_client := v_dn.client_id;
      v_first := v_dn;
    ELSIF v_dn.client_id IS DISTINCT FROM v_client THEN
      RAISE EXCEPTION 'invoice_client_mismatch' USING ERRCODE = 'P0001';
    END IF;
    IF v_dn.project_id IS NOT NULL AND NOT (v_dn.project_id = ANY (v_projects)) THEN
      v_projects := v_projects || v_dn.project_id;
    END IF;
  END LOOP;

  IF cardinality(v_projects) = 1 THEN
    v_project := v_projects[1];
  ELSE
    v_project := NULL;
  END IF;

  INSERT INTO data.commercial_documents (
    tenant_id, doc_type, doc_number, client_id, project_id, contact_site_id,
    status, seller_snapshot, buyer_snapshot, service_address_snapshot,
    terms_text, locale, currency, subtotal, tax_breakdown, total,
    show_prices, issued_on, client_op_id, created_by, formalization_mode
  ) VALUES (
    v_tenant,
    'invoice',
    NULL,
    v_client,
    v_project,
    v_first.contact_site_id,
    'draft',
    v_first.seller_snapshot,
    v_first.buyer_snapshot,
    v_first.service_address_snapshot,
    NULLIF(btrim(COALESCE(p_notes, '')), ''),
    v_first.locale,
    v_first.currency,
    0, '[]'::jsonb, 0,
    true,
    p_issued_on,
    p_client_op_id,
    v_uid,
    'signed_quote'
  ) RETURNING id INTO v_invoice_id;

  INSERT INTO data.invoice_delivery_notes (invoice_id, delivery_note_id, tenant_id)
  SELECT v_invoice_id, dn_id, v_tenant
  FROM unnest(v_sorted) AS dn_id;

  FOR v_line IN
    SELECT cdl.*
    FROM unnest(v_sorted) AS dn_id
    JOIN data.commercial_document_lines cdl ON cdl.document_id = dn_id
    ORDER BY array_position(v_sorted, dn_id), cdl.position, cdl.created_at
  LOOP
    INSERT INTO data.commercial_document_lines (
      tenant_id, document_id, source_project_line_id, source_commercial_document_line_id,
      catalog_item_id, kind, name, description, unit, quantity, unit_price,
      discount_pct, tax_rate, tax_category, line_subtotal, line_tax, line_total, position
    ) VALUES (
      v_tenant, v_invoice_id, v_line.source_project_line_id, v_line.id,
      v_line.catalog_item_id, v_line.kind, v_line.name, v_line.description, v_line.unit,
      v_line.quantity, v_line.unit_price, v_line.discount_pct, v_line.tax_rate,
      v_line.tax_category, v_line.line_subtotal, v_line.line_tax, v_line.line_total, v_pos
    );
    v_pos := v_pos + 1;
  END LOOP;

  PERFORM data.recompute_commercial_document_totals(v_invoice_id);
  RETURN v_invoice_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.issue_invoice(
  p_invoice_id uuid,
  p_client_op_id uuid,
  p_issued_on date DEFAULT NULL,
  p_series_id uuid DEFAULT NULL,
  p_doc_number text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant uuid := data.active_tenant_id();
  v_doc data.commercial_documents%ROWTYPE;
  v_event_id uuid;
  v_number text;
  v_issued_on date;
  v_year int;
  v_hash text;
  v_dn_total integer := 0;
  v_inv_total integer := 0;
  v_origin text := 'allocated';
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_invoice_permission(v_tenant, 'invoices.edit');
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT id INTO v_event_id
  FROM data.commercial_document_events
  WHERE tenant_id = v_tenant
    AND client_op_id = p_client_op_id;
  IF v_event_id IS NOT NULL THEN
    RETURN p_invoice_id;
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_invoice_id
  FOR UPDATE;
  IF NOT FOUND
     OR v_doc.tenant_id IS DISTINCT FROM v_tenant
     OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_doc.doc_type IS DISTINCT FROM 'invoice' OR v_doc.status IS DISTINCT FROM 'draft' THEN
    RAISE EXCEPTION 'invoice_not_draft' USING ERRCODE = 'P0001';
  END IF;

  PERFORM 1
  FROM data.commercial_documents d
  JOIN data.invoice_delivery_notes link ON link.delivery_note_id = d.id
  WHERE link.invoice_id = v_doc.id
    AND link.released_at IS NULL
  ORDER BY d.id
  FOR UPDATE;

  IF NOT EXISTS (
    SELECT 1 FROM data.invoice_delivery_notes link
    WHERE link.invoice_id = v_doc.id AND link.released_at IS NULL
  ) THEN
    RAISE EXCEPTION 'invoice_delivery_notes_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT COALESCE(SUM(data.commercial_document_total_cents(d.total)), 0)::integer
  INTO v_dn_total
  FROM data.invoice_delivery_notes link
  JOIN data.commercial_documents d ON d.id = link.delivery_note_id
  WHERE link.invoice_id = v_doc.id
    AND link.released_at IS NULL;

  PERFORM data.recompute_commercial_document_totals(v_doc.id);
  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = v_doc.id;
  v_inv_total := data.commercial_document_total_cents(v_doc.total);
  IF v_inv_total IS DISTINCT FROM v_dn_total THEN
    RAISE EXCEPTION 'invoice_totals_mismatch: invoice=% dn=%', v_inv_total, v_dn_total
      USING ERRCODE = 'P0001';
  END IF;

  v_issued_on := COALESCE(p_issued_on, v_doc.issued_on, CURRENT_DATE);
  v_year := EXTRACT(YEAR FROM v_issued_on)::int;

  IF NULLIF(btrim(COALESCE(p_doc_number, '')), '') IS NOT NULL THEN
    v_number := btrim(p_doc_number);
    v_origin := 'external_migrated';
    IF EXISTS (
      SELECT 1 FROM data.commercial_documents d
      WHERE d.tenant_id = v_tenant
        AND d.doc_type = 'invoice'
        AND d.doc_number = v_number
        AND d.id IS DISTINCT FROM v_doc.id
    ) THEN
      RAISE EXCEPTION 'invoice_number_taken' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    v_number := data.allocate_commercial_document_number(v_tenant, 'invoice', v_year);
    v_origin := 'allocated';
  END IF;

  v_hash := encode(
    extensions.digest(
      convert_to(
        v_number || '|invoice|' || v_doc.subtotal::text || '|' || v_doc.total::text
        || '|' || COALESCE(v_doc.buyer_snapshot::text, '')
        || '|' || COALESCE(v_doc.seller_snapshot->>'name', ''),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  UPDATE data.commercial_documents
  SET doc_number = v_number,
      number_origin = v_origin,
      series_id = COALESCE(p_series_id, series_id),
      issued_on = v_issued_on,
      issued_at = now(),
      issued_by = v_uid,
      content_hash = v_hash,
      status = 'issued',
      updated_at = now()
  WHERE id = v_doc.id
    AND status = 'draft';

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, content_hash, client_op_id, payload
  ) VALUES (
    v_tenant, v_doc.id, 'issued', v_uid, v_hash, p_client_op_id,
    jsonb_build_object(
      'doc_type', 'invoice',
      'doc_number', v_number,
      'issued_on', v_issued_on,
      'total', v_doc.total,
      'number_origin', v_origin
    )
  );

  RETURN v_doc.id;
END;
$$;

CREATE OR REPLACE FUNCTION api.cancel_invoice(
  p_invoice_id uuid,
  p_client_op_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant uuid := data.active_tenant_id();
  v_doc data.commercial_documents%ROWTYPE;
  v_event_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_invoice_permission(v_tenant, 'invoices.edit');
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT id INTO v_event_id
  FROM data.commercial_document_events
  WHERE tenant_id = v_tenant
    AND client_op_id = p_client_op_id;
  IF v_event_id IS NOT NULL THEN
    RETURN p_invoice_id;
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_invoice_id
  FOR UPDATE;
  IF NOT FOUND
     OR v_doc.tenant_id IS DISTINCT FROM v_tenant
     OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_doc.doc_type IS DISTINCT FROM 'invoice' OR v_doc.status IS DISTINCT FROM 'issued' THEN
    RAISE EXCEPTION 'invoice_not_cancellable' USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.payments p
    WHERE p.tenant_id = v_doc.tenant_id
      AND p.document_id = v_doc.id
  ) THEN
    RAISE EXCEPTION 'invoice_has_payments' USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.commercial_document_external_refs r
    WHERE r.document_id = v_doc.id
      AND r.synced_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'invoice_externally_synced' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.commercial_documents
  SET status = 'cancelled', updated_at = now()
  WHERE id = v_doc.id;

  UPDATE data.invoice_delivery_notes
  SET released_at = now()
  WHERE invoice_id = v_doc.id
    AND released_at IS NULL;

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, content_hash, client_op_id, payload
  ) VALUES (
    v_doc.tenant_id, v_doc.id, 'invoice_cancelled', v_uid, v_doc.content_hash, p_client_op_id,
    jsonb_build_object('doc_number', v_doc.doc_number)
  );

  RETURN v_doc.id;
END;
$$;

-- Patch record_invoice_payment with permission gate (keep body from 000002).
CREATE OR REPLACE FUNCTION api.record_invoice_payment(
  p_invoice_id uuid,
  p_amount_cents integer,
  p_method text,
  p_reference text,
  p_client_op_id uuid,
  p_occurred_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant uuid := data.active_tenant_id();
  v_invoice data.commercial_documents%ROWTYPE;
  v_existing data.payments%ROWTYPE;
  v_payment_id uuid;
  v_left integer;
  v_slice integer;
  v_row record;
  v_open integer := 0;
  v_pos int := 0;
  v_allocations jsonb := '[]'::jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_invoice_permission(v_tenant, 'invoices.edit');
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_amount_cents IS NULL OR p_amount_cents <= 0 THEN
    RAISE EXCEPTION 'invalid_amount' USING ERRCODE = 'P0001';
  END IF;
  IF p_method NOT IN ('cash', 'card', 'transfer', 'bizum', 'payment_link') THEN
    RAISE EXCEPTION 'invalid_payment_method' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_existing
  FROM data.payments
  WHERE tenant_id = v_tenant
    AND client_op_id = p_client_op_id;
  IF FOUND THEN
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'delivery_note_id', a.delivery_note_id,
        'amount_cents', a.amount_cents,
        'position', a.position
      ) ORDER BY a.position
    ), '[]'::jsonb)
    INTO v_allocations
    FROM data.payment_allocations a
    WHERE a.payment_id = v_existing.id;

    RETURN jsonb_build_object(
      'payment_id', v_existing.id,
      'amount_cents', v_existing.amount_cents,
      'allocations', v_allocations,
      'idempotent', true
    );
  END IF;

  SELECT * INTO v_invoice
  FROM data.commercial_documents
  WHERE id = p_invoice_id
  FOR UPDATE;
  IF NOT FOUND
     OR v_invoice.tenant_id IS DISTINCT FROM v_tenant
     OR NOT (data.jwt_user_tenants() ? v_invoice.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_invoice.doc_type IS DISTINCT FROM 'invoice' OR v_invoice.status IS DISTINCT FROM 'issued' THEN
    RAISE EXCEPTION 'invoice_not_collectable' USING ERRCODE = 'P0001';
  END IF;

  PERFORM 1
  FROM data.commercial_documents d
  JOIN data.invoice_delivery_notes link ON link.delivery_note_id = d.id
  WHERE link.invoice_id = v_invoice.id
    AND link.released_at IS NULL
  ORDER BY d.id
  FOR UPDATE;

  SELECT COALESCE(SUM(x.remaining_cents), 0)::integer
  INTO v_open
  FROM (
    SELECT
      CASE
        WHEN d.project_id IS NOT NULL THEN COALESCE((
          SELECT b.remaining_cents
          FROM data.delivery_balances(v_invoice.tenant_id, ARRAY[d.project_id]) b
          WHERE b.delivery_note_id = d.id
        ), 0)
        ELSE GREATEST(
          0,
          data.commercial_document_total_cents(d.total)
          - COALESCE((
              SELECT SUM(p.amount_cents)::integer FROM data.payments p
              JOIN data.commercial_documents pd ON pd.id = p.document_id
              WHERE p.document_id = d.id AND pd.doc_type IS DISTINCT FROM 'invoice'
            ), 0)
          - COALESCE((
              SELECT SUM(a.amount_cents)::integer FROM data.payment_allocations a
              WHERE a.delivery_note_id = d.id
            ), 0)
        )
      END AS remaining_cents
    FROM data.invoice_delivery_notes link
    JOIN data.commercial_documents d ON d.id = link.delivery_note_id
    WHERE link.invoice_id = v_invoice.id
      AND link.released_at IS NULL
  ) x;

  IF p_amount_cents > v_open THEN
    RAISE EXCEPTION 'payment_exceeds_remaining' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.payments (
    tenant_id, document_id, amount_cents, method, reference,
    collected_by, occurred_at, client_op_id
  ) VALUES (
    v_invoice.tenant_id,
    v_invoice.id,
    p_amount_cents,
    p_method,
    NULLIF(btrim(COALESCE(p_reference, '')), ''),
    v_uid,
    COALESCE(p_occurred_at, now()),
    p_client_op_id
  ) RETURNING id INTO v_payment_id;

  v_left := p_amount_cents;
  FOR v_row IN
    SELECT
      d.id,
      CASE
        WHEN d.project_id IS NOT NULL THEN COALESCE((
          SELECT b.remaining_cents
          FROM data.delivery_balances(v_invoice.tenant_id, ARRAY[d.project_id]) b
          WHERE b.delivery_note_id = d.id
        ), 0)
        ELSE GREATEST(
          0,
          data.commercial_document_total_cents(d.total)
          - COALESCE((
              SELECT SUM(p.amount_cents)::integer FROM data.payments p
              JOIN data.commercial_documents pd ON pd.id = p.document_id
              WHERE p.document_id = d.id AND pd.doc_type IS DISTINCT FROM 'invoice'
            ), 0)
          - COALESCE((
              SELECT SUM(a.amount_cents)::integer FROM data.payment_allocations a
              WHERE a.delivery_note_id = d.id AND a.payment_id IS DISTINCT FROM v_payment_id
            ), 0)
        )
      END AS remaining_cents
    FROM data.invoice_delivery_notes link
    JOIN data.commercial_documents d ON d.id = link.delivery_note_id
    WHERE link.invoice_id = v_invoice.id
      AND link.released_at IS NULL
    ORDER BY COALESCE(d.issued_at, d.created_at), d.id
  LOOP
    v_slice := LEAST(v_left, v_row.remaining_cents);
    IF v_slice <= 0 THEN
      CONTINUE;
    END IF;

    INSERT INTO data.payment_allocations (
      tenant_id, payment_id, delivery_note_id, amount_cents, position
    ) VALUES (
      v_invoice.tenant_id, v_payment_id, v_row.id, v_slice, v_pos
    );

    v_allocations := v_allocations || jsonb_build_array(
      jsonb_build_object(
        'delivery_note_id', v_row.id,
        'amount_cents', v_slice,
        'position', v_pos
      )
    );
    v_pos := v_pos + 1;
    v_left := v_left - v_slice;
    EXIT WHEN v_left = 0;
  END LOOP;

  IF v_left <> 0 THEN
    RAISE EXCEPTION 'payment_allocation_incomplete' USING ERRCODE = 'P0001';
  END IF;

  RETURN jsonb_build_object(
    'payment_id', v_payment_id,
    'amount_cents', p_amount_cents,
    'allocations', v_allocations,
    'idempotent', false
  );
END;
$$;

REVOKE ALL ON FUNCTION api.create_invoice_draft_from_delivery_notes(uuid[], uuid, date, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.issue_invoice(uuid, uuid, date, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.cancel_invoice(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.record_invoice_payment(uuid, integer, text, text, uuid, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_invoice_draft_from_delivery_notes(uuid[], uuid, date, text)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.issue_invoice(uuid, uuid, date, uuid, text)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.cancel_invoice(uuid, uuid)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.record_invoice_payment(uuid, integer, text, text, uuid, timestamptz)
  TO authenticated, service_role;

COMMENT ON FUNCTION data.assert_invoice_permission(uuid, text) IS
  'Requires auth.uid(), active_tenant_id match, and jwt_has_permission for the invoice key.';

NOTIFY pgrst, 'reload schema';
