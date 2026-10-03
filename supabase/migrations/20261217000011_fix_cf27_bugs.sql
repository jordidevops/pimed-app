-- CF-27 bugfix:
-- 1) Atomic issue_invoice_from_delivery_notes (+ resume orphan draft)
-- 2) prepare_commercial_export_batch honors client_op_id
-- 3) member base role loses invoices.edit

-- ---------------------------------------------------------------------------
-- 1. get_role_permissions: member without invoices.edit
-- ---------------------------------------------------------------------------
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
    'storage.upload', 'calendar.edit', 'email.send',
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

  -- CF-27: members must not inherit invoices.* from viewer base.
  -- Explicit member customizations (tenant overrides) are kept.
  IF p_role = 'member' THEN
    v_accumulated := ARRAY(
      SELECT DISTINCT u
      FROM unnest(v_accumulated) AS u
      WHERE u NOT LIKE 'invoices.%'
         OR (
           p_custom_perms IS NOT NULL
           AND p_custom_perms ? 'member'
           AND u IN (
             SELECT jsonb_array_elements_text(p_custom_perms -> 'member')
           )
         )
    );
  END IF;

  RETURN ARRAY(SELECT DISTINCT unnest(v_accumulated));
END;
$$;

GRANT EXECUTE ON FUNCTION data.get_role_permissions(text, jsonb)
  TO authenticated, supabase_auth_admin;

