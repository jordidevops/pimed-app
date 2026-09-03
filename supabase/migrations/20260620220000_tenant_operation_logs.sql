-- =============================================================================
-- Migration: 20260620220000_tenant_operation_logs.sql
-- Purpose : Centre d'errors operatius per tenant (independent d'audit_logs)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Enums
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type
    WHERE typname = 'operation_log_status' AND typnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'data')
  ) THEN
    CREATE TYPE data.operation_log_status AS ENUM (
      'pending', 'running', 'success', 'failed', 'dead_letter', 'cancelled', 'degraded'
    );
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type
    WHERE typname = 'operation_integration_type' AND typnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'data')
  ) THEN
    CREATE TYPE data.operation_integration_type AS ENUM (
      'email', 'sms', 'push', 'webhook_inbound', 'webhook_outbound',
      'erp_sync', 'signing', 'pdf_generation', 'ai_generation', 'ai_chat',
      'import', 'export', 'storage', 'geocoding', 'billing', 'other'
    );
  END IF;
END$$;

-- ---------------------------------------------------------------------------
-- 2. Taula
-- ---------------------------------------------------------------------------

CREATE TABLE data.tenant_operation_logs (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id               uuid REFERENCES data.sites(id) ON DELETE SET NULL,

  integration_type      data.operation_integration_type NOT NULL,
  operation_code        text NOT NULL,
  status                data.operation_log_status NOT NULL DEFAULT 'pending',

  title                 text NOT NULL,
  message               text,
  error_code            text,
  error_message         text,

  entity_type           text,
  entity_id             uuid,
  correlation_id        text,
  source_job_table      text,
  source_job_id         uuid,

  payload_summary       jsonb NOT NULL DEFAULT '{}'::jsonb,

  duration_ms           integer,
  duration_threshold_ms integer,
  external_service      text,

  attempt_count         smallint NOT NULL DEFAULT 0,
  max_attempts          smallint,
  is_retryable          boolean NOT NULL DEFAULT false,

  actor_user_id         uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  resolved_at           timestamptz,
  resolved_by             uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  resolution_note       text,
  tenant_notified_at    timestamptz,

  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  completed_at            timestamptz,

  CONSTRAINT tenant_operation_logs_idempotency
    UNIQUE (tenant_id, correlation_id, operation_code)
);

CREATE TRIGGER trg_tenant_operation_logs_updated_at
  BEFORE UPDATE ON data.tenant_operation_logs
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

CREATE INDEX idx_op_logs_tenant_created
  ON data.tenant_operation_logs (tenant_id, created_at DESC);

CREATE INDEX idx_op_logs_tenant_status
  ON data.tenant_operation_logs (tenant_id, status)
  WHERE status IN ('failed', 'dead_letter', 'degraded');

CREATE INDEX idx_op_logs_tenant_unresolved
  ON data.tenant_operation_logs (tenant_id, created_at DESC)
  WHERE resolved_at IS NULL AND status IN ('failed', 'dead_letter');

CREATE INDEX idx_op_logs_integration_duration
  ON data.tenant_operation_logs (integration_type, created_at DESC)
  WHERE duration_ms IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 3. RLS
-- ---------------------------------------------------------------------------

ALTER TABLE data.tenant_operation_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "service_role full access on tenant_operation_logs"
  ON data.tenant_operation_logs FOR ALL TO service_role
  USING (true) WITH CHECK (true);

