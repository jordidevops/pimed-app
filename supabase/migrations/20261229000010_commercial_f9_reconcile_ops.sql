-- CF-28 F9 Tall 3: commercial inconsistency reconcile (detect+alert) + ops metrics.

CREATE TABLE IF NOT EXISTS data.commercial_ops_job_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_name text NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  ok boolean,
  findings_count integer,
  payload jsonb,
  error_text text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_commercial_ops_job_runs_job_started
  ON data.commercial_ops_job_runs (job_name, started_at DESC);

ALTER TABLE data.commercial_ops_job_runs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON data.commercial_ops_job_runs FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON data.commercial_ops_job_runs TO service_role;
GRANT SELECT ON data.commercial_ops_job_runs TO prisma_admin;

CREATE TABLE IF NOT EXISTS data.commercial_ops_metric_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid REFERENCES data.tenants(id) ON DELETE SET NULL,
  metric text NOT NULL,
  request_id uuid,
  detail jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT commercial_ops_metric_events_metric_check
    CHECK (metric IN ('already_decided', 'rate_limited'))
);

CREATE INDEX IF NOT EXISTS idx_commercial_ops_metric_events_metric_created
  ON data.commercial_ops_metric_events (metric, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_commercial_ops_metric_events_tenant_created
  ON data.commercial_ops_metric_events (tenant_id, created_at DESC);

ALTER TABLE data.commercial_ops_metric_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON data.commercial_ops_metric_events FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON data.commercial_ops_metric_events TO service_role;
GRANT SELECT ON data.commercial_ops_metric_events TO prisma_admin;

CREATE OR REPLACE FUNCTION api.record_commercial_ops_metric(
  p_metric text,
  p_tenant_id uuid DEFAULT NULL,
  p_request_id uuid DEFAULT NULL,
  p_detail jsonb DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_metric IS NULL OR p_metric NOT IN ('already_decided', 'rate_limited') THEN
    RETURN;
  END IF;
  INSERT INTO data.commercial_ops_metric_events (tenant_id, metric, request_id, detail)
  VALUES (p_tenant_id, p_metric, p_request_id, p_detail);
END;
$$;

REVOKE ALL ON FUNCTION api.record_commercial_ops_metric(text, uuid, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_commercial_ops_metric(text, uuid, uuid, jsonb)
  TO service_role;

CREATE OR REPLACE FUNCTION api.record_commercial_ops_job_run(
  p_job_name text,
  p_ok boolean,
  p_findings_count integer DEFAULT NULL,
  p_payload jsonb DEFAULT NULL,
  p_error text DEFAULT NULL,
  p_started_at timestamptz DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO data.commercial_ops_job_runs (
    job_name, started_at, finished_at, ok, findings_count, payload, error_text
  ) VALUES (
    left(btrim(COALESCE(p_job_name, 'unknown')), 128),
    COALESCE(p_started_at, now()),
    now(),
    p_ok,
    p_findings_count,
    p_payload,
    left(NULLIF(btrim(COALESCE(p_error, '')), ''), 1000)
  )
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.record_commercial_ops_job_run(text, boolean, integer, jsonb, text, timestamptz)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_commercial_ops_job_run(text, boolean, integer, jsonb, text, timestamptz)
  TO service_role;

-- Detect-only reconcile (§9.6). Never auto-fixes contradictory outcomes.
CREATE OR REPLACE FUNCTION api.reconcile_commercial_decision_inconsistencies(
  p_limit integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_limit int := GREATEST(1, LEAST(COALESCE(p_limit, 50), 200));
  v_findings jsonb := '[]'::jsonb;
  v_started timestamptz := now();
BEGIN
  -- accepted request but target quote not accepted/signed
  v_findings := v_findings || COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'code', 'accepted_target_not_projected',
      'tenant_id', r.tenant_id,
      'request_id', r.id,
      'commercial_document_id', r.commercial_document_id,
      'doc_status', d.status
    ))
    FROM (
      SELECT r.*
      FROM data.commercial_decision_requests r
      JOIN data.commercial_documents d ON d.id = r.commercial_document_id
      WHERE r.status = 'accepted'
        AND r.commercial_document_id IS NOT NULL
        AND d.status NOT IN ('accepted', 'signed')
      ORDER BY r.updated_at DESC NULLS LAST
      LIMIT v_limit
    ) r
    JOIN data.commercial_documents d ON d.id = r.commercial_document_id
  ), '[]'::jsonb);

  -- signing submission completed + request still open (bridge)
  v_findings := v_findings || COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'code', 'submission_completed_request_open',
      'tenant_id', ss.tenant_id,
      'request_id', (ss.metadata->>'decision_request_id')::uuid,
      'submission_id', ss.id
    ))
    FROM (
      SELECT ss.*
      FROM data.signing_submissions ss
      JOIN data.commercial_decision_requests r
        ON r.id::text = ss.metadata->>'decision_request_id'
       AND r.tenant_id = ss.tenant_id
      WHERE ss.status = 'completed'
        AND COALESCE((ss.metadata->>'commercial_bridge')::boolean, false)
        AND NOT COALESCE((ss.metadata->>'superseded_by_switch')::boolean, false)
        AND r.status = 'open'
      ORDER BY ss.updated_at DESC
      LIMIT v_limit
    ) ss
  ), '[]'::jsonb);

  -- completed bridge missing result PDF
  v_findings := v_findings || COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'code', 'result_pdf_pending',
      'tenant_id', ss.tenant_id,
      'submission_id', ss.id,
      'request_id', ss.metadata->>'decision_request_id',
      'artifact_status', ss.metadata->>'artifact_status'
    ))
    FROM (
      SELECT *
      FROM data.signing_submissions ss
      WHERE ss.status = 'completed'
        AND ss.result_document_version_id IS NULL
        AND COALESCE((ss.metadata->>'commercial_bridge')::boolean, false)
        AND NOT COALESCE((ss.metadata->>'superseded_by_switch')::boolean, false)
      ORDER BY ss.updated_at ASC
      LIMIT v_limit
    ) ss
  ), '[]'::jsonb);

  -- active token on terminal request
  v_findings := v_findings || COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'code', 'active_token_on_terminal_request',
      'tenant_id', r.tenant_id,
      'request_id', r.id,
      'token_id', t.id,
      'request_status', r.status
    ))
    FROM (
      SELECT t.id, t.request_id
      FROM data.commercial_decision_access_tokens t
      JOIN data.commercial_decision_requests r ON r.id = t.request_id
      WHERE t.status = 'active'
        AND r.status IN ('accepted', 'declined', 'expired', 'revoked', 'superseded')
      ORDER BY t.created_at DESC
      LIMIT v_limit
    ) t
    JOIN data.commercial_decision_requests r ON r.id = t.request_id
  ), '[]'::jsonb);

  -- defense: more than one open request per target document
  v_findings := v_findings || COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'code', 'multiple_open_requests',
      'tenant_id', x.tenant_id,
      'commercial_document_id', x.commercial_document_id,
      'open_count', x.open_count
    ))
    FROM (
      SELECT tenant_id, commercial_document_id, count(*)::int AS open_count
      FROM data.commercial_decision_requests
      WHERE status = 'open'
        AND commercial_document_id IS NOT NULL
      GROUP BY tenant_id, commercial_document_id
      HAVING count(*) > 1
      LIMIT v_limit
    ) x
  ), '[]'::jsonb);

  -- delivery queued without email_log_id
  v_findings := v_findings || COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'code', 'delivery_queued_without_email_log',
      'tenant_id', d.tenant_id,
      'delivery_id', d.id,
      'request_id', d.request_id
    ))
    FROM (
      SELECT d.*
      FROM data.commercial_decision_deliveries d
      WHERE d.channel = 'email'
        AND d.status = 'queued'
        AND d.email_log_id IS NULL
        AND d.created_at < now() - interval '15 minutes'
      ORDER BY d.created_at ASC
      LIMIT v_limit
    ) d
  ), '[]'::jsonb);

  PERFORM api.record_commercial_ops_job_run(
    'reconcile_commercial_decision_inconsistencies',
    true,
    jsonb_array_length(v_findings),
    jsonb_build_object('findings', v_findings),
    NULL,
    v_started
  );

  RETURN jsonb_build_object(
    'ok', true,
    'findings_count', jsonb_array_length(v_findings),
    'findings', v_findings
  );