-- ---------------------------------------------------------------------------
-- 2. Atomic issue from delivery notes (+ resume orphan draft)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.issue_invoice_from_delivery_notes(
  p_delivery_note_ids uuid[],
  p_client_op_id uuid,
  p_issued_on date DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_erp_reference text DEFAULT NULL
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
  v_existing_status text;
  v_sorted uuid[];
  v_dn_id uuid;
  v_link_invoice uuid;
  v_link_status text;
  v_draft_id uuid;
  v_issued_id uuid;
  v_erp text := NULLIF(btrim(COALESCE(p_erp_reference, '')), '');
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

  SELECT d.id, d.status
  INTO v_existing, v_existing_status
  FROM data.commercial_documents d
  WHERE d.tenant_id = v_tenant
    AND d.client_op_id = p_client_op_id
    AND d.doc_type = 'invoice'
  LIMIT 1;

  IF v_existing IS NOT NULL THEN
    IF v_existing_status = 'issued' THEN
      RETURN v_existing;
    END IF;
    IF v_existing_status = 'draft' THEN
      v_issued_id := api.issue_invoice(v_existing, p_client_op_id, p_issued_on, NULL, NULL);
      IF v_erp IS NOT NULL THEN
        PERFORM api.set_commercial_document_external_ref(v_issued_id, v_erp, 'manual', NULL);
      END IF;
      RETURN v_issued_id;
    END IF;
    RAISE EXCEPTION 'invoice_not_cancellable' USING ERRCODE = 'P0001';
  END IF;

  SELECT ARRAY_AGG(DISTINCT x ORDER BY x)
  INTO v_sorted
  FROM unnest(p_delivery_note_ids) AS x;

  FOREACH v_dn_id IN ARRAY v_sorted LOOP
    SELECT link.invoice_id, inv.status
    INTO v_link_invoice, v_link_status
    FROM data.invoice_delivery_notes link
    JOIN data.commercial_documents inv ON inv.id = link.invoice_id
    WHERE link.delivery_note_id = v_dn_id
      AND link.released_at IS NULL
    LIMIT 1;

    IF v_link_invoice IS NOT NULL THEN
      IF v_link_status = 'issued' THEN
        RAISE EXCEPTION 'delivery_already_invoiced' USING ERRCODE = 'P0001';
      END IF;
      IF v_link_status = 'draft' THEN
        IF v_draft_id IS NULL THEN
          v_draft_id := v_link_invoice;
        ELSIF v_draft_id IS DISTINCT FROM v_link_invoice THEN
          RAISE EXCEPTION 'delivery_already_invoiced' USING ERRCODE = 'P0001';
        END IF;
      ELSE
        RAISE EXCEPTION 'delivery_already_invoiced' USING ERRCODE = 'P0001';
      END IF;
    END IF;
  END LOOP;

  IF v_draft_id IS NOT NULL THEN
    -- Resume orphan draft: issue it (idempotent on event client_op_id).
    v_issued_id := api.issue_invoice(v_draft_id, p_client_op_id, p_issued_on, NULL, NULL);
    IF v_erp IS NOT NULL THEN
      PERFORM api.set_commercial_document_external_ref(v_issued_id, v_erp, 'manual', NULL);
    END IF;
    RETURN v_issued_id;
  END IF;

  v_draft_id := api.create_invoice_draft_from_delivery_notes(
    v_sorted,
    p_client_op_id,
    p_issued_on,
    p_notes
  );
  v_issued_id := api.issue_invoice(v_draft_id, p_client_op_id, p_issued_on, NULL, NULL);
  IF v_erp IS NOT NULL THEN
    PERFORM api.set_commercial_document_external_ref(v_issued_id, v_erp, 'manual', NULL);
  END IF;
  RETURN v_issued_id;
END;
$$;

REVOKE ALL ON FUNCTION api.issue_invoice_from_delivery_notes(uuid[], uuid, date, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.issue_invoice_from_delivery_notes(uuid[], uuid, date, text, text)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.issue_invoice_from_delivery_notes(uuid[], uuid, date, text, text) IS
  'CF-27: create+issue invoice from DNs in one TX; resumes orphan draft; idempotent by client_op_id.';

-- ---------------------------------------------------------------------------
-- 3. Export batch client_op_id
-- ---------------------------------------------------------------------------
ALTER TABLE data.commercial_export_batches
  ADD COLUMN IF NOT EXISTS client_op_id uuid;

CREATE UNIQUE INDEX IF NOT EXISTS uq_ceb_tenant_client_op
  ON data.commercial_export_batches (tenant_id, client_op_id)
  WHERE client_op_id IS NOT NULL;

CREATE OR REPLACE VIEW api.commercial_export_batches
  WITH (security_invoker = true) AS
SELECT
  id, tenant_id, profile_id, period_from, period_to, status, schema_version,
  row_count, failed_count, checksum, storage_path, file_node_id,
  created_by, created_at, finalized_at, claimed_at, expires_at, error_text,
  client_op_id
FROM data.commercial_export_batches
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.commercial_export_batches TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.prepare_commercial_export_batch(
  p_period_from date,
  p_period_to date,
  p_profile_id uuid DEFAULT NULL,
  p_client_op_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant uuid := data.active_tenant_id();
  v_profile_id uuid;
  v_batch_id uuid;
  v_ok int := 0;
  v_fail int := 0;
  v_doc data.commercial_documents%ROWTYPE;
  v_errors jsonb;
  v_existing data.commercial_export_batches%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_invoice_permission(v_tenant, 'invoices.export');

  IF p_period_from IS NULL OR p_period_to IS NULL OR p_period_to < p_period_from THEN
    RAISE EXCEPTION 'invalid_period' USING ERRCODE = 'P0001';
  END IF;

  IF p_client_op_id IS NOT NULL THEN
    SELECT * INTO v_existing
    FROM data.commercial_export_batches
    WHERE tenant_id = v_tenant
      AND client_op_id = p_client_op_id;
    IF FOUND THEN
      IF v_existing.status IN ('preparing', 'ready') THEN
        RETURN jsonb_build_object(
          'batch_id', v_existing.id,
          'profile_id', v_existing.profile_id,
          'status', v_existing.status,
          'row_count', v_existing.row_count,
          'failed_count', v_existing.failed_count,
          'period_from', v_existing.period_from,
          'period_to', v_existing.period_to
        );
      END IF;
      -- failed: free the op id so a new batch can reuse it
      UPDATE data.commercial_export_batches
      SET client_op_id = NULL
      WHERE id = v_existing.id;
    END IF;
  END IF;

  IF p_profile_id IS NOT NULL THEN
    SELECT id INTO v_profile_id
    FROM data.commercial_export_profiles
    WHERE id = p_profile_id AND tenant_id = v_tenant AND active;
    IF v_profile_id IS NULL THEN
      RAISE EXCEPTION 'export_profile_not_found' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    v_profile_id := data.ensure_canonical_export_profile(v_tenant);
  END IF;

  INSERT INTO data.commercial_export_batches (
    tenant_id, profile_id, period_from, period_to, status, schema_version,
    created_by, expires_at, client_op_id
  ) VALUES (
    v_tenant, v_profile_id, p_period_from, p_period_to, 'preparing', '1',
    v_uid, now() + interval '1 hour', p_client_op_id
  )
  RETURNING id INTO v_batch_id;

  FOR v_doc IN
    SELECT d.*
    FROM data.commercial_documents d
    WHERE d.tenant_id = v_tenant
      AND d.doc_type = 'invoice'
      AND d.status = 'issued'
      AND d.issued_on IS NOT NULL
      AND d.issued_on >= p_period_from
      AND d.issued_on <= p_period_to
    ORDER BY d.issued_on, d.doc_number, d.id
  LOOP
    v_errors := data.validate_invoice_for_export(v_doc.id);
    IF jsonb_array_length(v_errors) = 0 THEN
      INSERT INTO data.commercial_export_batch_documents (
        batch_id, document_id, tenant_id, content_hash,
        validation_status, validation_errors
      ) VALUES (
        v_batch_id, v_doc.id, v_tenant, v_doc.content_hash,
        'ok', '[]'::jsonb
      );
      v_ok := v_ok + 1;
    ELSE
      INSERT INTO data.commercial_export_batch_documents (
        batch_id, document_id, tenant_id, content_hash,
        validation_status, validation_errors
      ) VALUES (
        v_batch_id, v_doc.id, v_tenant, v_doc.content_hash,
        'failed', v_errors
      );
      v_fail := v_fail + 1;
    END IF;
  END LOOP;

  UPDATE data.commercial_export_batches SET
    row_count = v_ok,
    failed_count = v_fail,
    error_text = CASE
      WHEN v_ok = 0 THEN 'no_valid_documents'
      ELSE NULL
    END,
    status = CASE WHEN v_ok = 0 THEN 'failed' ELSE status END
  WHERE id = v_batch_id;

  RETURN jsonb_build_object(
    'batch_id', v_batch_id,
    'profile_id', v_profile_id,
    'status', CASE WHEN v_ok = 0 THEN 'failed' ELSE 'preparing' END,
    'row_count', v_ok,
    'failed_count', v_fail,
    'period_from', p_period_from,
    'period_to', p_period_to
  );
END;
$$;

REVOKE ALL ON FUNCTION api.prepare_commercial_export_batch(date, date, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.prepare_commercial_export_batch(date, date, uuid, uuid)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
