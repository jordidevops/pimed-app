-- Fix: membres només amb rol de site (global_role NULL) no han de passar _assert_ai_manager_access.
-- Abans: (NULL IN ('owner','manager')) avaluava a NULL → IF NOT NULL no llançava excepció.

CREATE OR REPLACE FUNCTION api._assert_ai_manager_access(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND COALESCE(
      data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role',
      ''
    ) IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'Access denied: owner or manager role required';
  END IF;
END;
$$;
