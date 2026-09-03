-- =============================================================================
-- REC-5c — Drets Art. 16 / 18 / 20 / 21 (sobre safata REC-5b)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Schema: request types + fulfilled_via + resolution_notes
-- ---------------------------------------------------------------------------
ALTER TABLE data.applicant_data_requests
  DROP CONSTRAINT IF EXISTS applicant_data_requests_request_type_check;

ALTER TABLE data.applicant_data_requests
  ADD CONSTRAINT applicant_data_requests_request_type_check
  CHECK (request_type IN (
    'access', 'erasure', 'rectification', 'restriction', 'portability', 'objection'
  ));

ALTER TABLE data.applicant_data_requests
  DROP CONSTRAINT IF EXISTS applicant_data_requests_fulfilled_via_check;

ALTER TABLE data.applicant_data_requests
  ADD CONSTRAINT applicant_data_requests_fulfilled_via_check
  CHECK (
    fulfilled_via IS NULL
    OR fulfilled_via IN (
      'email_export',
      'purge',
      'rejected_with_reason',
      'field_update',
      'restriction_flag',
      'preference_update'
    )
  );

ALTER TABLE data.applicant_data_requests
  ADD COLUMN IF NOT EXISTS resolution_notes text;

-- Applicant flags (Art. 18 / 21)
ALTER TABLE data.applicants
  ADD COLUMN IF NOT EXISTS processing_restricted_at timestamptz;

ALTER TABLE data.applicants
  ADD COLUMN IF NOT EXISTS objection_at timestamptz;

DROP VIEW IF EXISTS api.applicants;
CREATE VIEW api.applicants
WITH (security_invoker = true) AS
SELECT
  id, tenant_id, email, full_name, phone,
  email_verified_at, talent_pool_until,
  processing_restricted_at, objection_at,
  created_at, updated_at
FROM data.applicants;

GRANT SELECT ON api.applicants TO authenticated;

DROP VIEW IF EXISTS api.applicant_data_requests;
CREATE VIEW api.applicant_data_requests
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
  resolution_notes,
  due_at,
  sla_reminded_at,
  resolved_at,
  resolved_by,
  export_storage_path,
  created_at,
  updated_at
FROM data.applicant_data_requests;

GRANT SELECT ON api.applicant_data_requests TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Label helper
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.rights_request_type_label(p_type text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_type
    WHEN 'access' THEN 'accés (Art. 15)'
    WHEN 'erasure' THEN 'esborrat (Art. 17)'
    WHEN 'rectification' THEN 'rectificació (Art. 16)'
    WHEN 'restriction' THEN 'limitació (Art. 18)'
    WHEN 'portability' THEN 'portabilitat (Art. 20)'
    WHEN 'objection' THEN 'oposició (Art. 21)'
    ELSE COALESCE(p_type, 'desconegut')
  END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Email templates
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
  'Rectificació atesa (Art. 16)',
  'recruitment-rights-rectification-fulfilled',
  'recruitment.rights_rectification_fulfilled',
  'Hem atès la teva petició de rectificació',
  '<p>Hola,</p>
<p>Hem revisat i atès la teva petició de rectificació (Art. 16).</p>
<p>{{resolution_notes}}</p>',
  'Rectificació atesa. {{resolution_notes}}',
  '{"resolution_notes":"string","tenant_name":"string"}'::jsonb,
  '{}'::jsonb,
  false, NULL, true, true, true, false
),
(
  NULL,
  'Limitació atesa (Art. 18)',
  'recruitment-rights-restriction-fulfilled',
  'recruitment.rights_restriction_fulfilled',
  'Hem limitat el tractament de les teves dades',
  '<p>Hola,</p>
<p>Hem marcat les teves dades de candidatura amb limitació de tractament (Art. 18) des del {{restricted_at}}.</p>',
  'Limitació de tractament des de {{restricted_at}}.',
  '{"restricted_at":"string","tenant_name":"string"}'::jsonb,
  '{}'::jsonb,
  false, NULL, true, true, true, false
),
(
  NULL,
  'Oposició atesa (Art. 21)',
  'recruitment-rights-objection-fulfilled',
  'recruitment.rights_objection_fulfilled',
  'Hem registrat la teva oposició',
  '<p>Hola,</p>
<p>Hem registrat la teva oposició al tractament (Art. 21). No et mantindrem al talent pool.</p>
<p>{{resolution_notes}}</p>',
  'Oposició registrada. {{resolution_notes}}',
  '{"resolution_notes":"string","tenant_name":"string"}'::jsonb,
  '{}'::jsonb,
  false, NULL, true, true, true, false
)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. submit (extended types)
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
  IF v_type NOT IN (
    'access', 'erasure', 'rectification', 'restriction', 'portability', 'objection'
  ) THEN
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

  IF NOT FOUND THEN
    IF v_type IN ('access', 'portability') THEN
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
  v_label := data.rights_request_type_label(v_type);

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

