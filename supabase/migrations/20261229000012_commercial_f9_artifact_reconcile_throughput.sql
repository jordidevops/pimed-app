-- CF-28 F9 scale Tall 1B: artifact reconcile throughput (cron + list limit).
-- Does not claim Gate F / SLO; raises cadence from */10×20 to */2×50.

-- ---------------------------------------------------------------------------
-- Job run metrics: duration + detail (backlog_hint, etc.)
-- ---------------------------------------------------------------------------
ALTER TABLE data.signing_ops_job_runs
  ADD COLUMN IF NOT EXISTS duration_ms integer,
  ADD COLUMN IF NOT EXISTS detail jsonb;

CREATE OR REPLACE FUNCTION api.record_signing_ops_job_run(
  p_job_name text,
  p_ok boolean,
  p_listed integer DEFAULT NULL,
  p_attempted integer DEFAULT NULL,
  p_attached integer DEFAULT NULL,
  p_skipped integer DEFAULT NULL,
  p_error text DEFAULT NULL,
  p_started_at timestamptz DEFAULT NULL,
  p_duration_ms integer DEFAULT NULL,
  p_detail jsonb DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF NULLIF(btrim(COALESCE(p_job_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'invalid_job_name' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.signing_ops_job_runs (
    job_name, started_at, finished_at, ok,
    listed, attempted, attached, skipped, error_text,
    duration_ms, detail
  ) VALUES (
    left(btrim(p_job_name), 128),
    COALESCE(p_started_at, now()),
    now(),
    p_ok,
    p_listed,
    p_attempted,
    p_attached,
    p_skipped,
    left(NULLIF(btrim(COALESCE(p_error, '')), ''), 1000),
    p_duration_ms,
    p_detail
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.record_signing_ops_job_run(
  text, boolean, integer, integer, integer, integer, text, timestamptz, integer, jsonb
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_signing_ops_job_run(
  text, boolean, integer, integer, integer, integer, text, timestamptz, integer, jsonb
) TO service_role;

-- Keep old 8-arg overload callable (PostgREST may still use it via named args on new fn).
-- Drop previous 8-arg signature if it conflicts with CREATE OR REPLACE name change.
DROP FUNCTION IF EXISTS api.record_signing_ops_job_run(
  text, boolean, integer, integer, integer, integer, text, timestamptz
);

-- ---------------------------------------------------------------------------
-- List needing reconcile: higher cap, stable order
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_signing_submissions_needing_artifact_reconcile(
  p_limit integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_limit int := GREATEST(1, LEAST(COALESCE(p_limit, 50), 100));
BEGIN
  RETURN COALESCE((
    SELECT jsonb_agg(row_to_json(x)::jsonb ORDER BY x.updated_at ASC, x.submission_id ASC)
    FROM (
      SELECT
        ss.id AS submission_id,
        ss.tenant_id,
        ss.docuseal_submission_id,
        ss.metadata->>'decision_request_id' AS decision_request_id,
        ss.metadata->>'artifact_status' AS artifact_status,
        ss.artifact_retry_url AS artifact_signed_url,
        ss.metadata->>'artifact_error' AS artifact_error,
        ss.updated_at
      FROM data.signing_submissions ss
      WHERE ss.status = 'completed'
        AND ss.result_document_version_id IS NULL
        AND COALESCE((ss.metadata->>'commercial_bridge')::boolean, false)
        AND NOT COALESCE((ss.metadata->>'superseded_by_switch')::boolean, false)
        AND COALESCE(ss.metadata->>'artifact_status', 'failed') IN ('pending', 'failed')
        AND NULLIF(btrim(COALESCE(ss.artifact_retry_url, '')), '') IS NOT NULL
      ORDER BY ss.updated_at ASC, ss.id ASC
      LIMIT v_limit
    ) x
  ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION api.list_signing_submissions_needing_artifact_reconcile(integer)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_signing_submissions_needing_artifact_reconcile(integer)
  TO service_role;

-- Cheap backlog hint for ops (capped count)
CREATE OR REPLACE FUNCTION api.count_signing_submissions_needing_artifact_reconcile(
  p_cap integer DEFAULT 500
)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_cap int := GREATEST(1, LEAST(COALESCE(p_cap, 500), 2000));
  v_n int;
BEGIN
  SELECT count(*)::int INTO v_n
  FROM (
    SELECT 1
    FROM data.signing_submissions ss
    WHERE ss.status = 'completed'
      AND ss.result_document_version_id IS NULL
      AND COALESCE((ss.metadata->>'commercial_bridge')::boolean, false)
      AND NOT COALESCE((ss.metadata->>'superseded_by_switch')::boolean, false)
      AND COALESCE(ss.metadata->>'artifact_status', 'failed') IN ('pending', 'failed')
      AND NULLIF(btrim(COALESCE(ss.artifact_retry_url, '')), '') IS NOT NULL
    LIMIT v_cap
  ) x;
  RETURN v_n;
END;
$$;

REVOKE ALL ON FUNCTION api.count_signing_submissions_needing_artifact_reconcile(integer)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.count_signing_submissions_needing_artifact_reconcile(integer)
  TO service_role;

-- ---------------------------------------------------------------------------
-- Invoke + cron cadence
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.invoke_docuseal_artifact_reconcile(p_limit integer DEFAULT 50)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_supabase_url text;
  v_service_key text;
  v_request_id bigint;
  v_limit int := GREATEST(1, LEAST(COALESCE(p_limit, 50), 100));
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
      url := v_supabase_url || '/functions/v1/reconcile-docuseal-signed-artifacts',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || v_service_key
      ),
      body := jsonb_build_object('limit', v_limit),
      timeout_milliseconds := 60000
    ) INTO v_request_id;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'invoke_docuseal_artifact_reconcile failed: %', SQLERRM;
    RETURN NULL;
  END;

  RETURN v_request_id;
END;
$$;

REVOKE ALL ON FUNCTION data.invoke_docuseal_artifact_reconcile(integer) FROM PUBLIC;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('reconcile-docuseal-signed-artifacts')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'reconcile-docuseal-signed-artifacts'
    );
    PERFORM cron.schedule(
      'reconcile-docuseal-signed-artifacts',
      '*/2 * * * *',
      'SELECT data.invoke_docuseal_artifact_reconcile(50)'
    );
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';