EXCEPTION WHEN OTHERS THEN
  PERFORM api.record_commercial_ops_job_run(
    'reconcile_commercial_decision_inconsistencies',
    false,
    NULL,
    NULL,
    SQLERRM,
    v_started
  );
  RETURN jsonb_build_object('ok', false, 'code', 'reconcile_failed');
END;
$$;

REVOKE ALL ON FUNCTION api.reconcile_commercial_decision_inconsistencies(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.reconcile_commercial_decision_inconsistencies(integer)
  TO service_role;

-- Instrument already_decided via trigger on events is weak; wrap note into apply
-- by replacing only a helper used from edge + optional cron.
-- Also patch: when commercial_decision_requests stay terminal, count conflict applies
-- from API wrapper used by office if present — add SECURITY DEFINER shim:

CREATE OR REPLACE FUNCTION api.apply_commercial_decision_request(
  p_request_id uuid,
  p_outcome text,
  p_via text,
  p_evidence jsonb DEFAULT '{}'::jsonb,
  p_client_op_id uuid DEFAULT NULL,
  p_actor_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb;
  v_tenant uuid;
BEGIN
  v_result := data.apply_commercial_decision_request(
    p_request_id, p_outcome, p_via, p_evidence, p_client_op_id, p_actor_id
  );

  IF COALESCE((v_result->>'already_decided')::boolean, false) THEN
    SELECT tenant_id INTO v_tenant
    FROM data.commercial_decision_requests
    WHERE id = p_request_id;
    PERFORM api.record_commercial_ops_metric(
      'already_decided',
      v_tenant,
      p_request_id,
      jsonb_build_object('via', p_via, 'outcome', p_outcome)
    );
  END IF;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION api.apply_commercial_decision_request(uuid, text, text, jsonb, uuid, uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.apply_commercial_decision_request(uuid, text, text, jsonb, uuid, uuid)
  TO authenticated, service_role;

-- Office decline/accept path: instrument already_decided
CREATE OR REPLACE FUNCTION api.apply_commercial_decision_office(
  p_request_id uuid,
  p_outcome text,
  p_reason text,
  p_client_op_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_req data.commercial_decision_requests%ROWTYPE;
  v_evidence jsonb;
  v_result jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_req FROM data.commercial_decision_requests WHERE id = p_request_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_req.tenant_id::text) THEN
    RAISE EXCEPTION 'decision_request_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF p_outcome = 'declined' AND (p_reason IS NULL OR btrim(p_reason) = '') THEN
    RAISE EXCEPTION 'office_decline_reason_required' USING ERRCODE = 'P0001';
  END IF;
  v_evidence := jsonb_strip_nulls(jsonb_build_object(
    'method', 'office',
    'role', 'office_reject',
    'reason', NULLIF(btrim(p_reason), '')
  ));
  v_result := data.apply_commercial_decision_request(
    p_request_id, p_outcome, 'office', v_evidence, p_client_op_id, v_uid
  );
  IF COALESCE((v_result->>'already_decided')::boolean, false) THEN
    PERFORM api.record_commercial_ops_metric(
      'already_decided',
      v_req.tenant_id,
      p_request_id,
      jsonb_build_object('via', 'office', 'outcome', p_outcome)
    );
  END IF;
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION api.apply_commercial_decision_office(uuid, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.apply_commercial_decision_office(uuid, text, text, uuid)
  TO authenticated, service_role;

-- Cron: every 30 minutes (best-effort; vault URL same pattern as other jobs)
CREATE OR REPLACE FUNCTION data.invoke_commercial_decision_reconcile(
  p_limit integer DEFAULT 50
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_supabase_url text;
  v_service_key text;
  v_request_id bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RETURN -2;
  END IF;

  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets WHERE name = 'app_supabase_url' LIMIT 1;
  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets WHERE name = 'app_service_role_key' LIMIT 1;

  IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
    RETURN -1;
  END IF;

  BEGIN
    SELECT extensions.http_post(
      url := v_supabase_url || '/functions/v1/reconcile-commercial-decision-ops',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || v_service_key
      ),
      body := jsonb_build_object('limit', COALESCE(p_limit, 50)),
      timeout_milliseconds := 60000
    ) INTO v_request_id;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'invoke_commercial_decision_reconcile failed: %', SQLERRM;
    RETURN NULL;
  END;

  RETURN v_request_id;
END;
$$;

REVOKE ALL ON FUNCTION data.invoke_commercial_decision_reconcile(integer) FROM PUBLIC;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('commercial_decision_reconcile')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'commercial_decision_reconcile'
    );
    PERFORM cron.schedule(
      'commercial_decision_reconcile',
      '*/30 * * * *',
      'SELECT data.invoke_commercial_decision_reconcile(50)'
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'commercial_decision_reconcile cron not scheduled: %', SQLERRM;
END $$;

NOTIFY pgrst, 'reload schema';
