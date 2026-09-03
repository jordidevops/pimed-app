-- =============================================================================
-- REC-5 — Communicate outcome + post-rejection preferences (tall 2)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Schema columns on applications
-- ---------------------------------------------------------------------------
ALTER TABLE data.applications
  ADD COLUMN IF NOT EXISTS outcome_kind text
    CHECK (outcome_kind IS NULL OR outcome_kind IN ('rejected', 'withdrawn', 'hired_next_steps'));

ALTER TABLE data.applications
  ADD COLUMN IF NOT EXISTS post_rejection_token_hash text;

ALTER TABLE data.applications
  ADD COLUMN IF NOT EXISTS post_rejection_token_expires_at timestamptz;

ALTER TABLE data.applications
  ADD COLUMN IF NOT EXISTS post_rejection_responded_at timestamptz;

ALTER TABLE data.applications
  ADD COLUMN IF NOT EXISTS post_rejection_choice text
    CHECK (
      post_rejection_choice IS NULL
      OR post_rejection_choice IN ('erase', 'talent_pool', 'keep_until_purge')
    );

CREATE INDEX IF NOT EXISTS idx_applications_post_rejection_token
  ON data.applications (post_rejection_token_hash)
  WHERE post_rejection_token_hash IS NOT NULL;

-- Refresh API view to include new columns
CREATE OR REPLACE VIEW api.applications
WITH (security_invoker = true) AS
SELECT * FROM data.applications;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.applications TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Email templates
-- ---------------------------------------------------------------------------
INSERT INTO data.email_templates (
  tenant_id, name, slug, event_type,
  subject_template, html_body_template, text_body_template,
  variables_schema, translations,
  is_layout, layout_id, use_layout,
  is_platform_default, is_active, is_draft
)
VALUES
(
  NULL,
  'Resultat de candidatura',
  'recruitment-application-rejected',
  'recruitment.application_rejected',
  'Actualització del procés — {{job_title}}',
  '<p>Hola <strong>{{applicant_name}}</strong>,</p>
<p>T''informem que el procés de selecció per a <strong>{{job_title}}</strong> s''ha tancat per a la teva candidatura.</p>
<p>Pots indicar les teves preferències de retenció de dades aquí (enllaç d''un sol ús):</p>
<p><a href="{{preferences_url}}">Gestionar preferències</a></p>
<p>Aquest enllaç caduca el {{prefs_expires_at}}.</p>',
  'Hola {{applicant_name}}. Procés tancat per {{job_title}}. Preferències: {{preferences_url}} (caduca {{prefs_expires_at}}).',
  '{"applicant_name":"string","job_title":"string","preferences_url":"string","prefs_expires_at":"string","tenant_name":"string"}'::jsonb,
  '{}'::jsonb,
  false, NULL, true, true, true, false
),
(
  NULL,
  'Confirmació preferències post-rebuig',
  'recruitment-post-rejection-preferences',
  'recruitment.post_rejection_preferences',
  'Hem registrat les teves preferències',
  '<p>Hola <strong>{{applicant_name}}</strong>,</p>
<p>Hem registrat la teva preferència (<strong>{{choice_label}}</strong>) per a la candidatura a <strong>{{job_title}}</strong>.</p>',
  'Hola {{applicant_name}}, preferència {{choice_label}} registrada per {{job_title}}.',
  '{"applicant_name":"string","job_title":"string","choice_label":"string","tenant_name":"string"}'::jsonb,
  '{}'::jsonb,
  false, NULL, true, true, true, false
)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. communicate_application_outcome
-- ---------------------------------------------------------------------------
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
  v_prefs_url text;
  v_expires timestamptz;
  v_kind text;
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

  v_token := encode(gen_random_bytes(24), 'hex');
  v_token_hash := encode(digest(v_token, 'sha256'), 'hex');
  v_expires := now() + interval '30 days';

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

  IF v_kind IN ('rejected', 'withdrawn')
     AND COALESCE(trim(p_prefs_base_url), '') <> ''
  THEN
    v_prefs_url := rtrim(trim(p_prefs_base_url), '/') || '/recruitment/preferences?token=' || v_token;
    BEGIN
      PERFORM api.enqueue_email(jsonb_build_object(
        'tenant_id', v_tenant,
        'idempotency_key', 'recruitment-rejected-' || v_app.id::text,
        'to', jsonb_build_array(v_applicant.email),
        'event_type', 'recruitment.application_rejected',
        'locale', 'ca',
        'variables', jsonb_build_object(
          'applicant_name', v_applicant.full_name,
          'job_title', v_posting.title,
          'preferences_url', v_prefs_url,
          'prefs_expires_at', to_char(v_expires AT TIME ZONE 'Europe/Madrid', 'YYYY-MM-DD')
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
    jsonb_build_object('outcome_kind', v_kind)
  );

  RETURN jsonb_build_object(
    'application_id', v_app.id,
    'already_communicated', false,
    'outcome_kind', v_kind,
    'candidate_visible_status', 'closed'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.communicate_application_outcome(uuid, text, text)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Batch communicate for a posting
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.communicate_posting_outcomes(
  p_job_posting_id uuid,
  p_prefs_base_url text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_posting data.job_postings%ROWTYPE;
  v_settings data.recruitment_settings%ROWTYPE;
  r record;
  v_count int := 0;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT data.jwt_has_recruitment_permission(v_tenant, 'recruitment.manage') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_posting
  FROM data.job_postings
  WHERE id = p_job_posting_id AND tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  SELECT * INTO v_settings FROM data.recruitment_settings WHERE tenant_id = v_tenant;

  -- Always allow explicit batch call; archive trigger gates on policy
  FOR r IN
    SELECT id FROM data.applications
    WHERE job_posting_id = p_job_posting_id
      AND tenant_id = v_tenant
      AND outcome_communicated_at IS NULL
  LOOP
    PERFORM api.communicate_application_outcome(r.id, 'rejected', p_prefs_base_url);
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'job_posting_id', p_job_posting_id,
    'communicated_count', v_count,
    'policy', COALESCE(v_settings.rejection_notify_policy, 'on_decision')
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.communicate_posting_outcomes(uuid, text)
  TO authenticated;

-- Internal helper for trigger (no JWT / prefs URL — emails without prefs link if no URL)
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
BEGIN
  SELECT * INTO v_posting FROM data.job_postings WHERE id = p_job_posting_id;

  FOR r IN
    SELECT id FROM data.applications
    WHERE job_posting_id = p_job_posting_id
      AND tenant_id = p_tenant_id
      AND outcome_communicated_at IS NULL
  LOOP
    SELECT * INTO v_app FROM data.applications WHERE id = r.id;
    SELECT * INTO v_applicant FROM data.applicants WHERE id = v_app.applicant_id;

    v_token := encode(gen_random_bytes(24), 'hex');
    v_token_hash := encode(digest(v_token, 'sha256'), 'hex');
    v_expires := now() + interval '30 days';

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
      jsonb_build_object('outcome_kind', 'rejected', 'batch', true)
    );

    BEGIN
      PERFORM api.enqueue_email(jsonb_build_object(
        'tenant_id', p_tenant_id,
        'idempotency_key', 'recruitment-rejected-' || v_app.id::text,
        'to', jsonb_build_array(v_applicant.email),
        'event_type', 'recruitment.application_rejected',
        'locale', 'ca',
        'variables', jsonb_build_object(
          'applicant_name', v_applicant.full_name,
          'job_title', v_posting.title,
          'preferences_url', '',
          'prefs_expires_at', to_char(v_expires AT TIME ZONE 'Europe/Madrid', 'YYYY-MM-DD')
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

CREATE OR REPLACE FUNCTION data.trg_job_posting_archive_communicate()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_settings data.recruitment_settings%ROWTYPE;
  v_should boolean := false;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_settings FROM data.recruitment_settings WHERE tenant_id = NEW.tenant_id;

  IF NEW.status = 'archived' THEN
    v_should := true;
  ELSIF NEW.status = 'expired' AND COALESCE(v_settings.expire_closes_process, true) THEN
    v_should := true;
  END IF;

  IF v_should AND COALESCE(v_settings.rejection_notify_policy, 'on_decision') = 'on_posting_close' THEN
    PERFORM data.communicate_posting_outcomes_internal(NEW.id, NEW.tenant_id);
  ELSIF v_should THEN
    -- Still close process timestamps without email lot when on_decision
    UPDATE data.applications SET
      process_closed_at = COALESCE(process_closed_at, now()),
      updated_at = now()
    WHERE job_posting_id = NEW.id
      AND process_closed_at IS NULL;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_job_posting_archive_communicate ON data.job_postings;
CREATE TRIGGER trg_job_posting_archive_communicate
  AFTER UPDATE OF status ON data.job_postings
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_job_posting_archive_communicate();

-- ---------------------------------------------------------------------------
-- 5. submit_post_rejection_preferences (anon)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.submit_post_rejection_preferences(
  p_token text,
  p_choice text,
  p_talent_months int DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_hash text;
  v_app data.applications%ROWTYPE;
  v_applicant data.applicants%ROWTYPE;
  v_posting data.job_postings%ROWTYPE;
  v_settings data.recruitment_settings%ROWTYPE;
  v_max int;
  v_months int;
  v_choice text;
  v_label text;
BEGIN
  IF COALESCE(trim(p_token), '') = '' THEN
    RAISE EXCEPTION 'invalid_token';
  END IF;

  v_choice := trim(p_choice);
  IF v_choice NOT IN ('erase', 'talent_pool', 'keep_until_purge') THEN
    RAISE EXCEPTION 'invalid_choice';
  END IF;

  v_hash := encode(digest(trim(p_token), 'sha256'), 'hex');

  SELECT * INTO v_app
  FROM data.applications
  WHERE post_rejection_token_hash = v_hash
    AND post_rejection_token_expires_at > now()
    AND post_rejection_responded_at IS NULL
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid_or_expired_token';
  END IF;

  SELECT * INTO v_applicant FROM data.applicants WHERE id = v_app.applicant_id;
  SELECT * INTO v_posting FROM data.job_postings WHERE id = v_app.job_posting_id;
  SELECT * INTO v_settings FROM data.recruitment_settings WHERE tenant_id = v_app.tenant_id;
  v_max := COALESCE(v_settings.default_max_retention_months, 12);

  IF v_applicant.email_verified_at IS NULL THEN
    RAISE EXCEPTION 'email_not_verified'
      USING HINT = 'Cal verificar el correu abans de gestionar preferències.';
  END IF;

  IF v_choice = 'talent_pool' THEN
    v_months := LEAST(COALESCE(NULLIF(p_talent_months, 0), v_max), v_max);
    IF v_months < 1 THEN
      v_months := v_max;
    END IF;
    UPDATE data.applicants SET
      talent_pool_until = now() + make_interval(months => v_months),
      updated_at = now()
    WHERE id = v_applicant.id;
    v_label := 'talent pool (' || v_months::text || ' mesos)';
  ELSIF v_choice = 'erase' THEN
    UPDATE data.applications SET
      process_closed_at = COALESCE(process_closed_at, now()),
      retention_preference = 'delete_on_process_end',
      retention_months = NULL,
      updated_at = now()
    WHERE id = v_app.id;
    -- Force near-term purge: set process closed and preference; also clamp purge via direct update after trigger
    UPDATE data.applications SET
      purge_at = LEAST(purge_at, now() + interval '1 day')
    WHERE id = v_app.id;
    v_label := 'esborrat';
  ELSE
    v_label := 'mantenir fins a purge';
  END IF;

  UPDATE data.applications SET
    post_rejection_choice = v_choice,
    post_rejection_responded_at = now(),
    post_rejection_token_hash = NULL,
    post_rejection_token_expires_at = NULL,
    updated_at = now()
  WHERE id = v_app.id;

  INSERT INTO data.applicant_consent_events (
    tenant_id, applicant_id, application_id, event_type, legal_text_version, payload
  ) VALUES (
    v_app.tenant_id, v_app.applicant_id, v_app.id, 'post_rejection_preference', 'v1',
    jsonb_build_object('choice', v_choice, 'talent_months', p_talent_months)
  );

  BEGIN
    PERFORM api.enqueue_email(jsonb_build_object(
      'tenant_id', v_app.tenant_id,
      'idempotency_key', 'recruitment-prefs-' || v_app.id::text,
      'to', jsonb_build_array(v_applicant.email),
      'event_type', 'recruitment.post_rejection_preferences',
      'locale', 'ca',
      'variables', jsonb_build_object(
        'applicant_name', v_applicant.full_name,
        'job_title', v_posting.title,
        'choice_label', v_label
      )
    ));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'submit_post_rejection_preferences: email failed: %', SQLERRM;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'choice', v_choice,
    'application_id', v_app.id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.submit_post_rejection_preferences(text, text, int)
  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
