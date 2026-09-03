-- =============================================================================
-- REC-5b — Safata drets Art. 15 (accés) + Art. 17 (esborrat)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Schema
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.applicant_data_requests (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  applicant_id         uuid REFERENCES data.applicants(id) ON DELETE SET NULL,
  request_type         text NOT NULL
    CHECK (request_type IN ('access', 'erasure')),
  status               text NOT NULL DEFAULT 'pending_review'
    CHECK (status IN ('pending_review', 'fulfilled', 'rejected')),
  fulfilled_via        text
    CHECK (
      fulfilled_via IS NULL
      OR fulfilled_via IN ('email_export', 'purge', 'rejected_with_reason')
    ),
  requester_email      text NOT NULL,
  message              text,
  rejection_reason     text,
  due_at               timestamptz NOT NULL,
  sla_reminded_at      timestamptz,
  resolved_at          timestamptz,
  resolved_by          uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  export_storage_path  text,
  export_json          jsonb,
  export_token_hash    text,
  export_token_expires_at timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_applicant_data_requests_tenant_status
  ON data.applicant_data_requests (tenant_id, status, due_at);

CREATE INDEX IF NOT EXISTS idx_applicant_data_requests_export_token
  ON data.applicant_data_requests (export_token_hash)
  WHERE export_token_hash IS NOT NULL;

ALTER TABLE data.applicant_data_requests ENABLE ROW LEVEL SECURITY;

CREATE POLICY applicant_data_requests_select ON data.applicant_data_requests
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(tenant_id, 'recruitment.rights')
  );

CREATE POLICY applicant_data_requests_update ON data.applicant_data_requests
  FOR UPDATE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(tenant_id, 'recruitment.rights')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(tenant_id, 'recruitment.rights')
  );

-- API view: no export_json / tokens (PII package stays out of PostgREST selects)
CREATE OR REPLACE VIEW api.applicant_data_requests
WITH (security_invoker = true) AS
SELECT
  id,
  tenant_id,
  applicant_id,
  request_type,
  status,
  fulfilled_via,
  requester_email,
  message,
  rejection_reason,
  due_at,
  sla_reminded_at,
  resolved_at,
  resolved_by,
  export_storage_path,
  created_at,
  updated_at
FROM data.applicant_data_requests;

GRANT SELECT ON api.applicant_data_requests TO authenticated;
GRANT SELECT, UPDATE ON data.applicant_data_requests TO authenticated;

-- Allow JSON in exports bucket (logical path; download via token RPC)
UPDATE storage.buckets
SET allowed_mime_types = ARRAY[
  'text/csv', 'text/plain', 'application/csv', 'application/json'
]::text[]
WHERE id = 'recruitment-exports';

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
  'Petició de drets rebuda',
  'recruitment-rights-request-ack',
  'recruitment.rights_request_ack',
  'Hem rebut la teva petició de drets',
  '<p>Hola,</p>
