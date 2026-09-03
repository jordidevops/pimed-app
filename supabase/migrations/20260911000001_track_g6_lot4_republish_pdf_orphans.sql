-- Track G6 Lot 4 (G6.6 + G6.7 + G6.10): republicació, PDF async, neteja orfes

-- --- 1. Assignment versioning / supersede (G6.6) ---

ALTER TABLE data.employee_portal_document_assignments
  ADD COLUMN IF NOT EXISTS superseded_at timestamptz,
  ADD COLUMN IF NOT EXISTS protocol_version int NOT NULL DEFAULT 1;

CREATE INDEX IF NOT EXISTS idx_epda_employee_active_protocol
  ON data.employee_portal_document_assignments (employee_id, assignment_kind, published_at DESC)
  WHERE assignment_kind = 'attendance_protocol' AND superseded_at IS NULL;

CREATE OR REPLACE FUNCTION data.is_attendance_protocol_assignment_pending(
  p_assignment_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row record;
  v_sig_status text;
BEGIN
  SELECT a.acknowledged_at, a.signature_submission_id
  INTO v_row
  FROM data.employee_portal_document_assignments a
  WHERE a.id = p_assignment_id
    AND a.assignment_kind = 'attendance_protocol';

  IF NOT FOUND OR v_row.acknowledged_at IS NOT NULL THEN
    RETURN false;
  END IF;

  IF v_row.signature_submission_id IS NULL THEN
    RETURN true;
  END IF;

  SELECT ss.status INTO v_sig_status
  FROM data.signing_submissions ss
  WHERE ss.id = v_row.signature_submission_id;

  RETURN COALESCE(v_sig_status, '') <> 'completed';
END;
$$;

CREATE OR REPLACE FUNCTION data.supersede_pending_attendance_protocols(
  p_employee_id uuid,
  p_tenant_id   uuid,
  p_actor_id    uuid DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_count int;
  v_rec   record;
BEGIN
  v_count := 0;

  FOR v_rec IN
    SELECT a.id
    FROM data.employee_portal_document_assignments a
    WHERE a.employee_id = p_employee_id
      AND a.tenant_id = p_tenant_id
      AND a.assignment_kind = 'attendance_protocol'
      AND a.superseded_at IS NULL
      AND data.is_attendance_protocol_assignment_pending(a.id)
  LOOP
    UPDATE data.employee_portal_document_assignments
    SET superseded_at = now()
    WHERE id = v_rec.id;

    PERFORM data.log_attendance_employee_audit(
      p_tenant_id, p_actor_id,
      (SELECT site_id FROM data.employees WHERE id = p_employee_id),
      p_employee_id,
      'ATTENDANCE_PROTOCOL_SUPERSEDED',
      jsonb_build_object('assignment_id', v_rec.id)
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION data.next_attendance_protocol_version(
  p_employee_id uuid,
  p_tenant_id   uuid
)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT COALESCE(MAX(a.protocol_version), 0) + 1
  FROM data.employee_portal_document_assignments a
  WHERE a.employee_id = p_employee_id
    AND a.tenant_id = p_tenant_id
    AND a.assignment_kind = 'attendance_protocol';
$$;

-- --- 2. PDF async staging (G6.7) ---

ALTER TABLE data.attendance_protocol_bulk_job_items
  ADD COLUMN IF NOT EXISTS pdf_job_id uuid REFERENCES data.document_pdf_jobs(id) ON DELETE SET NULL;

ALTER TABLE data.attendance_protocol_bulk_job_items
  DROP CONSTRAINT IF EXISTS attendance_protocol_bulk_job_items_status_check;

ALTER TABLE data.attendance_protocol_bulk_job_items
  ADD CONSTRAINT attendance_protocol_bulk_job_items_status_check
  CHECK (status IN ('pending', 'processing', 'awaiting_pdf', 'succeeded', 'failed', 'skipped'));

CREATE TABLE IF NOT EXISTS data.attendance_protocol_publish_pending (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id         uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  pdf_job_id          uuid NOT NULL REFERENCES data.document_pdf_jobs(id) ON DELETE CASCADE,
  bulk_item_id        uuid REFERENCES data.attendance_protocol_bulk_job_items(id) ON DELETE SET NULL,
  initiated_by        uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  requires_signature  boolean NOT NULL DEFAULT false,
  signer_email        text,
  employee_name       text NOT NULL,
  status              text NOT NULL DEFAULT 'awaiting_pdf'
                      CHECK (status IN ('awaiting_pdf', 'ready', 'processing', 'completed', 'failed')),
  error_message       text,
  assignment_id       uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (pdf_job_id)
);

CREATE INDEX IF NOT EXISTS idx_appp_status_created
  ON data.attendance_protocol_publish_pending (status, created_at);

ALTER TABLE data.attendance_protocol_publish_pending ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS appp_manager_read ON data.attendance_protocol_publish_pending;
CREATE POLICY appp_manager_read ON data.attendance_protocol_publish_pending
  FOR SELECT TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND data.jwt_has_permission(tenant_id, 'attendance.manage', NULL)
  );

DROP POLICY IF EXISTS appp_service_all ON data.attendance_protocol_publish_pending;
CREATE POLICY appp_service_all ON data.attendance_protocol_publish_pending
  FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE OR REPLACE FUNCTION data.stage_attendance_protocol_publish_pending(
  p_tenant_id          uuid,
  p_employee_id        uuid,
  p_pdf_job_id         uuid,
  p_bulk_item_id       uuid DEFAULT NULL,
  p_initiated_by       uuid DEFAULT NULL,
  p_requires_signature boolean DEFAULT false,
  p_signer_email       text DEFAULT NULL,
  p_employee_name      text DEFAULT 'Empleat'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO data.attendance_protocol_publish_pending (
    tenant_id, employee_id, pdf_job_id, bulk_item_id, initiated_by,
    requires_signature, signer_email, employee_name
  ) VALUES (
    p_tenant_id, p_employee_id, p_pdf_job_id, p_bulk_item_id, p_initiated_by,
    p_requires_signature, p_signer_email, p_employee_name
  )
  ON CONFLICT (pdf_job_id) DO UPDATE SET
    updated_at = now(),
    status = 'awaiting_pdf'
  RETURNING id INTO v_id;

  IF p_bulk_item_id IS NOT NULL THEN
    UPDATE data.attendance_protocol_bulk_job_items
    SET status = 'awaiting_pdf', pdf_job_id = p_pdf_job_id
    WHERE id = p_bulk_item_id;
  END IF;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION data.service_mark_protocol_publish_pending_ready(p_pdf_job_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required';
  END IF;

  UPDATE data.attendance_protocol_publish_pending
  SET status = 'ready', updated_at = now()
  WHERE pdf_job_id = p_pdf_job_id
    AND status IN ('awaiting_pdf', 'ready')
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION data.service_claim_protocol_publish_pending(p_pending_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row record;
  v_job record;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required';
  END IF;

  UPDATE data.attendance_protocol_publish_pending
  SET status = 'processing', updated_at = now()
  WHERE id = p_pending_id AND status IN ('ready', 'processing')
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('claimed', false);
  END IF;

  SELECT j.status, j.result_version_id, j.last_error_message
  INTO v_job
  FROM data.document_pdf_jobs j
  WHERE j.id = v_row.pdf_job_id;

  IF v_job.status = 'completed' AND v_job.result_version_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'claimed', true,
      'pending', to_jsonb(v_row),
      'document_version_id', v_job.result_version_id
    );
  END IF;

  IF v_job.status IN ('failed', 'dead_letter') THEN
    UPDATE data.attendance_protocol_publish_pending
    SET status = 'failed', error_message = COALESCE(v_job.last_error_message, 'pdf_job_failed'), updated_at = now()
    WHERE id = p_pending_id;

    IF v_row.bulk_item_id IS NOT NULL THEN
      PERFORM data.service_complete_protocol_publish_item(
        v_row.bulk_item_id, 'failed', NULL, COALESCE(v_job.last_error_message, 'pdf_job_failed')
      );
    END IF;

    RETURN jsonb_build_object('claimed', false, 'failed', true);
  END IF;

  UPDATE data.attendance_protocol_publish_pending
  SET status = 'ready', updated_at = now()
  WHERE id = p_pending_id;

  RETURN jsonb_build_object('claimed', false, 'waiting_pdf', true);
END;
$$;

CREATE OR REPLACE FUNCTION data.service_complete_protocol_publish_pending(
  p_pending_id    uuid,
  p_assignment_id uuid,
  p_error_message text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row record;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required';
  END IF;

  SELECT * INTO v_row
  FROM data.attendance_protocol_publish_pending
  WHERE id = p_pending_id;

  IF NOT FOUND THEN RETURN; END IF;

  IF p_error_message IS NOT NULL THEN
    UPDATE data.attendance_protocol_publish_pending
    SET status = 'failed', error_message = p_error_message, updated_at = now()
    WHERE id = p_pending_id;

    IF v_row.bulk_item_id IS NOT NULL THEN
      PERFORM data.service_complete_protocol_publish_item(
        v_row.bulk_item_id, 'failed', NULL, p_error_message
      );
    END IF;
    RETURN;
  END IF;

  UPDATE data.attendance_protocol_publish_pending
  SET status = 'completed', assignment_id = p_assignment_id, updated_at = now()
  WHERE id = p_pending_id;

  IF v_row.bulk_item_id IS NOT NULL THEN
    PERFORM data.service_complete_protocol_publish_item(
      v_row.bulk_item_id, 'succeeded', p_assignment_id, NULL
    );
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION data.service_enqueue_protocol_finalize_after_pdf(p_pdf_job_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_pending_id uuid;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required';
  END IF;

  v_pending_id := data.service_mark_protocol_publish_pending_ready(p_pdf_job_id);
  IF v_pending_id IS NULL THEN
    RETURN;
  END IF;

  PERFORM pgmq.send(
    'attendance_protocol_publish_queue',
    jsonb_build_object(
      'task', 'finalize_attendance_protocol_pdf',
      'tenant_id', (SELECT tenant_id FROM data.attendance_protocol_publish_pending WHERE id = v_pending_id),
      'idempotency_key', 'protocol-finalize:' || v_pending_id::text,
      'pending_id', v_pending_id,
      'pdf_job_id', p_pdf_job_id,
      'enqueued_at', now()
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.get_attendance_protocol_publish_pending(p_pending_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
  SELECT jsonb_build_object(
    'id', p.id,
    'status', p.status,
    'employee_id', p.employee_id,
    'pdf_job_id', p.pdf_job_id,
    'assignment_id', p.assignment_id,
    'error_message', p.error_message,
    'pdf_job_status', j.status,
    'document_version_id', j.result_version_id
  )
  FROM data.attendance_protocol_publish_pending p
  LEFT JOIN data.document_pdf_jobs j ON j.id = p.pdf_job_id
  WHERE p.id = p_pending_id
    AND data.jwt_has_permission(p.tenant_id, 'attendance.manage', NULL);
$$;

GRANT EXECUTE ON FUNCTION api.get_attendance_protocol_publish_pending(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION api.stage_attendance_protocol_publish(
  p_employee_id        uuid,
  p_pdf_job_id         uuid,
  p_requires_signature boolean DEFAULT false,
  p_signer_email       text DEFAULT NULL,
  p_employee_name      text DEFAULT 'Empleat'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
  v_id  uuid;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id, e.full_name INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.manage', v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  v_id := data.stage_attendance_protocol_publish_pending(
    v_emp.tenant_id,
    p_employee_id,
    p_pdf_job_id,
    NULL,
    auth.uid(),
    p_requires_signature,
    p_signer_email,
    COALESCE(NULLIF(trim(p_employee_name), ''), v_emp.full_name)
  );

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.stage_attendance_protocol_publish(uuid, uuid, boolean, text, text) TO authenticated;

-- --- 3. Update assignment RPCs (G6.6) ---

CREATE OR REPLACE FUNCTION api.create_attendance_protocol_assignment(
  p_employee_id           uuid,
  p_document_version_id   uuid,
  p_signing_submission_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
  v_doc record;
  v_id  uuid;
  v_version int;
  v_superseded int;
  v_event text;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id INTO v_emp
  FROM data.employees e WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.manage', v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  SELECT d.tenant_id, d.title INTO v_doc
  FROM data.document_versions dv
  JOIN data.documents d ON d.id = dv.document_id
  WHERE dv.id = p_document_version_id;

  IF NOT FOUND OR v_doc.tenant_id IS DISTINCT FROM v_emp.tenant_id THEN
    RAISE EXCEPTION 'document_version_not_found';
  END IF;

  v_superseded := data.supersede_pending_attendance_protocols(
    p_employee_id, v_emp.tenant_id, auth.uid()
  );
  v_version := data.next_attendance_protocol_version(p_employee_id, v_emp.tenant_id);
  v_event := CASE WHEN v_version > 1 THEN 'ATTENDANCE_PROTOCOL_REPUBLISHED' ELSE 'ATTENDANCE_PROTOCOL_PUBLISHED' END;

  INSERT INTO data.employee_portal_document_assignments (
    tenant_id, employee_id, assignment_kind,
    document_version_id, published_by, signature_submission_id, protocol_version
  ) VALUES (
    v_emp.tenant_id, p_employee_id, 'attendance_protocol',
    p_document_version_id, auth.uid(), p_signing_submission_id, v_version
  )
  ON CONFLICT (employee_id, document_version_id) DO UPDATE SET
    published_at = now(),
    published_by = auth.uid(),
    signature_submission_id = COALESCE(EXCLUDED.signature_submission_id, data.employee_portal_document_assignments.signature_submission_id),
    acknowledged_at = NULL,
    superseded_at = NULL,
    protocol_version = EXCLUDED.protocol_version
  RETURNING id INTO v_id;

  PERFORM data.log_attendance_employee_audit(
    v_emp.tenant_id, auth.uid(), v_emp.site_id, p_employee_id,
    v_event,
    jsonb_build_object(
      'assignment_id', v_id,
      'document_version_id', p_document_version_id,
      'signing_submission_id', p_signing_submission_id,
      'protocol_version', v_version,
      'superseded_count', v_superseded
    )
  );

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION data.service_create_attendance_protocol_assignment(
  p_employee_id           uuid,
  p_document_version_id   uuid,
  p_published_by          uuid,
  p_signing_submission_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_emp record;
  v_doc record;
  v_id  uuid;
  v_version int;
  v_superseded int;
  v_event text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required';
  END IF;

  SELECT e.id, e.tenant_id, e.site_id INTO v_emp
  FROM data.employees e WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  SELECT d.tenant_id INTO v_doc
  FROM data.document_versions dv
  JOIN data.documents d ON d.id = dv.document_id
  WHERE dv.id = p_document_version_id;

  IF NOT FOUND OR v_doc.tenant_id IS DISTINCT FROM v_emp.tenant_id THEN
    RAISE EXCEPTION 'document_version_not_found';
  END IF;

  v_superseded := data.supersede_pending_attendance_protocols(
    p_employee_id, v_emp.tenant_id, p_published_by
  );
  v_version := data.next_attendance_protocol_version(p_employee_id, v_emp.tenant_id);
  v_event := CASE WHEN v_version > 1 THEN 'ATTENDANCE_PROTOCOL_REPUBLISHED' ELSE 'ATTENDANCE_PROTOCOL_PUBLISHED' END;

  INSERT INTO data.employee_portal_document_assignments (
    tenant_id, employee_id, assignment_kind,
    document_version_id, published_by, signature_submission_id, protocol_version
  ) VALUES (
    v_emp.tenant_id, p_employee_id, 'attendance_protocol',
    p_document_version_id, p_published_by, p_signing_submission_id, v_version
  )
  ON CONFLICT (employee_id, document_version_id) DO UPDATE SET
    published_at = now(),
    published_by = p_published_by,
    signature_submission_id = COALESCE(EXCLUDED.signature_submission_id, data.employee_portal_document_assignments.signature_submission_id),
    acknowledged_at = NULL,
    superseded_at = NULL,
    protocol_version = EXCLUDED.protocol_version
  RETURNING id INTO v_id;

  PERFORM data.log_attendance_employee_audit(
    v_emp.tenant_id, p_published_by, v_emp.site_id, p_employee_id,
    v_event,
    jsonb_build_object(
      'assignment_id', v_id,
      'document_version_id', p_document_version_id,
      'signing_submission_id', p_signing_submission_id,
      'protocol_version', v_version,
      'superseded_count', v_superseded,
      'source', 'bulk_worker'
    )
  );

  RETURN v_id;
END;
$$;

-- --- 4. Portal RPCs: exclude superseded ---

CREATE OR REPLACE FUNCTION api.employee_portal_list_documents(
  p_employee_id uuid,
  p_tenant_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_settings jsonb;
  v_requires_sig boolean;
  v_site_id uuid;
  v_rows jsonb := '[]'::jsonb;
  v_rec record;
  v_signing record;
  v_sign_url text;
  v_completed boolean;
  v_pending boolean;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM data.employees e
    WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id
  ) THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  SELECT e.site_id INTO v_site_id
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id;

  v_settings := data.merge_effective_settings_for_service(p_tenant_id, v_site_id);
  v_requires_sig := COALESCE((v_settings->>'attendance_protocol_requires_signature')::boolean, false);

  FOR v_rec IN
    SELECT
      a.id,
      a.assignment_kind,
      a.published_at,
      a.acknowledged_at,
      a.signature_submission_id,
      a.protocol_version,
      a.superseded_at,
      d.title,
      dv.id AS version_id,
      dv.mime_type,
      dv.file_path_or_url
    FROM data.employee_portal_document_assignments a
    JOIN data.document_versions dv ON dv.id = a.document_version_id
    JOIN data.documents d ON d.id = dv.document_id
    WHERE a.employee_id = p_employee_id
      AND a.tenant_id = p_tenant_id
      AND a.superseded_at IS NULL
    ORDER BY a.published_at DESC
    LIMIT 20
  LOOP
    v_sign_url := NULL;
    v_completed := false;
    v_pending := v_rec.acknowledged_at IS NULL;

    IF v_rec.signature_submission_id IS NOT NULL THEN
      SELECT ss.status, ss.signers INTO v_signing
      FROM data.signing_submissions ss
      WHERE ss.id = v_rec.signature_submission_id;

      v_completed := v_signing.status = 'completed';
      v_pending := NOT v_completed;

      IF NOT v_completed THEN
        SELECT s->>'signing_url' INTO v_sign_url
        FROM jsonb_array_elements(COALESCE(v_signing.signers, '[]'::jsonb)) s
        WHERE (s->>'role') = 'Empleat'
        LIMIT 1;
      END IF;
    ELSIF v_requires_sig AND v_rec.assignment_kind = 'attendance_protocol' THEN
      v_pending := v_rec.acknowledged_at IS NULL;
    END IF;

    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'id', v_rec.id,
      'assignment_kind', v_rec.assignment_kind,
      'title', v_rec.title,
      'published_at', v_rec.published_at,
      'acknowledged_at', v_rec.acknowledged_at,
      'protocol_version', v_rec.protocol_version,
      'requires_signature', v_requires_sig AND v_rec.assignment_kind = 'attendance_protocol',
      'signature_submission_id', v_rec.signature_submission_id,
      'signature_completed', v_completed,
      'employee_sign_url', v_sign_url,
      'is_pending', v_pending,
      'document_version_id', v_rec.version_id,
      'mime_type', v_rec.mime_type,
      'storage_path', v_rec.file_path_or_url
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'documents', v_rows,
    'settings', jsonb_build_object(
      'requires_signature', v_requires_sig,
      'required_before_punch', COALESCE((v_settings->>'attendance_protocol_required_before_punch')::boolean, false)
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.employee_portal_acknowledge_document(
  p_employee_id   uuid,
  p_tenant_id     uuid,
  p_assignment_id uuid
)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row record;
  v_settings jsonb;
  v_requires_sig boolean;
BEGIN
  SELECT a.*, e.site_id INTO v_row
  FROM data.employee_portal_document_assignments a
  JOIN data.employees e ON e.id = a.employee_id
  WHERE a.id = p_assignment_id
    AND a.employee_id = p_employee_id
    AND a.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'assignment_not_found';
  END IF;

  IF v_row.superseded_at IS NOT NULL THEN
    RAISE EXCEPTION 'assignment_superseded';
  END IF;

  v_settings := data.merge_effective_settings_for_service(p_tenant_id, v_row.site_id);
  v_requires_sig := COALESCE((v_settings->>'attendance_protocol_requires_signature')::boolean, false);

  IF v_requires_sig AND v_row.assignment_kind = 'attendance_protocol' THEN
    RAISE EXCEPTION 'signature_required' USING ERRCODE = 'check_violation';
  END IF;

  IF v_row.acknowledged_at IS NOT NULL THEN
    RETURN v_row.acknowledged_at;
  END IF;

  UPDATE data.employee_portal_document_assignments
  SET acknowledged_at = now()
  WHERE id = p_assignment_id
  RETURNING acknowledged_at INTO v_row.acknowledged_at;

  PERFORM data.log_attendance_employee_audit(
    p_tenant_id, NULL, v_row.site_id, p_employee_id,
    'ATTENDANCE_PROTOCOL_ACKNOWLEDGED',
    jsonb_build_object('assignment_id', p_assignment_id)
  );

  RETURN v_row.acknowledged_at;
END;
$$;

CREATE OR REPLACE FUNCTION api.employee_portal_has_pending_protocol(
  p_employee_id uuid,
  p_tenant_id   uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_settings jsonb;
  v_site_id uuid;
  v_required boolean;
BEGIN
  SELECT e.site_id INTO v_site_id
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  v_settings := data.merge_effective_settings_for_service(p_tenant_id, v_site_id);
  v_required := COALESCE((v_settings->>'attendance_protocol_required_before_punch')::boolean, false);

  IF NOT v_required THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM data.employee_portal_document_assignments a
    LEFT JOIN data.signing_submissions s ON s.id = a.signature_submission_id
    WHERE a.employee_id = p_employee_id
      AND a.tenant_id = p_tenant_id
      AND a.assignment_kind = 'attendance_protocol'
      AND a.superseded_at IS NULL
      AND (
        (a.signature_submission_id IS NULL AND a.acknowledged_at IS NULL)
        OR (a.signature_submission_id IS NOT NULL AND COALESCE(s.status, '') <> 'completed')
      )
  );
END;
$$;

-- --- 5. Orphan cleanup (G6.10) ---

CREATE OR REPLACE FUNCTION data.cleanup_orphan_attendance_protocol_documents(
  p_ttl_days    integer DEFAULT 30,
  p_batch_limit integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_deleted   int := 0;
  v_scanned   int := 0;
  v_rec       record;
  v_cutoff    timestamptz := now() - make_interval(days => GREATEST(p_ttl_days, 7));
BEGIN
  FOR v_rec IN
    SELECT d.id AS document_id, d.tenant_id, dv.id AS version_id, dv.file_path_or_url
    FROM data.documents d
    JOIN data.document_versions dv ON dv.document_id = d.id
    WHERE d.category = 'attendance'
      AND d.title LIKE 'Protocol de registre horari%'
      AND d.created_at < v_cutoff
      AND NOT EXISTS (
        SELECT 1
        FROM data.employee_portal_document_assignments a
        WHERE a.document_version_id = dv.id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM data.attendance_protocol_publish_pending p
        WHERE p.status IN ('awaiting_pdf', 'ready', 'processing')
          AND EXISTS (
            SELECT 1 FROM data.document_pdf_jobs j
            WHERE j.id = p.pdf_job_id AND j.result_version_id = dv.id
          )
      )
    ORDER BY d.created_at
    LIMIT GREATEST(p_batch_limit, 1)
  LOOP
    v_scanned := v_scanned + 1;

    IF v_rec.file_path_or_url IS NOT NULL
       AND v_rec.file_path_or_url LIKE (v_rec.tenant_id::text || '/%') THEN
      PERFORM pgmq.send('trash_deletion_queue', jsonb_build_object(
        'tenant_id',           v_rec.tenant_id,
        'idempotency_key',     'orphan-protocol-' || v_rec.version_id::text,
        'file_node_id',        v_rec.version_id,
        'storage_provider_id', NULL,
        'storage_key',         v_rec.file_path_or_url,
        'bucket',              'documents'
      ));
    END IF;

    DELETE FROM data.documents WHERE id = v_rec.document_id;
    v_deleted := v_deleted + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'scanned', v_scanned,
    'deleted', v_deleted,
    'ttl_days', p_ttl_days
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.run_attendance_protocol_orphan_cleanup_service(
  p_ttl_days    integer DEFAULT 30,
  p_batch_limit integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required';
  END IF;

  RETURN data.cleanup_orphan_attendance_protocol_documents(p_ttl_days, p_batch_limit);
END;
$$;

REVOKE ALL ON FUNCTION data.cleanup_orphan_attendance_protocol_documents(integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.cleanup_orphan_attendance_protocol_documents(integer, integer) FROM authenticated;
REVOKE ALL ON FUNCTION data.cleanup_orphan_attendance_protocol_documents(integer, integer) FROM anon;

GRANT EXECUTE ON FUNCTION api.run_attendance_protocol_orphan_cleanup_service(integer, integer) TO service_role;

GRANT EXECUTE ON FUNCTION data.stage_attendance_protocol_publish_pending(uuid, uuid, uuid, uuid, uuid, boolean, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION data.service_mark_protocol_publish_pending_ready(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION data.service_claim_protocol_publish_pending(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION data.service_complete_protocol_publish_pending(uuid, uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION data.service_enqueue_protocol_finalize_after_pdf(uuid) TO service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('cleanup-orphan-attendance-protocol-docs')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'cleanup-orphan-attendance-protocol-docs'
    );

    PERFORM cron.schedule(
      'cleanup-orphan-attendance-protocol-docs',
      '0 3 * * 0',
      'SELECT api.run_attendance_protocol_orphan_cleanup_service(30, 50)'
    );
  END IF;
END;
$$;

COMMENT ON FUNCTION data.supersede_pending_attendance_protocols IS
  'G6.6: invalida protocols pendents (L1/L2) en republicar.';

COMMENT ON FUNCTION data.stage_attendance_protocol_publish_pending IS
  'G6.7: espera pdf_job abans de crear assignació portal.';

COMMENT ON FUNCTION data.cleanup_orphan_attendance_protocol_documents IS
  'G6.10: elimina PDFs de protocol sense assignació després del TTL.';

-- --- 6. Active protocol helper (exclude superseded) ---

CREATE OR REPLACE FUNCTION data.employee_lacks_attendance_protocol(
  p_employee_id uuid,
  p_tenant_id   uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT NOT EXISTS (
    SELECT 1
    FROM data.employee_portal_document_assignments a
    WHERE a.employee_id = p_employee_id
      AND a.tenant_id = p_tenant_id
      AND a.assignment_kind = 'attendance_protocol'
      AND a.superseded_at IS NULL
  );
$$;

-- --- 7. Bulk job status: include awaiting_pdf ---

CREATE OR REPLACE FUNCTION data.refresh_attendance_protocol_bulk_job_status(p_job_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_job record;
  v_pending int;
  v_processing int;
BEGIN
  SELECT * INTO v_job FROM data.attendance_protocol_bulk_jobs WHERE id = p_job_id;
  IF NOT FOUND THEN RETURN; END IF;

  SELECT
    COUNT(*) FILTER (WHERE status IN ('pending', 'processing', 'awaiting_pdf')),
    COUNT(*) FILTER (WHERE status IN ('processing', 'awaiting_pdf'))
  INTO v_pending, v_processing
  FROM data.attendance_protocol_bulk_job_items
  WHERE job_id = p_job_id;

  IF v_pending = 0 THEN
    UPDATE data.attendance_protocol_bulk_jobs
    SET
      status = CASE
        WHEN succeeded_count = 0 AND failed_count > 0 THEN 'failed'::data.attendance_protocol_bulk_job_status
        WHEN failed_count > 0 THEN 'partial'::data.attendance_protocol_bulk_job_status
        ELSE 'completed'::data.attendance_protocol_bulk_job_status
      END,
      completed_at = COALESCE(completed_at, now()),
      updated_at = now()
    WHERE id = p_job_id;
  ELSIF v_processing > 0 OR v_job.status = 'queued' THEN
    UPDATE data.attendance_protocol_bulk_jobs
    SET
      status = 'processing'::data.attendance_protocol_bulk_job_status,
      started_at = COALESCE(started_at, now()),
      updated_at = now()
    WHERE id = p_job_id AND status IN ('queued', 'processing');
  END IF;
END;
$$;
