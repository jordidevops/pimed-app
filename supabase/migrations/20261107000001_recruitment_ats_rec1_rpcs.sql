-- =============================================================================
-- REC-1b — submit/verify RPCs, public list/get, email templates
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Email templates (REC-0)
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
  'Confirmació correu candidatura',
  'recruitment-email-verify',
  'recruitment.email_verify',
  'Confirma el teu correu — {{job_title}}',
  '<p>Hola <strong>{{applicant_name}}</strong>,</p>
<p>Hem rebut la teva candidatura per a <strong>{{job_title}}</strong>.</p>
<p>Confirma el teu correu per gestionar preferències i drets:</p>
<p><a href="{{verify_url}}">Confirmar correu</a></p>
<p>Si no has enviat aquesta candidatura, ignora aquest missatge.</p>',
  'Hola {{applicant_name}}, confirma el correu: {{verify_url}}',
  '{"applicant_name":"string","job_title":"string","verify_url":"string","tenant_name":"string"}'::jsonb,
  '{}'::jsonb,
  false, NULL, true, true, true, false
),
(
  NULL,
  'Candidatura rebuda',
  'recruitment-application-received',
  'recruitment.application_received',
  'Hem rebut la teva candidatura — {{job_title}}',
  '<p>Hola <strong>{{applicant_name}}</strong>,</p>
<p>Hem registrat la teva candidatura per a <strong>{{job_title}}</strong> el {{applied_at}}.</p>
<p>Et contactarem si avancem en el procés. No cal respondre aquest correu.</p>',
  'Hola {{applicant_name}}, hem rebut la teva candidatura per a {{job_title}} ({{applied_at}}).',
  '{"applicant_name":"string","job_title":"string","applied_at":"string","tenant_name":"string"}'::jsonb,
  '{}'::jsonb,
  false, NULL, true, true, true, false
),
(
  NULL,
  'Dades de candidatura esborrades',
  'recruitment-retention-purge',
  'recruitment.retention_purge_fulfilled',
  'Hem esborrat les dades de la teva candidatura',
  '<p>Hola,</p>
<p>Segons la política de retenció / la teva preferència, hem esborrat les dades de la candidatura a <strong>{{job_title}}</strong> el {{erased_at}}.</p>',
  'Hem esborrat les dades de la candidatura a {{job_title}} el {{erased_at}}.',
  '{"job_title":"string","erased_at":"string","tenant_name":"string"}'::jsonb,
  '{}'::jsonb,
  false, NULL, true, true, true, false
)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Public listing RPCs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_public_job_postings(p_public_site_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid;
  v_status text;
  v_enabled boolean;
BEGIN
  SELECT ps.tenant_id, ps.status, COALESCE(t.public_portal_enabled, false)
  INTO v_tenant, v_status, v_enabled
  FROM data.public_sites ps
  JOIN data.tenants t ON t.id = ps.tenant_id
  WHERE ps.id = p_public_site_id;

  IF NOT FOUND OR v_status <> 'published' OR NOT v_enabled THEN
    RETURN '[]'::jsonb;
  END IF;

  IF NOT data.is_feature_enabled(v_tenant, 'recruitment_enabled') THEN
    RETURN '[]'::jsonb;
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id', jp.id,
      'title', jp.title,
      'public_slug', jp.public_slug,
      'description', left(COALESCE(jp.description, ''), 400),
      'opens_at', jp.opens_at,
      'closes_at', jp.closes_at
    ) ORDER BY jp.created_at DESC)
    FROM data.job_postings jp
    JOIN data.job_posting_public_sites jps
      ON jps.job_posting_id = jp.id AND jps.public_site_id = p_public_site_id
    WHERE jp.tenant_id = v_tenant
      AND jp.status = 'published'
      AND (jp.opens_at IS NULL OR jp.opens_at <= now())
      AND (jp.closes_at IS NULL OR jp.closes_at > now())
  ), '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_public_job_postings(uuid) TO anon, authenticated;

