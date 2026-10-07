-- CS-D58 / CS-D60 follow-up:
-- - redact signing/decision email bodies from api.email_logs (tenant)
-- - allow authenticated signer to fetch only their own pending signing URL

-- ---------------------------------------------------------------------------
-- 1. api.email_logs — null bodies for signing / commercial.decision templates
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api.email_logs;

CREATE VIEW api.email_logs
  WITH (security_invoker = true) AS
  SELECT
    el.id,
    el.tenant_id,
    el.site_id,
    el.idempotency_key,
    el.status,
    el.email_type,
    el.from_email,
    el.from_name,
    el.to_emails,
    el.cc_emails,
    el.bcc_emails,
    el.reply_to,
    el.subject,
    CASE
      WHEN (
        et.event_type LIKE 'signing.%'
        OR et.event_type LIKE 'commercial.decision%'
        OR COALESCE(el.html_body, '') ILIKE '%/sign/%'
        OR COALESCE(el.text_body, '') ILIKE '%/sign/%'
        OR COALESCE(el.html_body, '') ILIKE '%docuseal%'
        OR COALESCE(el.text_body, '') ILIKE '%docuseal%'
      ) THEN NULL
      ELSE el.html_body
    END AS html_body,
    CASE
      WHEN (
        et.event_type LIKE 'signing.%'
        OR et.event_type LIKE 'commercial.decision%'
        OR COALESCE(el.html_body, '') ILIKE '%/sign/%'
        OR COALESCE(el.text_body, '') ILIKE '%/sign/%'
        OR COALESCE(el.html_body, '') ILIKE '%docuseal%'
        OR COALESCE(el.text_body, '') ILIKE '%docuseal%'
      ) THEN NULL
      ELSE el.text_body
    END AS text_body,
    el.provider,
    el.provider_message_id,
    el.attempt_count,
    el.is_dead_letter,
    el.last_error,
    el.error_history,
    el.tags,
    el.scheduled_at,
    el.created_at,
    el.sent_at,
    el.delivered_at,
    el.template_id,
    CASE
      WHEN (
        et.event_type LIKE 'signing.%'
        OR et.event_type LIKE 'commercial.decision%'
        OR COALESCE(el.html_body, '') ILIKE '%/sign/%'
        OR COALESCE(el.text_body, '') ILIKE '%/sign/%'
        OR COALESCE(el.html_body, '') ILIKE '%docuseal%'
        OR COALESCE(el.text_body, '') ILIKE '%docuseal%'
      ) THEN true
      ELSE false
    END AS body_redacted
  FROM data.email_logs el
  LEFT JOIN data.email_templates et ON et.id = el.template_id;

GRANT SELECT ON api.email_logs TO authenticated;
GRANT SELECT ON api.email_logs TO service_role;

COMMENT ON VIEW api.email_logs IS
  'Tenant email logs; signing/decision template bodies redacted (CS-D58).';

-- ---------------------------------------------------------------------------
-- 2. Own-signer URL only (monthly HR self-sign exception, CS-D58 §4)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_my_pending_signing_url(p_submission_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_email text;
  v_tenant uuid;
  v_signers jsonb;
  v_url text;
  v_status text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_submission_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT lower(btrim(u.email)) INTO v_email
  FROM auth.users u
  WHERE u.id = v_uid;

  IF v_email IS NULL OR v_email = '' THEN
    RETURN NULL;
  END IF;

  SELECT ss.tenant_id, ss.signers, ss.status
  INTO v_tenant, v_signers, v_status
  FROM data.signing_submissions ss
  WHERE ss.id = p_submission_id;

  IF v_tenant IS NULL THEN
    RETURN NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM data.tenant_members tm
    WHERE tm.tenant_id = v_tenant
      AND tm.user_id = v_uid
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'P0001';
  END IF;

  IF v_status IN ('completed', 'declined', 'expired', 'cancelled', 'error') THEN
    RETURN NULL;
  END IF;

  SELECT x.url
  INTO v_url
  FROM (
    SELECT
      NULLIF(e->>'signing_url', '') AS url,
      COALESCE((e->>'order')::int, 0) AS ord
    FROM jsonb_array_elements(COALESCE(v_signers, '[]'::jsonb)) e
    WHERE lower(btrim(COALESCE(e->>'email', ''))) = v_email
      AND lower(COALESCE(e->>'status', 'pending')) NOT IN ('completed', 'signed')
  ) x
  WHERE x.url IS NOT NULL
  ORDER BY x.ord
  LIMIT 1;

  RETURN v_url;
END;
$$;

REVOKE ALL ON FUNCTION api.get_my_pending_signing_url(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_my_pending_signing_url(uuid) TO authenticated;

COMMENT ON FUNCTION api.get_my_pending_signing_url(uuid) IS
  'CS-D58 §4: returns signing_url only for the authenticated user matching a pending signer email.';

NOTIFY pgrst, 'reload schema';
