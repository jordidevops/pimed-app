-- =============================================================================
-- REC-5 hotfix P0
-- 1) Archive lot: prefs URL from settings/system; no dead tokens without URL
-- 2) Purge retention + Art.17: delete CV objects in recruitment-cvs
-- 3) SLA reminder: internal owners/managers (or settings emails), not candidate
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Settings columns
-- ---------------------------------------------------------------------------
ALTER TABLE data.recruitment_settings
  ADD COLUMN IF NOT EXISTS candidate_portal_base_url text,
  ADD COLUMN IF NOT EXISTS rights_sla_notify_emails text[] NOT NULL DEFAULT '{}';

COMMENT ON COLUMN data.recruitment_settings.candidate_portal_base_url IS
  'Public portal origin for post-rejection prefs links (e.g. https://portal.example). Required for usable tokens on archive batch.';
COMMENT ON COLUMN data.recruitment_settings.rights_sla_notify_emails IS
  'Optional internal recipients for rights SLA reminders. Empty = active global owners/managers.';

DROP VIEW IF EXISTS api.recruitment_settings;
CREATE VIEW api.recruitment_settings
WITH (security_invoker = true) AS
SELECT
  tenant_id,
  default_max_retention_months,
  expire_closes_process,
  rights_sla_days,
  rejection_notify_policy,
  privacy_policy_url,
  import_legal_basis,
  import_legal_basis_note,
  enforce_department_scope,
  analytics_min_cohort,
  candidate_portal_base_url,
  rights_sla_notify_emails,
  created_at,
  updated_at
FROM data.recruitment_settings;