CREATE OR REPLACE FUNCTION api.get_public_job_posting(
  p_public_site_id uuid,
  p_slug text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid;
  v_status text;
  v_enabled boolean;
  v_row record;
  v_privacy text;
  v_max_ret int;
BEGIN
  SELECT ps.tenant_id, ps.status, COALESCE(t.public_portal_enabled, false)
  INTO v_tenant, v_status, v_enabled
  FROM data.public_sites ps
  JOIN data.tenants t ON t.id = ps.tenant_id
  WHERE ps.id = p_public_site_id;

  IF NOT FOUND OR v_status <> 'published' OR NOT v_enabled THEN
    RETURN NULL;
  END IF;

  IF NOT data.is_feature_enabled(v_tenant, 'recruitment_enabled') THEN
    RETURN NULL;
  END IF;

  SELECT jp.* INTO v_row
  FROM data.job_postings jp
  JOIN data.job_posting_public_sites jps
    ON jps.job_posting_id = jp.id AND jps.public_site_id = p_public_site_id
  WHERE jp.tenant_id = v_tenant
    AND jp.public_slug = p_slug
    AND jp.status = 'published'
    AND (jp.opens_at IS NULL OR jp.opens_at <= now())
    AND (jp.closes_at IS NULL OR jp.closes_at > now());

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT privacy_policy_url, default_max_retention_months
  INTO v_privacy, v_max_ret
  FROM data.recruitment_settings
  WHERE tenant_id = v_tenant;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'title', v_row.title,
    'public_slug', v_row.public_slug,
    'description', v_row.description,
    'opens_at', v_row.opens_at,
    'closes_at', v_row.closes_at,
    'privacy_policy_url', v_privacy,
    'default_max_retention_months', COALESCE(v_max_ret, 12),
    'retention_options_months', jsonb_build_array(3, 6, LEAST(12, COALESCE(v_max_ret, 12)))
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_public_job_posting(uuid, text) TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- Submit application
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.submit_job_application(
  p_public_site_id uuid,
  p_job_posting_id uuid,
  p_idempotency_key text,
  p_full_name text,
  p_email text,
  p_phone text DEFAULT NULL,
  p_cover_message text DEFAULT NULL,
  p_source text DEFAULT 'web',
  p_retention_preference text DEFAULT 'delete_after_months',
  p_retention_months int DEFAULT 12,
  p_cv_storage_path text DEFAULT NULL,
  p_legal_notice_version text DEFAULT 'v1',
  p_privacy_accepted boolean DEFAULT false,
  p_locale text DEFAULT 'ca',
  p_verify_base_url text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_tenant uuid;
  v_site_status text;
  v_enabled boolean;
  v_posting data.job_postings%ROWTYPE;
  v_applicant_id uuid;
  v_application_id uuid;
  v_stage_id uuid;
  v_email text;
  v_token text;
  v_token_hash text;
  v_settings data.recruitment_settings%ROWTYPE;
  v_verify_url text;
  v_max int;
BEGIN
  IF NOT COALESCE(p_privacy_accepted, false) THEN
    RAISE EXCEPTION 'privacy_not_accepted'
      USING HINT = 'Cal acceptar la informació de protecció de dades.';
  END IF;

  IF COALESCE(trim(p_full_name), '') = '' OR COALESCE(trim(p_email), '') = '' THEN
    RAISE EXCEPTION 'invalid_input'
      USING HINT = 'Nom i email són obligatoris.';
  END IF;

  v_email := lower(trim(p_email));

  IF p_source IS NULL OR p_source NOT IN ('web', 'qr', 'whatsapp', 'email', 'manual', 'csv_import') THEN
    p_source := 'web';
  END IF;

  SELECT ps.tenant_id, ps.status, COALESCE(t.public_portal_enabled, false)
  INTO v_tenant, v_site_status, v_enabled
  FROM data.public_sites ps
  JOIN data.tenants t ON t.id = ps.tenant_id
  WHERE ps.id = p_public_site_id;

  IF NOT FOUND OR v_site_status <> 'published' OR NOT v_enabled THEN
    RAISE EXCEPTION 'site_not_published';
  END IF;

  IF NOT data.is_feature_enabled(v_tenant, 'recruitment_enabled') THEN
    RAISE EXCEPTION 'module_not_enabled';
  END IF;

  SELECT * INTO v_posting
  FROM data.job_postings
  WHERE id = p_job_posting_id AND tenant_id = v_tenant;

  IF NOT FOUND OR v_posting.status <> 'published' THEN
    RAISE EXCEPTION 'posting_not_available';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.job_posting_public_sites
    WHERE job_posting_id = p_job_posting_id AND public_site_id = p_public_site_id
  ) THEN
    RAISE EXCEPTION 'posting_not_on_site';
  END IF;

  SELECT * INTO v_settings FROM data.recruitment_settings WHERE tenant_id = v_tenant;
  v_max := COALESCE(v_settings.default_max_retention_months, 12);

  IF p_retention_preference = 'delete_after_months' THEN
    IF p_retention_months IS NULL OR p_retention_months < 1 THEN
      p_retention_months := v_max;
    END IF;
    p_retention_months := LEAST(p_retention_months, v_max);
  ELSE
    p_retention_preference := 'delete_on_process_end';
    p_retention_months := NULL;
  END IF;

  SELECT id INTO v_stage_id
  FROM data.pipeline_stages
  WHERE tenant_id = v_tenant AND job_posting_id IS NULL
  ORDER BY position
  LIMIT 1;

  v_token := encode(gen_random_bytes(24), 'hex');
  v_token_hash := encode(digest(v_token, 'sha256'), 'hex');

  INSERT INTO data.applicants (
    tenant_id, email, full_name, phone,
    email_verify_token_hash, email_verify_expires_at
  ) VALUES (
    v_tenant, v_email, trim(p_full_name), nullif(trim(p_phone), ''),
    v_token_hash, now() + interval '7 days'
  )
  ON CONFLICT (tenant_id, email) DO UPDATE SET
    full_name = EXCLUDED.full_name,
    phone = COALESCE(EXCLUDED.phone, data.applicants.phone),
    email_verify_token_hash = CASE
      WHEN data.applicants.email_verified_at IS NULL THEN EXCLUDED.email_verify_token_hash
      ELSE data.applicants.email_verify_token_hash
    END,
    email_verify_expires_at = CASE
      WHEN data.applicants.email_verified_at IS NULL THEN EXCLUDED.email_verify_expires_at
      ELSE data.applicants.email_verify_expires_at
    END,
    updated_at = now()
  RETURNING id INTO v_applicant_id;

  INSERT INTO data.applications (
    tenant_id, job_posting_id, applicant_id, stage_id,
    cv_storage_path, retention_preference, retention_months,
    source, cover_message, legal_notice_version,
    purge_at
  ) VALUES (
    v_tenant, p_job_posting_id, v_applicant_id, v_stage_id,
    p_cv_storage_path, p_retention_preference, p_retention_months,
    p_source, nullif(trim(p_cover_message), ''), p_legal_notice_version,
    data.compute_application_purge_at(
      v_tenant, now(), p_retention_preference, p_retention_months, NULL
    )
  )
  ON CONFLICT (job_posting_id, applicant_id) DO NOTHING
  RETURNING id INTO v_application_id;

  IF v_application_id IS NULL THEN
    SELECT id INTO v_application_id
    FROM data.applications
    WHERE job_posting_id = p_job_posting_id AND applicant_id = v_applicant_id;

    RETURN jsonb_build_object(
      'application_id', v_application_id,
      'applicant_id', v_applicant_id,
      'duplicate', true
    );
  END IF;

  INSERT INTO data.applicant_consent_events (
    tenant_id, applicant_id, application_id, event_type, legal_text_version, payload
  ) VALUES (
    v_tenant, v_applicant_id, v_application_id, 'apply_consent', p_legal_notice_version,
    jsonb_build_object(
      'privacy_accepted', true,
      'retention_preference', p_retention_preference,
      'retention_months', p_retention_months,
      'idempotency_key', p_idempotency_key,
      'source', p_source
    )
  );

  IF COALESCE(trim(p_verify_base_url), '') <> '' THEN
    v_verify_url := rtrim(trim(p_verify_base_url), '/') || '/recruitment/verify?token=' || v_token;
    BEGIN
      PERFORM api.enqueue_email(jsonb_build_object(
        'tenant_id', v_tenant,
        'idempotency_key', 'recruitment-verify-' || v_application_id::text,
        'to', jsonb_build_array(v_email),
        'event_type', 'recruitment.email_verify',
        'locale', COALESCE(p_locale, 'ca'),
        'variables', jsonb_build_object(
          'applicant_name', trim(p_full_name),
          'job_title', v_posting.title,
          'verify_url', v_verify_url
        )
      ));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'submit_job_application: verify email enqueue failed: %', SQLERRM;
    END;
  END IF;

  BEGIN
    PERFORM api.enqueue_email(jsonb_build_object(
      'tenant_id', v_tenant,
      'idempotency_key', 'recruitment-received-' || v_application_id::text,
      'to', jsonb_build_array(v_email),
      'event_type', 'recruitment.application_received',
      'locale', COALESCE(p_locale, 'ca'),
      'variables', jsonb_build_object(
        'applicant_name', trim(p_full_name),
        'job_title', v_posting.title,
        'applied_at', to_char(now() AT TIME ZONE 'Europe/Madrid', 'YYYY-MM-DD HH24:MI')
      )
    ));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'submit_job_application: received email enqueue failed: %', SQLERRM;
  END;

  RETURN jsonb_build_object(
    'application_id', v_application_id,
    'applicant_id', v_applicant_id,
    'duplicate', false
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.submit_job_application(
  uuid, uuid, text, text, text, text, text, text, text, int, text, text, boolean, text, text
) TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- Verify email
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.verify_applicant_email(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public, extensions
AS $$
DECLARE
  v_hash text;
  v_app data.applicants%ROWTYPE;
BEGIN
  IF COALESCE(trim(p_token), '') = '' THEN
    RAISE EXCEPTION 'invalid_token';
  END IF;

  v_hash := encode(digest(trim(p_token), 'sha256'), 'hex');

  SELECT * INTO v_app
  FROM data.applicants
  WHERE email_verify_token_hash = v_hash
    AND email_verify_expires_at > now()
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid_or_expired_token';
  END IF;

  UPDATE data.applicants SET
    email_verified_at = COALESCE(email_verified_at, now()),
    email_verify_token_hash = NULL,
    email_verify_expires_at = NULL,
    updated_at = now()
  WHERE id = v_app.id;

  RETURN jsonb_build_object('ok', true, 'applicant_id', v_app.id);
END;
$$;

GRANT EXECUTE ON FUNCTION api.verify_applicant_email(text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