<p>Hem rebut la teva petició (<strong>{{request_type_label}}</strong>). La revisarem dins el termini legal (SLA {{sla_days}} dies).</p>',
  'Hem rebut la teva petició ({{request_type_label}}). SLA {{sla_days}} dies.',
  '{"request_type_label":"string","sla_days":"string","tenant_name":"string"}'::jsonb,
  '{}'::jsonb,
  false, NULL, true, true, true, false
),
(
  NULL,
  'Accés a dades (Art. 15)',
  'recruitment-rights-access-fulfilled',
  'recruitment.rights_access_fulfilled',
  'Export de les teves dades de candidatura',
  '<p>Hola <strong>{{applicant_name}}</strong>,</p>
<p>Adjuntem l''enllaç per descarregar l''export de les teves dades (caduca el {{export_expires_at}}):</p>
<p><a href="{{export_url}}">Descarregar export</a></p>',
  'Hola {{applicant_name}}. Export: {{export_url}} (caduca {{export_expires_at}}).',
  '{"applicant_name":"string","export_url":"string","export_expires_at":"string","tenant_name":"string"}'::jsonb,
  '{}'::jsonb,
  false, NULL, true, true, true, false
),
(
  NULL,
  'Accés després d''esborrat',
  'recruitment-rights-access-after-erasure',
  'recruitment.rights_access_after_erasure',
  'Sobre la teva petició d''accés',
  '<p>Hola,</p>
<p>Les dades de candidatura associades a aquest correu ja van ser esborrades el {{erased_at}} (motiu: {{reason}}).</p>',
  'Dades ja esborrades el {{erased_at}} ({{reason}}).',
  '{"erased_at":"string","reason":"string","tenant_name":"string"}'::jsonb,
  '{}'::jsonb,
  false, NULL, true, true, true, false
),
(
  NULL,
  'Esborrat confirmat (Art. 17)',
  'recruitment-rights-erasure-fulfilled',
  'recruitment.rights_erasure_fulfilled',
  'Hem esborrat les teves dades de candidatura',
  '<p>Hola,</p>
<p>Hem atès la teva petició d''esborrat. Les dades de candidatura al nostre sistema han estat eliminades el {{erased_at}}.</p>',
  'Esborrat confirmat el {{erased_at}}.',
  '{"erased_at":"string","tenant_name":"string"}'::jsonb,
  '{}'::jsonb,
  false, NULL, true, true, true, false
),
(
  NULL,
  'Petició de drets rebutjada',
  'recruitment-rights-rejected',
  'recruitment.rights_rejected',
  'Resposta a la teva petició de drets',
  '<p>Hola,</p>
<p>Hem revisat la teva petició (<strong>{{request_type_label}}</strong>) i no l''hem pogut atendre.</p>
<p>Motiu: {{rejection_reason}}</p>',
  'Petició {{request_type_label}} rebutjada: {{rejection_reason}}',
  '{"request_type_label":"string","rejection_reason":"string","tenant_name":"string"}'::jsonb,
  '{}'::jsonb,
  false, NULL, true, true, true, false
),
(
  NULL,
  'Recordatori SLA drets (intern)',
  'recruitment-rights-sla-reminder',
  'recruitment.rights_sla_reminder',
  'Recordatori SLA petició de drets',
  '<p>Hi ha una petició de drets pendent ({{request_type_label}}) amb venciment {{due_at}}.</p>
<p>Email sol·licitant: {{requester_email}}</p>',
  'SLA reminder: {{request_type_label}} due {{due_at}} — {{requester_email}}',
  '{"request_type_label":"string","due_at":"string","requester_email":"string","tenant_name":"string"}'::jsonb,
  '{}'::jsonb,
  false, NULL, true, true, true, false
)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.mask_email(p_email text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_email IS NULL OR position('@' in p_email) = 0 THEN '***'
    ELSE
      left(split_part(p_email, '@', 1), 1)
      || '***@'
      || split_part(p_email, '@', 2)
  END;
$$;

CREATE OR REPLACE FUNCTION data.build_applicant_access_export(
  p_tenant_id uuid,
  p_applicant_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_applicant jsonb;
  v_apps jsonb;
  v_consents jsonb;
  v_interviews jsonb;
BEGIN
  SELECT to_jsonb(ap) - 'id' || jsonb_build_object('id', ap.id)
  INTO v_applicant
  FROM data.applicants ap
  WHERE ap.id = p_applicant_id AND ap.tenant_id = p_tenant_id;

  SELECT coalesce(jsonb_agg(row_to_json(x)::jsonb ORDER BY x.created_at), '[]'::jsonb)
  INTO v_apps
  FROM (
    SELECT
      a.id,
      a.job_posting_id,
      jp.title AS job_title,
      a.source,
      a.retention_preference,
      a.retention_months,
      a.purge_at,
      a.outcome_communicated_at,
      a.process_closed_at,
      a.candidate_visible_status,
      a.cv_storage_path,
      a.cover_message,
      a.created_at
    FROM data.applications a
    JOIN data.job_postings jp ON jp.id = a.job_posting_id
    WHERE a.applicant_id = p_applicant_id AND a.tenant_id = p_tenant_id
  ) x;

  SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY c.created_at), '[]'::jsonb)
  INTO v_consents
  FROM data.applicant_consent_events c
  WHERE c.applicant_id = p_applicant_id AND c.tenant_id = p_tenant_id;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'id', i.id,
      'application_id', i.application_id,
      'type', i.type,
      'scheduled_at', i.scheduled_at,
      'status', i.status,
      'created_at', i.created_at
    ) ORDER BY i.created_at
  ), '[]'::jsonb)
  INTO v_interviews
  FROM data.interviews i
  JOIN data.applications a ON a.id = i.application_id
  WHERE a.applicant_id = p_applicant_id AND i.tenant_id = p_tenant_id;

  RETURN jsonb_build_object(
    'exported_at', now(),
    'tenant_id', p_tenant_id,
    'applicant', v_applicant,
    'applications', v_apps,
    'consent_events', v_consents,
    'interviews', v_interviews,
    'cv_note', 'cv_storage_path is a private storage path; use the export download within the validity window or contact the controller.'
  );
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
    SELECT id FROM data.applications
    WHERE applicant_id = p_applicant_id AND tenant_id = p_tenant_id
  LOOP
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
-- 4. submit_applicant_data_request (anon)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.submit_applicant_data_request(
  p_public_site_id uuid,
  p_email text,
  p_request_type text,
  p_message text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_site data.public_sites%ROWTYPE;
  v_settings data.recruitment_settings%ROWTYPE;
  v_applicant data.applicants%ROWTYPE;
  v_email text;
  v_type text;
  v_hmac text;
  v_erased_at timestamptz;
  v_reason text;
  v_req_id uuid;
  v_due timestamptz;
  v_label text;
BEGIN
  v_email := lower(trim(COALESCE(p_email, '')));
  v_type := trim(COALESCE(p_request_type, ''));

  IF v_email = '' OR position('@' in v_email) = 0 THEN
    RAISE EXCEPTION 'invalid_email';
  END IF;
  IF v_type NOT IN ('access', 'erasure') THEN
    RAISE EXCEPTION 'invalid_request_type';
  END IF;

  SELECT * INTO v_site FROM data.public_sites WHERE id = p_public_site_id;
  IF NOT FOUND OR v_site.status <> 'published' THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  SELECT * INTO v_settings FROM data.recruitment_settings WHERE tenant_id = v_site.tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'recruitment_settings_missing';
  END IF;

  SELECT * INTO v_applicant
  FROM data.applicants
  WHERE tenant_id = v_site.tenant_id
    AND lower(email) = v_email
  LIMIT 1;

  -- Anti-enumeration: always return ok-shaped response
  IF NOT FOUND THEN
    IF v_type = 'access' THEN
      v_hmac := data.applicant_email_hmac(v_site.tenant_id, v_email);
      SELECT erased_at, reason INTO v_erased_at, v_reason
      FROM data.applicant_erasure_log
      WHERE tenant_id = v_site.tenant_id AND email_hmac = v_hmac
      ORDER BY erased_at DESC
      LIMIT 1;
      IF v_erased_at IS NOT NULL THEN
        BEGIN
          PERFORM api.enqueue_email(jsonb_build_object(
            'tenant_id', v_site.tenant_id,
            'idempotency_key', 'rights-after-erasure-' || v_hmac || '-' || to_char(v_erased_at, 'YYYYMMDD'),
            'to', jsonb_build_array(v_email),
            'event_type', 'recruitment.rights_access_after_erasure',
            'locale', 'ca',
            'variables', jsonb_build_object(
              'erased_at', to_char(v_erased_at AT TIME ZONE 'Europe/Madrid', 'YYYY-MM-DD'),
              'reason', COALESCE(v_reason, 'unknown')
            )
          ));
        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'rights_access_after_erasure email failed: %', SQLERRM;
        END;
      END IF;
    END IF;
    RETURN jsonb_build_object('ok', true, 'queued', false);
  END IF;

  IF v_applicant.email_verified_at IS NULL THEN
    RAISE EXCEPTION 'email_not_verified'
      USING HINT = 'Cal verificar el correu abans d''exercir drets.';
  END IF;

  v_due := now() + make_interval(days => COALESCE(v_settings.rights_sla_days, 30));
  v_label := CASE v_type WHEN 'access' THEN 'accés (Art. 15)' ELSE 'esborrat (Art. 17)' END;

  INSERT INTO data.applicant_data_requests (
    tenant_id, applicant_id, request_type, status,
    requester_email, message, due_at
  ) VALUES (
    v_site.tenant_id, v_applicant.id, v_type, 'pending_review',
    v_email, nullif(trim(COALESCE(p_message, '')), ''), v_due
  )
  RETURNING id INTO v_req_id;

  BEGIN
    PERFORM api.enqueue_email(jsonb_build_object(
      'tenant_id', v_site.tenant_id,
      'idempotency_key', 'rights-ack-' || v_req_id::text,
      'to', jsonb_build_array(v_email),
      'event_type', 'recruitment.rights_request_ack',
      'locale', 'ca',
      'variables', jsonb_build_object(
        'request_type_label', v_label,
        'sla_days', COALESCE(v_settings.rights_sla_days, 30)::text
      )
    ));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'rights_request_ack email failed: %', SQLERRM;
  END;

  RETURN jsonb_build_object('ok', true, 'queued', true, 'request_id', v_req_id);
END;
$$;

GRANT EXECUTE ON FUNCTION api.submit_applicant_data_request(uuid, text, text, text)
  TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. list_applicant_data_requests
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
      r.request_type,
      r.status,
      r.fulfilled_via,
      r.requester_email,
      data.mask_email(r.requester_email) AS requester_email_masked,
      r.message,
      r.rejection_reason,
      r.due_at,
      r.sla_reminded_at,
      r.resolved_at,
      r.resolved_by,
      r.export_storage_path,
      r.created_at,
      CASE
        WHEN r.status = 'pending_review' AND r.due_at < now() THEN 'overdue'
        WHEN r.status = 'pending_review' AND r.due_at < now() + interval '3 days' THEN 'due_soon'
        ELSE 'ok'
      END AS sla_badge
    FROM data.applicant_data_requests r
    WHERE r.tenant_id = v_tenant
      AND (p_status IS NULL OR r.status = p_status)
  ) x;

  RETURN jsonb_build_object('items', v_rows);
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_applicant_data_requests(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. resolve_applicant_data_request
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.resolve_applicant_data_request(
  p_id uuid,
  p_action text,
  p_rejection_reason text DEFAULT NULL,
  p_export_base_url text DEFAULT NULL
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
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  IF NOT data.jwt_has_recruitment_permission(v_tenant, 'recruitment.rights') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501',
      HINT = 'Cal recruitment.rights';
  END IF;

  v_action := lower(trim(COALESCE(p_action, '')));
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

  v_label := CASE v_req.request_type
    WHEN 'access' THEN 'accés (Art. 15)'
    ELSE 'esborrat (Art. 17)'
  END;

  IF v_action = 'reject' THEN
    IF COALESCE(trim(p_rejection_reason), '') = '' THEN
      RAISE EXCEPTION 'rejection_reason_required';
    END IF;

    UPDATE data.applicant_data_requests SET
      status = 'rejected',
      fulfilled_via = 'rejected_with_reason',
      rejection_reason = trim(p_rejection_reason),
      resolved_at = now(),
      resolved_by = auth.uid(),
      updated_at = now()
    WHERE id = v_req.id;

    BEGIN
      PERFORM api.enqueue_email(jsonb_build_object(
        'tenant_id', v_tenant,
        'idempotency_key', 'rights-rejected-' || v_req.id::text,
        'to', jsonb_build_array(v_req.requester_email),
        'event_type', 'recruitment.rights_rejected',
        'locale', 'ca',
        'variables', jsonb_build_object(
          'request_type_label', v_label,
          'rejection_reason', trim(p_rejection_reason)
        )
      ));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'rights_rejected email failed: %', SQLERRM;
    END;

    RETURN jsonb_build_object('id', v_req.id, 'status', 'rejected');
  END IF;

  -- approve
  IF v_req.request_type = 'access' THEN
    IF v_req.applicant_id IS NULL THEN
      RAISE EXCEPTION 'applicant_missing';
    END IF;
    SELECT * INTO v_applicant FROM data.applicants WHERE id = v_req.applicant_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'applicant_missing';
    END IF;

    v_export := data.build_applicant_access_export(v_tenant, v_req.applicant_id);
    v_token := encode(gen_random_bytes(24), 'hex');
    v_token_hash := encode(digest(v_token, 'sha256'), 'hex');
    v_expires := now() + interval '7 days';
    v_path := 'rights/' || v_tenant::text || '/' || v_req.id::text || '.json';

    UPDATE data.applicant_data_requests SET
      status = 'fulfilled',
      fulfilled_via = 'email_export',
      export_json = v_export,
      export_storage_path = v_path,
      export_token_hash = v_token_hash,
      export_token_expires_at = v_expires,
      resolved_at = now(),
      resolved_by = auth.uid(),
      updated_at = now()
    WHERE id = v_req.id;

    IF COALESCE(trim(p_export_base_url), '') <> '' THEN
      v_url := rtrim(trim(p_export_base_url), '/')
        || '/api/recruitment/rights-export?token=' || v_token;
    ELSE
      v_url := '';
    END IF;

    BEGIN
      PERFORM api.enqueue_email(jsonb_build_object(
        'tenant_id', v_tenant,
        'idempotency_key', 'rights-access-' || v_req.id::text,
        'to', jsonb_build_array(v_req.requester_email),
        'event_type', 'recruitment.rights_access_fulfilled',
        'locale', 'ca',
        'variables', jsonb_build_object(
          'applicant_name', COALESCE(v_applicant.full_name, v_req.requester_email),
          'export_url', v_url,
          'export_expires_at', to_char(v_expires AT TIME ZONE 'Europe/Madrid', 'YYYY-MM-DD')
        )
      ));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'rights_access_fulfilled email failed: %', SQLERRM;
    END;

    RETURN jsonb_build_object(
      'id', v_req.id,
      'status', 'fulfilled',
      'fulfilled_via', 'email_export',
      'export_storage_path', v_path
    );
  END IF;

  -- erasure
  IF v_req.applicant_id IS NULL THEN
    RAISE EXCEPTION 'applicant_missing';
  END IF;

  v_purged := data.purge_applicant_for_rights(v_tenant, v_req.applicant_id);

  UPDATE data.applicant_data_requests SET
    status = 'fulfilled',
    fulfilled_via = 'purge',
    applicant_id = NULL,
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
      'variables', jsonb_build_object(
        'erased_at', to_char(now() AT TIME ZONE 'Europe/Madrid', 'YYYY-MM-DD')
      )
    ));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'rights_erasure_fulfilled email failed: %', SQLERRM;
  END;

  RETURN jsonb_build_object(
    'id', v_req.id,
    'status', 'fulfilled',
    'fulfilled_via', 'purge',
    'purged_applications', v_purged
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.resolve_applicant_data_request(uuid, text, text, text)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. fetch_rights_export (anon one-time token)
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

  -- One-time use
  UPDATE data.applicant_data_requests SET
    export_token_hash = NULL,
    export_token_expires_at = NULL,
    export_json = NULL,
    updated_at = now()
  WHERE id = v_req.id;

  RETURN jsonb_build_object(
    'ok', true,
    'export_storage_path', v_req.export_storage_path,
    'payload', v_payload
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.fetch_rights_export(text) TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 8. SLA reminder
-- ---------------------------------------------------------------------------
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
BEGIN
  FOR r IN
    SELECT req.*, s.rights_sla_days, t.name AS tenant_name
    FROM data.applicant_data_requests req
    JOIN data.recruitment_settings s ON s.tenant_id = req.tenant_id
    JOIN data.tenants t ON t.id = req.tenant_id
    WHERE req.status = 'pending_review'
      AND req.sla_reminded_at IS NULL
      AND req.due_at <= now() + interval '3 days'
      AND req.due_at > now() - interval '1 day'
  LOOP
    v_label := CASE r.request_type
      WHEN 'access' THEN 'accés (Art. 15)'
      ELSE 'esborrat (Art. 17)'
    END;

    -- Best-effort: email to requester as ack of pending (internal ops can poll list)
    BEGIN
      PERFORM api.enqueue_email(jsonb_build_object(
        'tenant_id', r.tenant_id,
        'idempotency_key', 'rights-sla-' || r.id::text,
        'to', jsonb_build_array(r.requester_email),
        'event_type', 'recruitment.rights_sla_reminder',
        'locale', 'ca',
        'variables', jsonb_build_object(
          'request_type_label', v_label,
          'due_at', to_char(r.due_at AT TIME ZONE 'Europe/Madrid', 'YYYY-MM-DD'),
          'requester_email', r.requester_email,
          'tenant_name', r.tenant_name
        )
      ));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'rights_sla_reminder failed: %', SQLERRM;
    END;

    UPDATE data.applicant_data_requests
    SET sla_reminded_at = now(), updated_at = now()
    WHERE id = r.id;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('recruitment-rights-sla-reminder');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    PERFORM cron.schedule(
      'recruitment-rights-sla-reminder',
      '0 8 * * *',
      $cron$SELECT data.remind_rights_sla()$cron$
    );
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';
