-- =============================================================================
-- Migration 9: process-deletion-queue RPCs
-- =============================================================================
-- Two privileged RPCs called exclusively by the process-deletion-queue Edge
-- Function acting as service_role.  The function cannot query pgmq tables
-- directly because the pgmq schema is not in PostgREST's exposed schemas list.
--
-- Design: read-then-archive (at-least-once delivery)
-- ─────────────────────────────────────────────────
-- We intentionally use pgmq.read() with a visibility timeout (VT) instead
-- of pgmq.pop().  pop() atomically removes the message, so if the Edge
-- Function crashes mid-batch the deletion is never retried.  With read():
--   1. Message is locked (invisible) for VT seconds.
--   2. Edge Function deletes the physical file.
--   3. Edge Function calls archive_deletion_message → pgmq.archive().
--   4. If step 3 is never reached (crash), the message re-appears after VT
--      and will be retried on the next invocation.
--   5. DeleteObject / Storage.remove() are idempotent, so retries are safe.
--
-- Queue name:    trash_deletion_queue  (created in migration 6)
-- Message schema: { file_node_id, tenant_id, storage_provider_id, storage_key }
-- =============================================================================


-- ---------------------------------------------------------------------------
-- api.pop_deletion_messages
--
-- Reads up to p_batch_size messages from the trash deletion queue.
-- Each message is locked for 5 minutes (VT = 300 s); if not archived within
-- that window it becomes visible again and will be retried.
--
-- Null storage_provider_id → Supabase Storage (default bucket)
-- Non-null storage_provider_id → BYOS (S3 / R2 / GCS)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.pop_deletion_messages(
  p_batch_size integer DEFAULT 10
)
RETURNS TABLE (
  msg_id              bigint,
  file_node_id        uuid,
  tenant_id           uuid,
  storage_provider_id uuid,
  storage_key         text
)
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT
    m.msg_id,
    (m.message ->> 'file_node_id')::uuid         AS file_node_id,
    (m.message ->> 'tenant_id')::uuid             AS tenant_id,
    (m.message ->> 'storage_provider_id')::uuid   AS storage_provider_id,
    m.message ->> 'storage_key'                   AS storage_key
  FROM pgmq.read(
    'trash_deletion_queue',
    300,                                     -- visibility timeout: 5 minutes
    LEAST(GREATEST(p_batch_size, 1), 50)     -- clamped to [1, 50]
  ) AS m;
$$;

REVOKE ALL ON FUNCTION api.pop_deletion_messages(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.pop_deletion_messages(integer) FROM authenticated;
REVOKE ALL ON FUNCTION api.pop_deletion_messages(integer) FROM anon;
GRANT  EXECUTE ON FUNCTION api.pop_deletion_messages(integer) TO service_role;


-- ---------------------------------------------------------------------------
-- api.archive_deletion_message
--
-- Acknowledges a processed message by moving it to the pgmq archive table
-- (pgmq.trash_deletion_queue_archive).  The archive table keeps a permanent
-- audit trail of all files that were physically deleted.
--
-- Returns true if archived, false if the message was not found (already
-- archived by a concurrent invocation — safe to ignore).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.archive_deletion_message(p_msg_id bigint)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT pgmq.archive('trash_deletion_queue', p_msg_id);
$$;

REVOKE ALL ON FUNCTION api.archive_deletion_message(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.archive_deletion_message(bigint) FROM authenticated;
REVOKE ALL ON FUNCTION api.archive_deletion_message(bigint) FROM anon;
GRANT  EXECUTE ON FUNCTION api.archive_deletion_message(bigint) TO service_role;
