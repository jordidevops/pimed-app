-- =============================================================================
-- 20260529000002_signing_mark_reviewed_hardening.sql
--
-- Hardening post-V2 mark-reviewed:
-- 1) Enforce terminal status at backend RPC level.
-- 2) Make update idempotent and concurrency-safe (single audit event).
-- 3) Close EXECUTE surface by revoking PUBLIC on RPC.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.mark_signing_submission_reviewed(
  p_submission_id uuid
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_sub data.signing_submissions%ROWTYPE;
  v_uid uuid := auth.uid();
BEGIN
  SELECT * INTO v_sub
  FROM data.signing_submissions
  WHERE id = p_submission_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Submission % not found', p_submission_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT (data.jwt_user_tenants() ? v_sub.tenant_id::text) THEN
    RAISE EXCEPTION 'Access denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF (data.jwt_user_tenants() -> v_sub.tenant_id::text ->> 'global_role') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'Access denied: owner or manager role required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Idempotent path
  IF v_sub.reviewed_at IS NOT NULL THEN
    RETURN row_to_json(v_sub);
  END IF;

  -- Backend guard: only terminal submissions can be reviewed.
  IF v_sub.status NOT IN ('completed', 'declined', 'expired', 'cancelled', 'error') THEN
    RAISE EXCEPTION 'Submission % is not in a terminal status (%).', p_submission_id, v_sub.status
      USING ERRCODE = 'check_violation';
  END IF;

  -- Concurrency-safe: only the first writer updates and emits audit.
  UPDATE data.signing_submissions
  SET reviewed_at = now(),
      reviewed_by = v_uid,
      updated_at  = now()
  WHERE id = p_submission_id
    AND reviewed_at IS NULL
  RETURNING * INTO v_sub;

  IF FOUND THEN
    PERFORM data.log_audit_event(
      v_sub.tenant_id, v_uid, NULL,
      'SIGNING_SUBMISSION_REVIEWED', 'signing_submission', v_sub.id,
      jsonb_build_object(
        'reviewed_at', v_sub.reviewed_at,
        'status',      v_sub.status
      )
    );
    RETURN row_to_json(v_sub);
  END IF;

  -- Concurrent call already reviewed it.
  SELECT * INTO v_sub
  FROM data.signing_submissions
  WHERE id = p_submission_id;

  RETURN row_to_json(v_sub);
END;
$$;

REVOKE EXECUTE ON FUNCTION api.mark_signing_submission_reviewed(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.mark_signing_submission_reviewed(uuid) TO authenticated;
