-- Expose resolved punch profile for employee portal session + UI (Track G1b)

CREATE OR REPLACE FUNCTION api.employee_portal_get_punch_profile(
  p_employee_id uuid,
  p_tenant_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_resolved jsonb;
  v_profile  text;
  v_policy   jsonb;
  v_legacy   boolean;
  v_today    date := (now() AT TIME ZONE 'Europe/Madrid')::date;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM data.employees e
    WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id
  ) THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT data.resolve_attendance_record_policy(p_employee_id, v_today)
  INTO v_resolved;

  v_profile := COALESCE(v_resolved->>'work_profile', 'fixed_site');
  v_policy  := COALESCE(v_resolved->'policy', '{}'::jsonb);

  v_legacy :=
    v_profile = 'fixed_site'
    OR COALESCE((v_policy->>'legacy_in_out_only')::boolean, false);

  RETURN jsonb_build_object(
    'work_profile', v_profile,
    'legacy_in_out_only', v_legacy
  );
END;
$$;

REVOKE ALL ON FUNCTION api.employee_portal_get_punch_profile(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_get_punch_profile(uuid, uuid) TO service_role;