GRANT SELECT, UPDATE ON api.recruitment_settings TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Resolve candidate portal base URL
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.resolve_candidate_portal_base_url(p_tenant_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_base text;
  v_dev_base text;
BEGIN
  SELECT NULLIF(btrim(candidate_portal_base_url), '')
  INTO v_base
  FROM data.recruitment_settings
  WHERE tenant_id = p_tenant_id;

  IF v_base IS NOT NULL THEN
    RETURN rtrim(v_base, '/');
  END IF;

  SELECT NULLIF(btrim(s.settings ->> 'dev_base_url'), '')
  INTO v_dev_base
  FROM data.system_settings s
  WHERE s.module = 'employee_portal'
  LIMIT 1;

  IF v_dev_base IS NOT NULL THEN
    RETURN rtrim(v_dev_base, '/');
  END IF;

  v_base := NULLIF(btrim(current_setting('app.public_portal_url', true)), '');
  IF v_base IS NOT NULL THEN
    RETURN rtrim(v_base, '/');
  END IF;

  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION data.resolve_candidate_portal_base_url(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.resolve_candidate_portal_base_url(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Delete CV from storage (bypasses protect_delete via allow flag)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.delete_recruitment_cv_storage(p_cv_storage_path text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = storage, public
AS $$
DECLARE
  v_path text := NULLIF(btrim(COALESCE(p_cv_storage_path, '')), '');
  v_deleted boolean := false;
BEGIN
  IF v_path IS NULL THEN
    RETURN false;
  END IF;

  PERFORM set_config('storage.allow_delete_query', 'true', true);

  DELETE FROM storage.objects
  WHERE bucket_id = 'recruitment-cvs'
    AND name = v_path;

  v_deleted := FOUND;
  RETURN v_deleted;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'delete_recruitment_cv_storage(%): %', v_path, SQLERRM;
  RETURN false;
END;
$$;

REVOKE ALL ON FUNCTION data.delete_recruitment_cv_storage(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.delete_recruitment_cv_storage(text)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Internal SLA recipients
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.recruitment_rights_sla_recipient_emails(p_tenant_id uuid)
RETURNS text[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_configured text[];
  v_emails text[];
BEGIN
  SELECT COALESCE(rights_sla_notify_emails, '{}')
  INTO v_configured
  FROM data.recruitment_settings
  WHERE tenant_id = p_tenant_id;

  IF v_configured IS NOT NULL AND cardinality(v_configured) > 0 THEN
    SELECT ARRAY(
      SELECT DISTINCT lower(btrim(e))
      FROM unnest(v_configured) AS e
      WHERE NULLIF(btrim(e), '') IS NOT NULL
        AND position('@' in e) > 0
    ) INTO v_emails;
    IF v_emails IS NOT NULL AND cardinality(v_emails) > 0 THEN
      RETURN v_emails;
    END IF;
  END IF;

  SELECT ARRAY(
    SELECT DISTINCT lower(btrim(p.email))
    FROM data.tenant_members tm
    JOIN data.profiles p ON p.id = tm.user_id
    WHERE tm.tenant_id = p_tenant_id
      AND tm.is_active = true
      AND tm.site_id IS NULL
      AND tm.role IN ('owner', 'manager')
      AND NULLIF(btrim(p.email), '') IS NOT NULL
      AND position('@' in p.email) > 0
    ORDER BY 1
  ) INTO v_emails;

  RETURN COALESCE(v_emails, '{}');
END;
$$;

REVOKE ALL ON FUNCTION data.recruitment_rights_sla_recipient_emails(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.recruitment_rights_sla_recipient_emails(uuid)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Archive batch: usable prefs URL or no token
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.communicate_posting_outcomes_internal(
  p_job_posting_id uuid,
  p_tenant_id uuid
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  r record;
  v_count int := 0;
  v_app data.applications%ROWTYPE;
  v_applicant data.applicants%ROWTYPE;
  v_posting data.job_postings%ROWTYPE;
  v_token text;
  v_token_hash text;
  v_expires timestamptz;
  v_base text;
  v_prefs_url text;
BEGIN
  SELECT * INTO v_posting FROM data.job_postings WHERE id = p_job_posting_id;
  v_base := data.resolve_candidate_portal_base_url(p_tenant_id);

  FOR r IN
    SELECT id FROM data.applications
    WHERE job_posting_id = p_job_posting_id
      AND tenant_id = p_tenant_id
      AND outcome_communicated_at IS NULL
  LOOP
    SELECT * INTO v_app FROM data.applications WHERE id = r.id;
    SELECT * INTO v_applicant FROM data.applicants WHERE id = v_app.applicant_id;

    v_token := NULL;
    v_token_hash := NULL;
    v_expires := NULL;
    v_prefs_url := '';

    IF v_base IS NOT NULL THEN
      v_token := encode(gen_random_bytes(24), 'hex');
      v_token_hash := encode(digest(v_token, 'sha256'), 'hex');
      v_expires := now() + interval '30 days';
      v_prefs_url := v_base || '/recruitment/preferences?token=' || v_token;
    END IF;

    UPDATE data.applications SET
      outcome_communicated_at = now(),
      outcome_kind = 'rejected',
      process_closed_at = COALESCE(process_closed_at, now()),
      post_rejection_token_hash = v_token_hash,
      post_rejection_token_expires_at = v_expires,
      updated_at = now()
    WHERE id = v_app.id;

    INSERT INTO data.applicant_consent_events (
      tenant_id, applicant_id, application_id, event_type, legal_text_version, payload
    ) VALUES (
      p_tenant_id, v_app.applicant_id, v_app.id, 'outcome_communicated', 'v1',
      jsonb_build_object(
        'outcome_kind', 'rejected',
        'batch', true,
        'prefs_link', (v_prefs_url <> '')
      )
    );

    BEGIN
      PERFORM api.enqueue_email(jsonb_build_object(
        'tenant_id', p_tenant_id,
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
      RAISE WARNING 'batch communicate email failed: %', SQLERRM;
    END;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

-- Single communicate: resolve base URL; no dead token without URL
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

-- ---------------------------------------------------------------------------
-- 6. Purge: delete CV storage then rows
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.purge_expired_applications()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, extensions, public
AS $$
DECLARE
  r record;
  v_count int := 0;
  v_email text;
  v_hmac text;
  v_remain int;
BEGIN
  FOR r IN
    SELECT a.id, a.tenant_id, a.applicant_id, a.cv_storage_path
    FROM data.applications a
    WHERE a.purge_at <= now()
    ORDER BY a.purge_at
    LIMIT 500
  LOOP
    SELECT email INTO v_email FROM data.applicants WHERE id = r.applicant_id;
    v_hmac := data.applicant_email_hmac(r.tenant_id, v_email);

    PERFORM data.delete_recruitment_cv_storage(r.cv_storage_path);

    DELETE FROM data.applicant_consent_events WHERE application_id = r.id;
    DELETE FROM data.applications WHERE id = r.id;

    INSERT INTO data.applicant_erasure_log (
      tenant_id, email_hmac, reason, scope, applications_count
    ) VALUES (
      r.tenant_id, v_hmac, 'retention_policy', 'application', 1
    );

    SELECT count(*) INTO v_remain
    FROM data.applications
    WHERE applicant_id = r.applicant_id;

    IF v_remain = 0 THEN
      IF NOT EXISTS (
        SELECT 1 FROM data.applicants ap
        WHERE ap.id = r.applicant_id
          AND ap.talent_pool_until IS NOT NULL
          AND ap.talent_pool_until > now()
      ) THEN
        DELETE FROM data.applicant_consent_events WHERE applicant_id = r.applicant_id;
        DELETE FROM data.applicants WHERE id = r.applicant_id;
        INSERT INTO data.applicant_erasure_log (
          tenant_id, email_hmac, reason, scope, applications_count
        ) VALUES (
          r.tenant_id, v_hmac, 'retention_policy', 'applicant', 0
        );
      END IF;
    END IF;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION data.purge_applicant_for_rights(
  p_tenant_id uuid,
  p_applicant_id uuid
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, extensions, public
AS $$
DECLARE
  r record;
  v_count int := 0;
  v_email text;
  v_hmac text;
BEGIN
  SELECT email INTO v_email FROM data.applicants WHERE id = p_applicant_id;
  v_hmac := data.applicant_email_hmac(p_tenant_id, v_email);

  UPDATE data.applicants
  SET talent_pool_until = NULL, updated_at = now()
  WHERE id = p_applicant_id AND tenant_id = p_tenant_id;

  FOR r IN
    SELECT id, cv_storage_path
    FROM data.applications
    WHERE applicant_id = p_applicant_id AND tenant_id = p_tenant_id
  LOOP
    PERFORM data.delete_recruitment_cv_storage(r.cv_storage_path);
    DELETE FROM data.applicant_consent_events WHERE application_id = r.id;
    DELETE FROM data.applications WHERE id = r.id;
    v_count := v_count + 1;
  END LOOP;

  IF v_count > 0 THEN
    INSERT INTO data.applicant_erasure_log (
      tenant_id, email_hmac, reason, scope, applications_count
    ) VALUES (
      p_tenant_id, v_hmac, 'user_request', 'application', v_count
    );
  END IF;

  DELETE FROM data.applicant_consent_events
  WHERE applicant_id = p_applicant_id AND tenant_id = p_tenant_id;

  DELETE FROM data.applicants WHERE id = p_applicant_id AND tenant_id = p_tenant_id;

  INSERT INTO data.applicant_erasure_log (
    tenant_id, email_hmac, reason, scope, applications_count
  ) VALUES (
    p_tenant_id, v_hmac, 'user_request', 'applicant', v_count
  );

  RETURN v_count;
END;
$$;

-- ---------------------------------------------------------------------------
-- 7. SLA reminder → internal recipients
-- ---------------------------------------------------------------------------
UPDATE data.email_templates
SET
  subject_template = '[Intern] Recordatori SLA petició de drets',
  html_body_template = '<p><strong>Missatge intern RRHH/DPO</strong> — no enviar al candidat.</p>
<p>Hi ha una petició de drets pendent (<strong>{{request_type_label}}</strong>) amb venciment {{due_at}}.</p>
<p>Sol·licitant (enmascarat a UI): {{requester_email}}</p>
<p>Tenant: {{tenant_name}}</p>
<p>Revisa la safata: /recruitment/rights</p>',
  text_body_template = E'[Intern] Petició de drets pendent\nTipus: {{request_type_label}}\nVenciment: {{due_at}}\nSol·licitant: {{requester_email}}\nTenant: {{tenant_name}}\nSafata: /recruitment/rights',
  updated_at = now()
WHERE event_type = 'recruitment.rights_sla_reminder'
  AND tenant_id IS NULL;

CREATE OR REPLACE FUNCTION data.remind_rights_sla()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  r record;
  v_count int := 0;
  v_label text;
  v_recipients text[];
BEGIN
  -- Allow enqueue_email membership bypass when invoked from cron (no JWT).
  PERFORM set_config('request.jwt.claim.role', 'service_role', true);

  FOR r IN
    SELECT req.*, t.name AS tenant_name
    FROM data.applicant_data_requests req
    JOIN data.tenants t ON t.id = req.tenant_id
    WHERE req.status = 'pending_review'
      AND req.sla_reminded_at IS NULL
      AND req.due_at <= now() + interval '3 days'
      AND req.due_at > now() - interval '1 day'
  LOOP
    v_label := data.rights_request_type_label(r.request_type);
    v_recipients := data.recruitment_rights_sla_recipient_emails(r.tenant_id);

    IF v_recipients IS NULL OR cardinality(v_recipients) = 0 THEN
      RAISE WARNING 'rights_sla_reminder skipped (no internal recipients) request=%', r.id;
      CONTINUE;
    END IF;

    BEGIN
      PERFORM api.enqueue_email(jsonb_build_object(
        'tenant_id', r.tenant_id,
        'idempotency_key', 'rights-sla-' || r.id::text,
        'to', to_jsonb(v_recipients),
        'event_type', 'recruitment.rights_sla_reminder',
        'locale', 'ca',
        'template_variables', jsonb_build_object(
          'request_type_label', v_label,
          'due_at', to_char(r.due_at AT TIME ZONE 'Europe/Madrid', 'YYYY-MM-DD'),
          'requester_email', r.requester_email,
          'tenant_name', r.tenant_name
        )
      ));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'rights_sla_reminder failed: %', SQLERRM;
      CONTINUE;
    END;

    UPDATE data.applicant_data_requests
    SET sla_reminded_at = now(), updated_at = now()
    WHERE id = r.id;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

NOTIFY pgrst, 'reload schema';
