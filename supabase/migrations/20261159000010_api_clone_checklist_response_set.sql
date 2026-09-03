-- Expose response-set clone to PostgREST (tenant portal RPC).
CREATE OR REPLACE FUNCTION api.clone_checklist_response_set(
  p_source_set_id uuid,
  p_tenant_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN data.clone_checklist_response_set(p_source_set_id, p_tenant_id);
END;
$$;

GRANT EXECUTE ON FUNCTION api.clone_checklist_response_set(uuid, uuid)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