-- ---------------------------------------------------------------------------
-- 5. list (include notes + applicant flags)
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
      r.resolution_notes,
      r.due_at,
      r.sla_reminded_at,
      r.resolved_at,
      r.resolved_by,
      r.export_storage_path,
      r.created_at,
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

-- ---------------------------------------------------------------------------
-- 6. resolve (extended) — drop 4-arg overload, create 5-arg
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.resolve_applicant_data_request(uuid, text, text, text);

CREATE OR REPLACE FUNCTION api.resolve_applicant_data_request(
  p_id uuid,
  p_action text,
  p_rejection_reason text DEFAULT NULL,
  p_export_base_url text DEFAULT NULL,
  p_resolution_notes text DEFAULT NULL
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

  v_label := data.rights_request_type_label(v_req.request_type);
  v_notes := nullif(trim(COALESCE(p_resolution_notes, '')), '');

  IF v_action = 'reject' THEN
    IF COALESCE(trim(p_rejection_reason), '') = '' THEN
      RAISE EXCEPTION 'rejection_reason_required';
    END IF;

    UPDATE data.applicant_data_requests SET
      status = 'rejected',
      fulfilled_via = 'rejected_with_reason',
      rejection_reason = trim(p_rejection_reason),
      resolution_notes = v_notes,
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

  -- approve: access OR portability → export
  IF v_req.request_type IN ('access', 'portability') THEN
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
      resolution_notes = v_notes,
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
  END IF;

  -- restriction / objection / rectification need applicant
  IF v_req.applicant_id IS NULL THEN
    RAISE EXCEPTION 'applicant_missing';
  END IF;
  SELECT * INTO v_applicant FROM data.applicants WHERE id = v_req.applicant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'applicant_missing';
  END IF;

  IF v_req.request_type = 'rectification' THEN
    IF v_notes IS NULL THEN
      RAISE EXCEPTION 'resolution_notes_required';
    END IF;

    UPDATE data.applicant_data_requests SET
      status = 'fulfilled',
      fulfilled_via = 'field_update',
      resolution_notes = v_notes,
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
        'variables', jsonb_build_object('resolution_notes', v_notes)
      ));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'rights_rectification_fulfilled email failed: %', SQLERRM;
    END;

    RETURN jsonb_build_object(
      'id', v_req.id,
      'status', 'fulfilled',
      'fulfilled_via', 'field_update'
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
        'variables', jsonb_build_object(
          'restricted_at', to_char(now() AT TIME ZONE 'Europe/Madrid', 'YYYY-MM-DD')
        )
      ));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'rights_restriction_fulfilled email failed: %', SQLERRM;
    END;

    RETURN jsonb_build_object(
      'id', v_req.id,
      'status', 'fulfilled',
      'fulfilled_via', 'restriction_flag'
    );
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
        'variables', jsonb_build_object('resolution_notes', v_notes)
      ));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'rights_objection_fulfilled email failed: %', SQLERRM;
    END;

    RETURN jsonb_build_object(
      'id', v_req.id,
      'status', 'fulfilled',
      'fulfilled_via', 'preference_update'
    );
  END IF;

  RAISE EXCEPTION 'invalid_request_type';
END;
$$;

GRANT EXECUTE ON FUNCTION api.resolve_applicant_data_request(uuid, text, text, text, text)
  TO authenticated;

-- SLA reminder labels via helper
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
    SELECT req.*, t.name AS tenant_name
    FROM data.applicant_data_requests req
    JOIN data.tenants t ON t.id = req.tenant_id
    WHERE req.status = 'pending_review'
      AND req.sla_reminded_at IS NULL
      AND req.due_at <= now() + interval '3 days'
      AND req.due_at > now() - interval '1 day'
  LOOP
    v_label := data.rights_request_type_label(r.request_type);

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

NOTIFY pgrst, 'reload schema';
