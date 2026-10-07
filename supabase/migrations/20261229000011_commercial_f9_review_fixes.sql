-- CF-28 F9 review fixes:
-- 1) Remove dangerous api.apply wrapper (authenticated → any request_id)
-- 2) Instrument already_decided on all data.apply paths via rename+wrap
-- 3) Office apply relies on wrapper (no double-count)

-- ---------------------------------------------------------------------------
-- Drop insecure API shim introduced in 00010
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.apply_commercial_decision_request(uuid, text, text, jsonb, uuid, uuid);

-- ---------------------------------------------------------------------------
-- Rename core apply → wrap with metric instrumentation
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'data'
      AND p.proname = 'apply_commercial_decision_request_core'
  ) THEN
    -- already wrapped in a prior apply of this migration
    NULL;
  ELSIF EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'data'
      AND p.proname = 'apply_commercial_decision_request'
  ) THEN
    ALTER FUNCTION data.apply_commercial_decision_request(uuid, text, text, jsonb, uuid, uuid)
      RENAME TO apply_commercial_decision_request_core;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION data.apply_commercial_decision_request(
  p_request_id uuid,
  p_outcome text,
  p_via text,
  p_evidence jsonb,
  p_client_op_id uuid,
  p_actor_id uuid
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
  v_result := data.apply_commercial_decision_request_core(
    p_request_id, p_outcome, p_via, p_evidence, p_client_op_id, p_actor_id
  );

  IF COALESCE((v_result->>'already_decided')::boolean, false) THEN
    SELECT tenant_id INTO v_tenant
    FROM data.commercial_decision_requests
    WHERE id = p_request_id;
    BEGIN
      PERFORM api.record_commercial_ops_metric(
        'already_decided',
        v_tenant,
        p_request_id,
        jsonb_build_object(
          'via', p_via,
          'outcome', p_outcome,
          'status', v_result->>'status'
        )
      );
    EXCEPTION WHEN OTHERS THEN
      NULL; -- never fail apply because of metrics
    END;
  END IF;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION data.apply_commercial_decision_request_core(uuid, text, text, jsonb, uuid, uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.apply_commercial_decision_request_core(uuid, text, text, jsonb, uuid, uuid)
  TO service_role;

REVOKE ALL ON FUNCTION data.apply_commercial_decision_request(uuid, text, text, jsonb, uuid, uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.apply_commercial_decision_request(uuid, text, text, jsonb, uuid, uuid)
  TO service_role;

-- Office: drop duplicate metric (wrapper on data.apply already records)
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
  RETURN data.apply_commercial_decision_request(
    p_request_id, p_outcome, 'office', v_evidence, p_client_op_id, v_uid
  );
END;
$$;

REVOKE ALL ON FUNCTION api.apply_commercial_decision_office(uuid, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.apply_commercial_decision_office(uuid, text, text, uuid)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
