-- =============================================================================
-- REC-5 P1–P2
-- P1: list masked-only + reveal audit; block restriction/objection on hire/communicate/move
-- P2: rectification can update full_name/phone; export multi-download (prefetch-safe)
-- Settings columns already exist (hotfix P0); UI ships in tenant-portal.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Export multi-download counters
-- ---------------------------------------------------------------------------
ALTER TABLE data.applicant_data_requests
  ADD COLUMN IF NOT EXISTS export_download_count int NOT NULL DEFAULT 0
    CHECK (export_download_count >= 0);

ALTER TABLE data.applicant_data_requests
  ADD COLUMN IF NOT EXISTS export_max_downloads int NOT NULL DEFAULT 5
    CHECK (export_max_downloads >= 1 AND export_max_downloads <= 20);

COMMENT ON COLUMN data.applicant_data_requests.export_download_count IS
  'REC-5 P2: successful fetch_rights_export calls; token cleared when >= export_max_downloads.';

-- ---------------------------------------------------------------------------
-- 2. Helper: block processing when Art.18 / Art.21 flags set
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.assert_applicant_processing_allowed(p_applicant_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_restricted timestamptz;
  v_objection timestamptz;
BEGIN
  SELECT processing_restricted_at, objection_at
  INTO v_restricted, v_objection
  FROM data.applicants
  WHERE id = p_applicant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'applicant_missing';
  END IF;

  IF v_restricted IS NOT NULL THEN
    RAISE EXCEPTION 'processing_restricted'
      USING ERRCODE = 'check_violation',
            HINT = 'Applicant té limitació de tractament (Art. 18).';
  END IF;

  IF v_objection IS NOT NULL THEN
    RAISE EXCEPTION 'objection_recorded'
      USING ERRCODE = 'check_violation',
            HINT = 'Applicant ha exercit oposició (Art. 21).';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.assert_applicant_processing_allowed(uuid) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- 3. list: masked email only (+ applicant fields for rectification UI)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_applicant_data_requests(
  p_status text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_rows jsonb;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  IF NOT data.jwt_has_recruitment_permission(v_tenant, 'recruitment.rights') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501',
      HINT = 'Cal recruitment.rights';
  END IF;

  SELECT coalesce(jsonb_agg(row_to_json(x)::jsonb ORDER BY x.created_at DESC), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      r.id,
      r.applicant_id,
      r.request_type,
      r.status,
      r.fulfilled_via,
      data.mask_email(r.requester_email) AS requester_email_masked,
      r.message,
      r.rejection_reason,
      r.resolution_notes,
      r.due_at,
      r.sla_reminded_at,
      r.resolved_at,
      r.resolved_by,
      r.export_storage_path,
      r.created_at,
      ap.full_name AS applicant_full_name,
      ap.phone AS applicant_phone,
      ap.processing_restricted_at,
      ap.objection_at,
      CASE
        WHEN r.status = 'pending_review' AND r.due_at < now() THEN 'overdue'
        WHEN r.status = 'pending_review' AND r.due_at < now() + interval '3 days' THEN 'due_soon'
        ELSE 'ok'
      END AS sla_badge
    FROM data.applicant_data_requests r
    LEFT JOIN data.applicants ap ON ap.id = r.applicant_id
    WHERE r.tenant_id = v_tenant
      AND (p_status IS NULL OR r.status = p_status)
  ) x;

  RETURN jsonb_build_object('items', v_rows);
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_applicant_data_requests(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Reveal requester email (explicit + audit)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.reveal_applicant_data_request_email(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_req data.applicant_data_requests%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  IF NOT data.jwt_has_recruitment_permission(v_tenant, 'recruitment.rights') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501',
      HINT = 'Cal recruitment.rights';
  END IF;

  SELECT * INTO v_req
  FROM data.applicant_data_requests
  WHERE id = p_id AND tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  BEGIN
    INSERT INTO data.audit_logs (
      tenant_id, user_id, action, entity_type, entity_id, payload
    ) VALUES (
      v_tenant,
      auth.uid(),
      'recruitment.reveal_rights_requester_email',
      'applicant_data_request',
      v_req.id,
      jsonb_build_object(
        'request_type', v_req.request_type,
        'requester_email_masked', data.mask_email(v_req.requester_email)
      )
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'reveal email audit failed: %', SQLERRM;
  END;

  RETURN jsonb_build_object(
    'id', v_req.id,
    'requester_email', v_req.requester_email,
    'requester_email_masked', data.mask_email(v_req.requester_email)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.reveal_applicant_data_request_email(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Block hire / communicate / move on restriction & objection
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.move_application_stage(
  p_application_id uuid,
  p_stage_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_app data.applications%ROWTYPE;
  v_stage data.pipeline_stages%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT data.jwt_has_recruitment_permission(v_tenant, 'recruitment.manage') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501',
      HINT = 'Cal recruitment.manage';
  END IF;

  SELECT * INTO v_app
  FROM data.applications
  WHERE id = p_application_id AND tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found' USING HINT = 'Candidatura no trobada';
  END IF;

  PERFORM data.assert_applicant_processing_allowed(v_app.applicant_id);

  SELECT * INTO v_stage
  FROM data.pipeline_stages
  WHERE id = p_stage_id AND tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid_stage' USING HINT = 'Etapa no vàlida';
  END IF;

  IF v_stage.job_posting_id IS NOT NULL AND v_stage.job_posting_id <> v_app.job_posting_id THEN
    RAISE EXCEPTION 'invalid_stage' USING HINT = 'Etapa no pertany a aquesta oferta';
  END IF;

  UPDATE data.applications SET
    stage_id = p_stage_id,
    updated_at = now()
  WHERE id = v_app.id;

  RETURN jsonb_build_object(
    'application_id', v_app.id,
    'stage_id', p_stage_id,
    'candidate_visible_status', (
      SELECT candidate_visible_status FROM data.applications WHERE id = v_app.id
    ),
    'outcome_communicated_at', (
      SELECT outcome_communicated_at FROM data.applications WHERE id = v_app.id
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.move_application_stage(uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION api.communicate_application_outcome(
  p_application_id uuid,
  p_outcome_kind text DEFAULT 'rejected',
  p_prefs_base_url text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_app data.applications%ROWTYPE;
  v_applicant data.applicants%ROWTYPE;
  v_posting data.job_postings%ROWTYPE;
  v_token text;
  v_token_hash text;
  v_prefs_url text := '';
  v_expires timestamptz;
  v_kind text;
  v_base text;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT data.jwt_has_recruitment_permission(v_tenant, 'recruitment.manage') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501',
      HINT = 'Cal recruitment.manage';
  END IF;

  v_kind := COALESCE(nullif(trim(p_outcome_kind), ''), 'rejected');
  IF v_kind NOT IN ('rejected', 'withdrawn', 'hired_next_steps') THEN
    RAISE EXCEPTION 'invalid_outcome_kind';
  END IF;

  SELECT * INTO v_app
  FROM data.applications
  WHERE id = p_application_id AND tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  IF v_app.outcome_communicated_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'application_id', v_app.id,
      'already_communicated', true,
      'candidate_visible_status', v_app.candidate_visible_status
    );
  END IF;

  SELECT * INTO v_applicant FROM data.applicants WHERE id = v_app.applicant_id;
  SELECT * INTO v_posting FROM data.job_postings WHERE id = v_app.job_posting_id;

  PERFORM data.assert_applicant_processing_allowed(v_app.applicant_id);

  v_base := NULLIF(btrim(COALESCE(p_prefs_base_url, '')), '');
  IF v_base IS NULL THEN
    v_base := data.resolve_candidate_portal_base_url(v_tenant);
  ELSE
    v_base := rtrim(v_base, '/');
  END IF;

  IF v_kind IN ('rejected', 'withdrawn') AND v_base IS NOT NULL THEN
    v_token := encode(gen_random_bytes(24), 'hex');
    v_token_hash := encode(digest(v_token, 'sha256'), 'hex');
    v_expires := now() + interval '30 days';
    v_prefs_url := v_base || '/recruitment/preferences?token=' || v_token;
  END IF;

  UPDATE data.applications SET
    outcome_communicated_at = now(),
    outcome_kind = v_kind,
    process_closed_at = COALESCE(process_closed_at, now()),
    post_rejection_token_hash = CASE
      WHEN v_kind IN ('rejected', 'withdrawn') THEN v_token_hash
      ELSE post_rejection_token_hash
    END,
    post_rejection_token_expires_at = CASE
      WHEN v_kind IN ('rejected', 'withdrawn') THEN v_expires
      ELSE post_rejection_token_expires_at
    END,
    updated_at = now()
  WHERE id = v_app.id;

  IF v_kind IN ('rejected', 'withdrawn') THEN
    BEGIN
      PERFORM api.enqueue_email(jsonb_build_object(
        'tenant_id', v_tenant,
        'idempotency_key', 'recruitment-rejected-' || v_app.id::text,
        'to', jsonb_build_array(v_applicant.email),
        'event_type', 'recruitment.application_rejected',
        'locale', 'ca',
        'template_variables', jsonb_build_object(
          'applicant_name', v_applicant.full_name,
          'job_title', v_posting.title,
          'preferences_url', v_prefs_url,
          'prefs_expires_at', CASE
            WHEN v_expires IS NULL THEN ''
            ELSE to_char(v_expires AT TIME ZONE 'Europe/Madrid', 'YYYY-MM-DD')
          END
        )
      ));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'communicate_application_outcome: email failed: %', SQLERRM;
    END;
  END IF;

  INSERT INTO data.applicant_consent_events (
    tenant_id, applicant_id, application_id, event_type, legal_text_version, payload
  ) VALUES (
    v_tenant, v_app.applicant_id, v_app.id, 'outcome_communicated', 'v1',
    jsonb_build_object(
      'outcome_kind', v_kind,
      'prefs_link', (v_prefs_url <> '')
    )
  );

  RETURN jsonb_build_object(
    'application_id', v_app.id,
    'already_communicated', false,
    'outcome_kind', v_kind,
    'candidate_visible_status', 'closed',
    'prefs_link', (v_prefs_url <> '')
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.communicate_application_outcome(uuid, text, text)
  TO authenticated;

CREATE OR REPLACE FUNCTION api.hire_application(
  p_application_id uuid,
  p_site_id uuid DEFAULT NULL,
  p_department_id uuid DEFAULT NULL,
  p_starts_on date DEFAULT NULL,
  p_job_title text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_app data.applications%ROWTYPE;
  v_applicant data.applicants%ROWTYPE;
  v_posting data.job_postings%ROWTYPE;
  v_employee_id uuid;
  v_stage_hire uuid;
  v_site uuid;
  v_dept uuid;
  v_title text;
  v_role text;
  v_lifecycle text;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  -- Prefer JWT global_role (tests / hook); COALESCE so NULL cannot bypass IF NOT.
  v_role := data.jwt_user_tenants() -> v_tenant::text ->> 'global_role';
  IF NOT (
    data.jwt_has_recruitment_permission(v_tenant, 'recruitment.manage')
    AND (
      data.jwt_has_permission(v_tenant, 'employees.manage')
      OR COALESCE(v_role, '') IN ('owner', 'manager')
    )
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501',
      HINT = 'Cal recruitment.manage i employees.manage (o owner/manager)';
  END IF;

  SELECT * INTO v_app
  FROM data.applications
  WHERE id = p_application_id AND tenant_id = v_tenant
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  IF v_app.hired_employee_id IS NOT NULL THEN
    SELECT lifecycle_state INTO v_lifecycle
    FROM data.employees WHERE id = v_app.hired_employee_id;
    RETURN jsonb_build_object(
      'application_id', v_app.id,
      'employee_id', v_app.hired_employee_id,
      'lifecycle_state', v_lifecycle,
      'already_hired', true
    );
  END IF;

  IF v_app.outcome_kind IN ('rejected', 'withdrawn') THEN
    RAISE EXCEPTION 'already_closed_as_rejected'
      USING HINT = 'La candidatura ja s''ha comunicat com a rebuig/retirada.';
  END IF;

  SELECT * INTO v_applicant FROM data.applicants WHERE id = v_app.applicant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'applicant_missing';
  END IF;

  PERFORM data.assert_applicant_processing_allowed(v_app.applicant_id);

  SELECT * INTO v_posting FROM data.job_postings WHERE id = v_app.job_posting_id;

  v_site := COALESCE(p_site_id, v_posting.site_id);
  v_dept := COALESCE(p_department_id, v_posting.department_id);
  v_title := COALESCE(
    nullif(trim(p_job_title), ''),
    nullif(trim(v_posting.title), ''),
    'Empleat'
  );

  INSERT INTO data.employees (
    tenant_id, site_id, department_id, full_name, email, phone,
    job_title, status, starts_on, metadata
  ) VALUES (
    v_tenant, v_site, v_dept, v_applicant.full_name, v_applicant.email, v_applicant.phone,
    v_title, 'active', COALESCE(p_starts_on, CURRENT_DATE),
    jsonb_build_object(
      'source', 'recruitment_hire',
      'application_id', v_app.id,
      'applicant_id', v_applicant.id,
      'job_posting_id', v_posting.id
    )
  )
  RETURNING id INTO v_employee_id;

  INSERT INTO data.employee_lifecycle_events (
    tenant_id, employee_id, from_state, to_state, reason_code,
    effective_on, triggered_by, source, metadata
  ) VALUES (
    v_tenant, v_employee_id, NULL, 'onboarding', 'hire_from_ats',
    COALESCE(p_starts_on, CURRENT_DATE), auth.uid(), 'manual',
    jsonb_build_object(
      'application_id', v_app.id,
      'applicant_id', v_applicant.id,
      'job_posting_id', v_posting.id
    )
  );

  SELECT id INTO v_stage_hire
  FROM data.pipeline_stages
  WHERE tenant_id = v_tenant
    AND is_terminal_hire
    AND (job_posting_id = v_app.job_posting_id OR job_posting_id IS NULL)
  ORDER BY job_posting_id NULLS LAST, position
  LIMIT 1;

  UPDATE data.applications SET
    hired_employee_id = v_employee_id,
    hired_at = now(),
    stage_id = COALESCE(v_stage_hire, stage_id),
    outcome_communicated_at = COALESCE(outcome_communicated_at, now()),
    outcome_kind = 'hired_next_steps',
    process_closed_at = COALESCE(process_closed_at, now()),
    updated_at = now()
  WHERE id = v_app.id;

  INSERT INTO data.applicant_consent_events (
    tenant_id, applicant_id, application_id, event_type, legal_text_version, payload
  ) VALUES (
    v_tenant, v_app.applicant_id, v_app.id, 'outcome_communicated', 'v1',
    jsonb_build_object(
      'outcome_kind', 'hired_next_steps',
      'employee_id', v_employee_id
    )
  );

  BEGIN
    PERFORM api.enqueue_email(jsonb_build_object(
      'tenant_id', v_tenant,
      'idempotency_key', 'recruitment-hired-' || v_app.id::text,
      'to', jsonb_build_array(v_applicant.email),
      'event_type', 'recruitment.application_hired_next_steps',
      'locale', 'ca',
      'template_variables', jsonb_build_object(
        'applicant_name', v_applicant.full_name,
        'job_title', v_title
      )
    ));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'hire_application: email failed: %', SQLERRM;
  END;

  PERFORM data.log_audit_event(
    v_tenant,
    auth.uid(),
    v_site,
    'recruitment.hire_application',
    'application',
    v_app.id,
    jsonb_build_object(
      'employee_id', v_employee_id,
      'job_posting_id', v_posting.id,
      'applicant_id', v_applicant.id
    )
  );

  SELECT lifecycle_state INTO v_lifecycle
  FROM data.employees WHERE id = v_employee_id;

  RETURN jsonb_build_object(
    'application_id', v_app.id,
    'employee_id', v_employee_id,
    'lifecycle_state', COALESCE(v_lifecycle, 'onboarding'),
    'already_hired', false
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.hire_application(uuid, uuid, uuid, date, text)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. Rectification: optional PII field updates + notes
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.resolve_applicant_data_request(uuid, text, text, text, text);

CREATE OR REPLACE FUNCTION api.resolve_applicant_data_request(
  p_id uuid,
  p_action text,
  p_rejection_reason text DEFAULT NULL,
  p_export_base_url text DEFAULT NULL,
  p_resolution_notes text DEFAULT NULL,
  p_rectify_full_name text DEFAULT NULL,
  p_rectify_phone text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_req data.applicant_data_requests%ROWTYPE;
  v_applicant data.applicants%ROWTYPE;
  v_action text;
  v_token text;
  v_token_hash text;
  v_expires timestamptz;
  v_export jsonb;
  v_path text;
  v_url text;
  v_label text;
  v_purged int;
  v_notes text;
  v_new_name text;
  v_new_phone text;
  v_fields_changed boolean := false;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  IF NOT data.jwt_has_recruitment_permission(v_tenant, 'recruitment.rights') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501',
      HINT = 'Cal recruitment.rights';
  END IF;

  v_action := lower(trim(p_action));
  IF v_action NOT IN ('approve', 'reject') THEN
    RAISE EXCEPTION 'invalid_action';
  END IF;

  SELECT * INTO v_req
  FROM data.applicant_data_requests
  WHERE id = p_id AND tenant_id = v_tenant
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  IF v_req.status <> 'pending_review' THEN
    RAISE EXCEPTION 'already_resolved';
  END IF;

  v_notes := NULLIF(btrim(COALESCE(p_resolution_notes, '')), '');
  v_label := data.rights_request_type_label(v_req.request_type);

  IF v_action = 'reject' THEN
    IF NULLIF(btrim(COALESCE(p_rejection_reason, '')), '') IS NULL THEN
      RAISE EXCEPTION 'rejection_reason_required';
    END IF;

    UPDATE data.applicant_data_requests SET
      status = 'rejected',
      fulfilled_via = 'rejected_with_reason',
      rejection_reason = btrim(p_rejection_reason),
      resolution_notes = v_notes,
      resolved_at = now(),
      resolved_by = auth.uid(),
      updated_at = now()
    WHERE id = v_req.id;

    BEGIN
      PERFORM api.enqueue_email(jsonb_build_object(
        'tenant_id', v_tenant,
        'idempotency_key', 'rights-reject-' || v_req.id::text,
        'to', jsonb_build_array(v_req.requester_email),
        'event_type', 'recruitment.rights_rejected',
        'locale', 'ca',
        'template_variables', jsonb_build_object(
          'request_type_label', v_label,
          'rejection_reason', btrim(p_rejection_reason),
          'tenant_name', (SELECT name FROM data.tenants WHERE id = v_tenant)
        )
      ));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'rights_rejected email failed: %', SQLERRM;
    END;

    RETURN jsonb_build_object('id', v_req.id, 'status', 'rejected', 'fulfilled_via', 'rejected_with_reason');
  END IF;

  -- APPROVE paths (reuse logic from REC-5c with rectification upgrade)
  IF v_req.request_type IN ('access', 'portability') THEN
    IF v_req.applicant_id IS NULL THEN
      RAISE EXCEPTION 'applicant_missing';
    END IF;
    v_export := data.build_applicant_access_export(v_tenant, v_req.applicant_id);
    v_token := encode(gen_random_bytes(24), 'hex');
    v_token_hash := encode(digest(v_token, 'sha256'), 'hex');
    v_expires := now() + interval '7 days';
    v_path := 'rights/' || v_tenant::text || '/' || v_req.id::text || '.json';
    IF COALESCE(trim(p_export_base_url), '') <> '' THEN
      v_url := rtrim(trim(p_export_base_url), '/')
        || '/api/recruitment/rights-export?token=' || v_token;
    ELSE
      v_url := '';
    END IF;

    UPDATE data.applicant_data_requests SET
      status = 'fulfilled',
      fulfilled_via = 'email_export',
      export_json = v_export,
      export_storage_path = v_path,
      export_token_hash = v_token_hash,
      export_token_expires_at = v_expires,
      export_download_count = 0,
      export_max_downloads = 5,
      resolution_notes = v_notes,
      resolved_at = now(),
      resolved_by = auth.uid(),
      updated_at = now()
    WHERE id = v_req.id;

    BEGIN
      PERFORM api.enqueue_email(jsonb_build_object(
        'tenant_id', v_tenant,
        'idempotency_key', 'rights-access-' || v_req.id::text,
        'to', jsonb_build_array(v_req.requester_email),
        'event_type', 'recruitment.rights_access_fulfilled',
        'locale', 'ca',
        'template_variables', jsonb_build_object(
          'applicant_name', COALESCE(
            (SELECT full_name FROM data.applicants WHERE id = v_req.applicant_id),
            v_req.requester_email
          ),
          'export_url', v_url,
          'export_expires_at', to_char(v_expires AT TIME ZONE 'Europe/Madrid', 'YYYY-MM-DD')
        )
      ));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'rights_access_fulfilled email failed: %', SQLERRM;
    END;

    RETURN jsonb_build_object(
      'id', v_req.id, 'status', 'fulfilled', 'fulfilled_via', 'email_export',
      'export_storage_path', v_path
    );
  END IF;

  IF v_req.request_type = 'erasure' THEN
    IF v_req.applicant_id IS NULL THEN
      RAISE EXCEPTION 'applicant_missing';
    END IF;
    v_purged := data.purge_applicant_for_rights(v_tenant, v_req.applicant_id);

    UPDATE data.applicant_data_requests SET
      status = 'fulfilled',
      fulfilled_via = 'purge',
      applicant_id = NULL,
      resolution_notes = v_notes,
      resolved_at = now(),
      resolved_by = auth.uid(),
      updated_at = now()
    WHERE id = v_req.id;

    BEGIN
      PERFORM api.enqueue_email(jsonb_build_object(
        'tenant_id', v_tenant,
        'idempotency_key', 'rights-erasure-' || v_req.id::text,
        'to', jsonb_build_array(v_req.requester_email),
        'event_type', 'recruitment.rights_erasure_fulfilled',
        'locale', 'ca',
        'template_variables', jsonb_build_object(
          'tenant_name', (SELECT name FROM data.tenants WHERE id = v_tenant)
        )
      ));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'rights_erasure_fulfilled email failed: %', SQLERRM;
    END;

    RETURN jsonb_build_object(
      'id', v_req.id, 'status', 'fulfilled', 'fulfilled_via', 'purge',
      'purged_applications', v_purged
    );
  END IF;

  IF v_req.applicant_id IS NULL THEN
    RAISE EXCEPTION 'applicant_missing';
  END IF;
  SELECT * INTO v_applicant FROM data.applicants WHERE id = v_req.applicant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'applicant_missing';
  END IF;

  IF v_req.request_type = 'rectification' THEN
    v_new_name := NULLIF(btrim(COALESCE(p_rectify_full_name, '')), '');
    v_new_phone := NULLIF(btrim(COALESCE(p_rectify_phone, '')), '');

    IF v_notes IS NULL AND v_new_name IS NULL AND v_new_phone IS NULL THEN
      RAISE EXCEPTION 'resolution_notes_required'
        USING HINT = 'Cal notes i/o canvis de nom/telèfon';
    END IF;

    IF v_new_name IS NOT NULL AND v_new_name IS DISTINCT FROM v_applicant.full_name THEN
      UPDATE data.applicants SET full_name = v_new_name, updated_at = now()
      WHERE id = v_applicant.id;
      v_fields_changed := true;
    END IF;

    IF p_rectify_phone IS NOT NULL THEN
      -- empty string clears phone
      UPDATE data.applicants SET
        phone = NULLIF(btrim(p_rectify_phone), ''),
        updated_at = now()
      WHERE id = v_applicant.id
        AND phone IS DISTINCT FROM NULLIF(btrim(p_rectify_phone), '');
      IF FOUND THEN
        v_fields_changed := true;
      END IF;
    END IF;

    IF v_notes IS NULL AND NOT v_fields_changed THEN
      RAISE EXCEPTION 'resolution_notes_required';
    END IF;

    UPDATE data.applicant_data_requests SET
      status = 'fulfilled',
      fulfilled_via = 'field_update',
      resolution_notes = COALESCE(v_notes, 'fields_updated'),
      resolved_at = now(),
      resolved_by = auth.uid(),
      updated_at = now()
    WHERE id = v_req.id;

    BEGIN
      PERFORM api.enqueue_email(jsonb_build_object(
        'tenant_id', v_tenant,
        'idempotency_key', 'rights-rectify-' || v_req.id::text,
        'to', jsonb_build_array(v_req.requester_email),
        'event_type', 'recruitment.rights_rectification_fulfilled',
        'locale', 'ca',
        'template_variables', jsonb_build_object(
          'resolution_notes', COALESCE(v_notes, 'Dades actualitzades')
        )
      ));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'rights_rectification_fulfilled email failed: %', SQLERRM;
    END;

    RETURN jsonb_build_object(
      'id', v_req.id,
      'status', 'fulfilled',
      'fulfilled_via', 'field_update',
      'fields_changed', v_fields_changed
    );
  END IF;

  IF v_req.request_type = 'restriction' THEN
    UPDATE data.applicants SET
      processing_restricted_at = COALESCE(processing_restricted_at, now()),
      updated_at = now()
    WHERE id = v_applicant.id;

    UPDATE data.applicant_data_requests SET
      status = 'fulfilled',
      fulfilled_via = 'restriction_flag',
      resolution_notes = v_notes,
      resolved_at = now(),
      resolved_by = auth.uid(),
      updated_at = now()
    WHERE id = v_req.id;

    BEGIN
      PERFORM api.enqueue_email(jsonb_build_object(
        'tenant_id', v_tenant,
        'idempotency_key', 'rights-restrict-' || v_req.id::text,
        'to', jsonb_build_array(v_req.requester_email),
        'event_type', 'recruitment.rights_restriction_fulfilled',
        'locale', 'ca',
        'template_variables', jsonb_build_object(
          'restricted_at', to_char(now() AT TIME ZONE 'Europe/Madrid', 'YYYY-MM-DD')
        )
      ));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'rights_restriction_fulfilled email failed: %', SQLERRM;
    END;

    RETURN jsonb_build_object('id', v_req.id, 'status', 'fulfilled', 'fulfilled_via', 'restriction_flag');
  END IF;

  IF v_req.request_type = 'objection' THEN
    IF v_notes IS NULL THEN
      RAISE EXCEPTION 'resolution_notes_required';
    END IF;

    UPDATE data.applicants SET
      objection_at = COALESCE(objection_at, now()),
      talent_pool_until = NULL,
      updated_at = now()
    WHERE id = v_applicant.id;

    UPDATE data.applicant_data_requests SET
      status = 'fulfilled',
      fulfilled_via = 'preference_update',
      resolution_notes = v_notes,
      resolved_at = now(),
      resolved_by = auth.uid(),
      updated_at = now()
    WHERE id = v_req.id;

    BEGIN
      PERFORM api.enqueue_email(jsonb_build_object(
        'tenant_id', v_tenant,
        'idempotency_key', 'rights-object-' || v_req.id::text,
        'to', jsonb_build_array(v_req.requester_email),
        'event_type', 'recruitment.rights_objection_fulfilled',
        'locale', 'ca',
        'template_variables', jsonb_build_object(
          'resolution_notes', v_notes
        )
      ));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'rights_objection_fulfilled email failed: %', SQLERRM;
    END;

    RETURN jsonb_build_object('id', v_req.id, 'status', 'fulfilled', 'fulfilled_via', 'preference_update');
  END IF;

  RAISE EXCEPTION 'invalid_request_type';
END;
$$;

GRANT EXECUTE ON FUNCTION api.resolve_applicant_data_request(uuid, text, text, text, text, text, text)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. Prefetch-safe export: allow N downloads within TTL
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.fetch_rights_export(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public, extensions
AS $$
DECLARE
  v_hash text;
  v_req data.applicant_data_requests%ROWTYPE;
  v_payload jsonb;
  v_count int;
  v_max int;
BEGIN
  IF COALESCE(trim(p_token), '') = '' THEN
    RAISE EXCEPTION 'invalid_token';
  END IF;

  v_hash := encode(digest(trim(p_token), 'sha256'), 'hex');

  SELECT * INTO v_req
  FROM data.applicant_data_requests
  WHERE export_token_hash = v_hash
    AND export_token_expires_at > now()
    AND status = 'fulfilled'
    AND fulfilled_via = 'email_export'
  FOR UPDATE;

  IF NOT FOUND OR v_req.export_json IS NULL THEN
    RAISE EXCEPTION 'invalid_or_expired_token';
  END IF;

  v_payload := v_req.export_json;
  v_count := COALESCE(v_req.export_download_count, 0) + 1;
  v_max := COALESCE(v_req.export_max_downloads, 5);

  IF v_count >= v_max THEN
    UPDATE data.applicant_data_requests SET
      export_download_count = v_count,
      export_token_hash = NULL,
      export_token_expires_at = NULL,
      export_json = NULL,
      updated_at = now()
    WHERE id = v_req.id;
  ELSE
    UPDATE data.applicant_data_requests SET
      export_download_count = v_count,
      updated_at = now()
    WHERE id = v_req.id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'export_storage_path', v_req.export_storage_path,
    'downloads_remaining', GREATEST(v_max - v_count, 0),
    'payload', v_payload
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.fetch_rights_export(text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
