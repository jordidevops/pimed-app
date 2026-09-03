-- M2 hardening: higher throughput + concurrency guard + richer metrics

CREATE OR REPLACE FUNCTION data.cleanup_orphan_ai_chat_attachments(
  p_ttl_days    integer DEFAULT 90,
  p_batch_limit integer DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_ttl_days          integer := GREATEST(COALESCE(p_ttl_days, 90), 1);
  v_batch_limit       integer := LEAST(GREATEST(COALESCE(p_batch_limit, 200), 1), 1000);
  v_max_iterations    integer := 3;
  v_candidate         record;
  v_batch_candidates  integer;
  v_deleted           integer := 0;
  v_errors            integer := 0;
  v_candidates        integer := 0;
  v_iterations        integer := 0;
  v_locked            boolean := false;
  v_started_at        timestamptz := clock_timestamp();
  v_lock_key          integer := hashtext('data.cleanup_orphan_ai_chat_attachments.v2');
BEGIN
  v_locked := pg_try_advisory_lock(v_lock_key);
  IF NOT v_locked THEN
    RETURN jsonb_build_object(
      'ttl_days', v_ttl_days,
      'batch_limit', v_batch_limit,
      'iterations', 0,
      'candidates', 0,
      'deleted', 0,
      'errors', 0,
      'locked_skip', true,
      'duration_ms', 0
    );
  END IF;

  BEGIN
    LOOP
      EXIT WHEN v_iterations >= v_max_iterations;
      v_iterations := v_iterations + 1;
      v_batch_candidates := 0;

      FOR v_candidate IN
        SELECT fn.id, fn.tenant_id
        FROM data.file_nodes fn
        WHERE fn.node_type = 'file'
          AND fn.is_deleted = false
          AND fn.processing_status = 'done'
          AND COALESCE(fn.metadata ->> 'source', '') = 'ai-chat'
          AND fn.created_at < now() - make_interval(days => v_ttl_days)
          AND NOT EXISTS (
            SELECT 1
            FROM data.ai_message_file_refs ref
            INNER JOIN data.ai_conversations c ON c.id = ref.conversation_id
            WHERE ref.tenant_id = fn.tenant_id
              AND ref.file_id = fn.id
              AND c.status IN ('active', 'archived')
          )
        ORDER BY fn.created_at ASC
        LIMIT v_batch_limit
      LOOP
        v_batch_candidates := v_batch_candidates + 1;
        v_candidates := v_candidates + 1;

        BEGIN
          PERFORM data.hard_delete_node(v_candidate.id, v_candidate.tenant_id);
          v_deleted := v_deleted + 1;
        EXCEPTION
          WHEN OTHERS THEN
            v_errors := v_errors + 1;
            RAISE WARNING 'cleanup_orphan_ai_chat_attachments: failed % (%): %',
              v_candidate.id, v_candidate.tenant_id, SQLERRM;
        END;
      END LOOP;

      EXIT WHEN v_batch_candidates = 0 OR v_batch_candidates < v_batch_limit;
    END LOOP;

    PERFORM pg_advisory_unlock(v_lock_key);
  EXCEPTION
    WHEN OTHERS THEN
      PERFORM pg_advisory_unlock(v_lock_key);
      RAISE;
  END;

  RETURN jsonb_build_object(
    'ttl_days', v_ttl_days,
    'batch_limit', v_batch_limit,
    'iterations', v_iterations,
    'candidates', v_candidates,
    'deleted', v_deleted,
    'errors', v_errors,
    'locked_skip', false,
    'duration_ms', floor(extract(epoch FROM (clock_timestamp() - v_started_at)) * 1000)::bigint
  );
END;
$$;

REVOKE ALL ON FUNCTION data.cleanup_orphan_ai_chat_attachments(integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.cleanup_orphan_ai_chat_attachments(integer, integer) FROM authenticated;
REVOKE ALL ON FUNCTION data.cleanup_orphan_ai_chat_attachments(integer, integer) FROM anon;

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

  RETURN data.cleanup_orphan_ai_chat_attachments(p_ttl_days, p_batch_limit);
END;
$$;

REVOKE ALL ON FUNCTION api.run_ai_chat_orphan_cleanup_service(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.run_ai_chat_orphan_cleanup_service(integer, integer) TO service_role;

COMMENT ON FUNCTION data.cleanup_orphan_ai_chat_attachments IS
  'Cleanup TTL ai-chat: usa ai_message_file_refs, lock advisory per evitar solapaments, i retorna mètriques de batch.';

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

    -- Run hourly, offset from :00 to reduce contention with other jobs.
    PERFORM cron.schedule(
      'cleanup-orphan-ai-chat-attachments',
      '17 * * * *',
      'SELECT data.cleanup_orphan_ai_chat_attachments();'
    );
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';
