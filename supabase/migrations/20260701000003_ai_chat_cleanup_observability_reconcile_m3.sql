-- M3 hardening: persistent run logs + storage_usage reconciliation helpers

-- ---------------------------------------------------------------------------
-- 1) Cleanup run log
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.ai_chat_orphan_cleanup_runs (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  started_at    timestamptz NOT NULL DEFAULT now(),
  finished_at   timestamptz,
  ttl_days      integer NOT NULL,
  batch_limit   integer NOT NULL,
  iterations    integer NOT NULL DEFAULT 0,
  candidates    integer NOT NULL DEFAULT 0,
  deleted       integer NOT NULL DEFAULT 0,
  errors        integer NOT NULL DEFAULT 0,
  locked_skip   boolean NOT NULL DEFAULT false,
  duration_ms   bigint NOT NULL DEFAULT 0,
  details       jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_ai_chat_orphan_cleanup_runs_started
  ON data.ai_chat_orphan_cleanup_runs (started_at DESC);

REVOKE ALL ON data.ai_chat_orphan_cleanup_runs FROM PUBLIC;
REVOKE ALL ON data.ai_chat_orphan_cleanup_runs FROM authenticated;
GRANT SELECT, INSERT ON data.ai_chat_orphan_cleanup_runs TO service_role;

-- ---------------------------------------------------------------------------
-- 2) Wrapper with persistent logging
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.run_ai_chat_orphan_cleanup_logged(
  p_ttl_days    integer DEFAULT 90,
  p_batch_limit integer DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_started_at timestamptz := clock_timestamp();
  v_result     jsonb;
BEGIN
  v_result := data.cleanup_orphan_ai_chat_attachments(p_ttl_days, p_batch_limit);

  INSERT INTO data.ai_chat_orphan_cleanup_runs (
    started_at,
    finished_at,
    ttl_days,
    batch_limit,
    iterations,
    candidates,
    deleted,
    errors,
    locked_skip,
    duration_ms,
    details
  )
  VALUES (
    v_started_at,
    clock_timestamp(),
    COALESCE((v_result ->> 'ttl_days')::integer, p_ttl_days),
    COALESCE((v_result ->> 'batch_limit')::integer, p_batch_limit),
    COALESCE((v_result ->> 'iterations')::integer, 0),
    COALESCE((v_result ->> 'candidates')::integer, 0),
    COALESCE((v_result ->> 'deleted')::integer, 0),
    COALESCE((v_result ->> 'errors')::integer, 0),
    COALESCE((v_result ->> 'locked_skip')::boolean, false),
    COALESCE((v_result ->> 'duration_ms')::bigint, 0),
    v_result
  );

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION data.run_ai_chat_orphan_cleanup_logged(integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.run_ai_chat_orphan_cleanup_logged(integer, integer) FROM authenticated;
REVOKE ALL ON FUNCTION data.run_ai_chat_orphan_cleanup_logged(integer, integer) FROM anon;

CREATE OR REPLACE FUNCTION api.run_ai_chat_orphan_cleanup_service(
  p_ttl_days    integer DEFAULT 90,
  p_batch_limit integer DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  RETURN data.run_ai_chat_orphan_cleanup_logged(p_ttl_days, p_batch_limit);
END;
$$;

REVOKE ALL ON FUNCTION api.run_ai_chat_orphan_cleanup_service(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.run_ai_chat_orphan_cleanup_service(integer, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) storage_usage reconciliation helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.reconcile_storage_usage_for_tenant(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_old_file_count  integer := 0;
  v_old_committed   bigint := 0;
  v_old_reserved    bigint := 0;
  v_new_file_count  integer := 0;
  v_new_committed   bigint := 0;
  v_new_reserved    bigint := 0;
BEGIN
  SELECT
    COALESCE(file_count, 0),
    COALESCE(committed_bytes, 0),
    COALESCE(reserved_bytes, 0)
  INTO
    v_old_file_count,
    v_old_committed,
    v_old_reserved
  FROM data.storage_usage
  WHERE tenant_id = p_tenant_id;

  SELECT
    COUNT(*) FILTER (
      WHERE fn.node_type = 'file'
        AND fn.processing_status <> 'pending'
    )::integer,
    COALESCE(SUM(fn.size_bytes) FILTER (
      WHERE fn.node_type = 'file'
        AND fn.processing_status <> 'pending'
    ), 0)::bigint,
    COALESCE(SUM(fn.size_bytes) FILTER (
      WHERE fn.node_type = 'file'
        AND fn.processing_status = 'pending'
    ), 0)::bigint
  INTO
    v_new_file_count,
    v_new_committed,
    v_new_reserved
  FROM data.file_nodes fn
  WHERE fn.tenant_id = p_tenant_id;

  INSERT INTO data.storage_usage (
    tenant_id,
    file_count,
    committed_bytes,
    reserved_bytes
  )
  VALUES (
    p_tenant_id,
    v_new_file_count,
    v_new_committed,
    v_new_reserved
  )
  ON CONFLICT (tenant_id) DO UPDATE
    SET file_count = EXCLUDED.file_count,
        committed_bytes = EXCLUDED.committed_bytes,
        reserved_bytes = EXCLUDED.reserved_bytes,
        updated_at = now();

  RETURN jsonb_build_object(
    'tenant_id', p_tenant_id,
    'before', jsonb_build_object(
      'file_count', v_old_file_count,
      'committed_bytes', v_old_committed,
      'reserved_bytes', v_old_reserved
    ),
    'after', jsonb_build_object(
      'file_count', v_new_file_count,
      'committed_bytes', v_new_committed,
      'reserved_bytes', v_new_reserved
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION data.reconcile_storage_usage_for_tenant(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.reconcile_storage_usage_for_tenant(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION data.reconcile_storage_usage_for_tenant(uuid) FROM anon;

CREATE OR REPLACE FUNCTION data.reconcile_storage_usage_batch(
  p_limit integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_limit     integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 500);
  v_tenant    record;
  v_processed integer := 0;
BEGIN
  FOR v_tenant IN
    SELECT t.id
    FROM data.tenants t
    ORDER BY t.created_at DESC
    LIMIT v_limit
  LOOP
    PERFORM data.reconcile_storage_usage_for_tenant(v_tenant.id);
    v_processed := v_processed + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'limit', v_limit,
    'processed', v_processed
  );
END;
$$;

REVOKE ALL ON FUNCTION data.reconcile_storage_usage_batch(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.reconcile_storage_usage_batch(integer) FROM authenticated;
REVOKE ALL ON FUNCTION data.reconcile_storage_usage_batch(integer) FROM anon;

CREATE OR REPLACE FUNCTION api.reconcile_storage_usage_service(
  p_tenant_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_tenant_id IS NOT NULL THEN
    RETURN data.reconcile_storage_usage_for_tenant(p_tenant_id);
  END IF;

  RETURN data.reconcile_storage_usage_batch(p_limit);
END;
$$;

REVOKE ALL ON FUNCTION api.reconcile_storage_usage_service(uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.reconcile_storage_usage_service(uuid, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) Schedule logged cleanup + low-priority weekly reconciliation
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_job_id bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    SELECT jobid INTO v_job_id
    FROM cron.job
    WHERE jobname = 'cleanup-orphan-ai-chat-attachments'
    LIMIT 1;

    IF v_job_id IS NOT NULL THEN
      PERFORM cron.unschedule(v_job_id);
    END IF;

    PERFORM cron.schedule(
      'cleanup-orphan-ai-chat-attachments',
      '17 * * * *',
      'SELECT data.run_ai_chat_orphan_cleanup_logged();'
    );

    SELECT jobid INTO v_job_id
    FROM cron.job
    WHERE jobname = 'reconcile-storage-usage-weekly'
    LIMIT 1;

    IF v_job_id IS NOT NULL THEN
      PERFORM cron.unschedule(v_job_id);
    END IF;

    -- Sunday early morning UTC, intentionally off-cycle from other jobs.
    PERFORM cron.schedule(
      'reconcile-storage-usage-weekly',
      '43 4 * * 0',
      'SELECT data.reconcile_storage_usage_batch(50);'
    );
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';