CREATE POLICY "tenant managers read operation_logs"
  ON data.tenant_operation_logs FOR SELECT TO authenticated
  USING (
    (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

GRANT SELECT ON data.tenant_operation_logs TO authenticated;
GRANT ALL ON data.tenant_operation_logs TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Vista api
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW api.tenant_operation_logs
WITH (security_invoker = true)
AS
SELECT
  id, tenant_id, site_id,
  integration_type, operation_code, status,
  title, message, error_code, error_message,
  entity_type, entity_id, correlation_id,
  source_job_table, source_job_id,
  payload_summary,
  duration_ms, duration_threshold_ms, external_service,
  attempt_count, max_attempts, is_retryable,
  actor_user_id, resolved_at, resolved_by, resolution_note,
  created_at, updated_at, completed_at
FROM data.tenant_operation_logs;

GRANT SELECT ON api.tenant_operation_logs TO authenticated;
GRANT SELECT, INSERT, UPDATE ON api.tenant_operation_logs TO service_role;

-- ---------------------------------------------------------------------------
-- 5. RPC: log_tenant_operation (service_role)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.log_tenant_operation(
  p_tenant_id             uuid,
  p_integration_type      data.operation_integration_type,
  p_operation_code        text,
  p_status                data.operation_log_status,
  p_title                 text,
  p_message               text DEFAULT NULL,
  p_error_code            text DEFAULT NULL,
  p_error_message         text DEFAULT NULL,
  p_entity_type           text DEFAULT NULL,
  p_entity_id             uuid DEFAULT NULL,
  p_correlation_id        text DEFAULT NULL,
  p_source_job_table      text DEFAULT NULL,
  p_source_job_id         uuid DEFAULT NULL,
  p_payload_summary       jsonb DEFAULT '{}'::jsonb,
  p_duration_ms           integer DEFAULT NULL,
  p_duration_threshold_ms integer DEFAULT NULL,
  p_external_service      text DEFAULT NULL,
  p_attempt_count         smallint DEFAULT 0,
  p_max_attempts          smallint DEFAULT NULL,
  p_is_retryable          boolean DEFAULT false,
  p_actor_user_id         uuid DEFAULT NULL,
  p_site_id               uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_id uuid;
  v_completed_at timestamptz;
BEGIN
  IF p_tenant_id IS NULL OR nullif(trim(p_operation_code), '') IS NULL OR nullif(trim(p_title), '') IS NULL THEN
    RAISE EXCEPTION 'tenant_id, operation_code and title are required';
  END IF;

  IF p_status IN ('success', 'failed', 'dead_letter', 'cancelled', 'degraded') THEN
    v_completed_at := now();
  END IF;

  INSERT INTO data.tenant_operation_logs (
    tenant_id, site_id,
    integration_type, operation_code, status,
    title, message, error_code, error_message,
    entity_type, entity_id, correlation_id,
    source_job_table, source_job_id,
    payload_summary,
    duration_ms, duration_threshold_ms, external_service,
    attempt_count, max_attempts, is_retryable,
    actor_user_id, completed_at
  ) VALUES (
    p_tenant_id, p_site_id,
    p_integration_type, trim(p_operation_code), p_status,
    trim(p_title), p_message, p_error_code, left(p_error_message, 500),
    p_entity_type, p_entity_id, nullif(trim(p_correlation_id), ''),
    p_source_job_table, p_source_job_id,
    COALESCE(p_payload_summary, '{}'::jsonb),
    p_duration_ms, p_duration_threshold_ms, p_external_service,
    COALESCE(p_attempt_count, 0), p_max_attempts, COALESCE(p_is_retryable, false),
    p_actor_user_id, v_completed_at
  )
  ON CONFLICT (tenant_id, correlation_id, operation_code)
  DO UPDATE SET
    status                = EXCLUDED.status,
    title                 = EXCLUDED.title,
    message               = EXCLUDED.message,
    error_code            = EXCLUDED.error_code,
    error_message         = EXCLUDED.error_message,
    payload_summary       = EXCLUDED.payload_summary,
    duration_ms           = EXCLUDED.duration_ms,
    duration_threshold_ms = EXCLUDED.duration_threshold_ms,
    external_service      = EXCLUDED.external_service,
    attempt_count         = EXCLUDED.attempt_count,
    max_attempts          = EXCLUDED.max_attempts,
    is_retryable          = EXCLUDED.is_retryable,
    completed_at          = EXCLUDED.completed_at,
    updated_at            = now()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.log_tenant_operation(
  uuid, data.operation_integration_type, text, data.operation_log_status, text,
  text, text, text, text, uuid, text, text, uuid, jsonb,
  integer, integer, text, smallint, smallint, boolean, uuid, uuid
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.log_tenant_operation(
  uuid, data.operation_integration_type, text, data.operation_log_status, text,
  text, text, text, text, uuid, text, text, uuid, jsonb,
  integer, integer, text, smallint, smallint, boolean, uuid, uuid
) TO service_role;

-- ---------------------------------------------------------------------------
-- 6. RPC: get_unresolved_operation_count (manager+)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.get_unresolved_operation_count(
  p_tenant_id uuid,
  p_since     timestamptz DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  PERFORM api._assert_ai_manager_access(p_tenant_id);

  RETURN (
    SELECT count(*)::bigint
    FROM data.tenant_operation_logs l
    WHERE l.tenant_id = p_tenant_id
      AND l.resolved_at IS NULL
      AND l.status IN ('failed', 'dead_letter')
      AND (p_since IS NULL OR l.created_at >= p_since)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_unresolved_operation_count(uuid, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_unresolved_operation_count(uuid, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_unresolved_operation_count(uuid, timestamptz) TO service_role;

-- ---------------------------------------------------------------------------
-- 7. RPC: get_tenant_operation_logs (manager+)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.get_tenant_operation_logs(
  p_tenant_id        uuid,
  p_status           data.operation_log_status DEFAULT NULL,
  p_integration_type data.operation_integration_type DEFAULT NULL,
  p_limit            integer DEFAULT 50,
  p_offset           integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_items jsonb;
  v_total bigint;
BEGIN
  PERFORM api._assert_ai_manager_access(p_tenant_id);

  p_limit := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
  p_offset := GREATEST(COALESCE(p_offset, 0), 0);

  SELECT count(*) INTO v_total
  FROM data.tenant_operation_logs l
  WHERE l.tenant_id = p_tenant_id
    AND (p_status IS NULL OR l.status = p_status)
    AND (p_integration_type IS NULL OR l.integration_type = p_integration_type);

  SELECT COALESCE(jsonb_agg(row_to_json(x)::jsonb ORDER BY x.created_at DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT
      l.id, l.integration_type, l.operation_code, l.status,
      l.title, l.message, l.error_code, l.error_message,
      l.duration_ms, l.duration_threshold_ms, l.external_service,
      l.is_retryable, l.resolved_at, l.created_at, l.completed_at,
      l.payload_summary, l.correlation_id
    FROM data.tenant_operation_logs l
    WHERE l.tenant_id = p_tenant_id
      AND (p_status IS NULL OR l.status = p_status)
      AND (p_integration_type IS NULL OR l.integration_type = p_integration_type)
    ORDER BY l.created_at DESC
    LIMIT p_limit OFFSET p_offset
  ) x;

  RETURN jsonb_build_object('items', v_items, 'total', v_total, 'limit', p_limit, 'offset', p_offset);
END;
$$;

REVOKE ALL ON FUNCTION api.get_tenant_operation_logs(uuid, data.operation_log_status, data.operation_integration_type, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_tenant_operation_logs(uuid, data.operation_log_status, data.operation_integration_type, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_tenant_operation_logs(uuid, data.operation_log_status, data.operation_integration_type, integer, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 8. RPC: mark_operation_log_resolved (manager+)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.mark_operation_log_resolved(
  p_tenant_id uuid,
  p_log_id    uuid,
  p_note      text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  PERFORM api._assert_ai_manager_access(p_tenant_id);

  UPDATE data.tenant_operation_logs
  SET resolved_at = now(),
      resolved_by = auth.uid(),
      resolution_note = nullif(trim(p_note), ''),
      updated_at = now()
  WHERE id = p_log_id
    AND tenant_id = p_tenant_id
    AND resolved_at IS NULL;

  RETURN FOUND;
END;
$$;

REVOKE ALL ON FUNCTION api.mark_operation_log_resolved(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.mark_operation_log_resolved(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION api.mark_operation_log_resolved(uuid, uuid, text) TO service_role;
