-- =============================================================================
-- Align api.update_tenant_role_permissions allowlist with ALL_PERMISSION_KEYS
--
-- Owner can grant commercial.pricing.edit (and other keys already in the TS
-- matrix) to the member role from Settings → Role permissions. Saving failed
-- because v_valid_keys still listed only the original 20260511 core keys.
--
-- Must match apps/tenant-portal/src/lib/permissions.ts ALL_PERMISSION_KEYS.
-- Does not change data.get_role_permissions member defaults.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.update_tenant_role_permissions(
  p_permissions jsonb,
  p_tenant_id   uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id   uuid;
  v_global_role text;
  v_role_key    text;
  v_perm_key    text;
  v_old_perms   jsonb;

  -- Ha de coincidir exactament amb ALL_PERMISSION_KEYS de permissions.ts
  v_valid_keys  text[] := ARRAY[
    'storage.view', 'storage.upload', 'storage.delete', 'storage.manage',
    'calendar.view', 'calendar.edit', 'calendar.manage',
    'email.view', 'email.send', 'email.manage',
    'invoices.view', 'invoices.edit', 'invoices.manage',
    'members.view', 'members.invite', 'members.manage',
    'sites.view', 'sites.create', 'sites.manage',
    'settings.view', 'settings.manage',
    'permissions.manage',
    'ai.use', 'ai.configure', 'ai.tools.write',
    'employees.directory.view', 'employees.view', 'employees.manage',
    'employees.private.view', 'employees.private.manage', 'employees.private.reveal', 'employees.skills.manage',
    'employees.lifecycle.view', 'employees.lifecycle.manage',
    'employees.contracts.view', 'employees.contracts.manage', 'employees.contracts.approve',
    'employees.compensation.view', 'employees.compensation.edit',
    'compliance.requirements.manage',
    'compliance.certifications.view', 'compliance.certifications.manage',
    'compliance.medical_clearance.view', 'compliance.medical_clearance.manage',
    'assets.view', 'assets.manage',
    'assets.employee_assignments.view', 'assets.employee_assignments.manage',
    'recruitment.view', 'recruitment.manage', 'recruitment.interview', 'recruitment.rights',
    'field_service.reports.publish', 'field_service.reports.regenerate',
    'field_service.reports.share', 'field_service.reports.revoke',
    'field_service.reports.preview_as_customer',
    'contacts.portal.manage',
    'commercial.pricing.edit',
    'attendance.punch_own', 'attendance.approve', 'absences.request'
  ];
  v_valid_roles text[] := ARRAY['viewer', 'member', 'manager'];
BEGIN
  v_tenant_id := COALESCE(p_tenant_id, data.active_tenant_id());

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'No active tenant: pass p_tenant_id or set x-tenant-id header';
  END IF;

  IF jsonb_typeof(p_permissions) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'p_permissions must be a JSON object';
  END IF;

  -- Comprovar que l'usuari és owner global del tenant
  -- (el rol s'extreu del JWT per al v_tenant_id concret — p_tenant_id no bypassa ACL)
  v_global_role := data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role';
  IF COALESCE(v_global_role, '') <> 'owner' THEN
    RAISE EXCEPTION 'Only tenant owners can modify role permissions';
  END IF;

  -- Validar claus de rol (no s'accepta 'owner' ni claus desconegudes)
  FOR v_role_key IN SELECT jsonb_object_keys(p_permissions)
  LOOP
    IF NOT (v_role_key = ANY(v_valid_roles)) THEN
      RAISE EXCEPTION 'Invalid role key: %. Valid roles are: viewer, member, manager', v_role_key;
    END IF;

    IF jsonb_typeof(p_permissions -> v_role_key) <> 'array' THEN
      RAISE EXCEPTION 'Permissions for role % must be an array', v_role_key;
    END IF;

    -- Validar cada clau de permís dins del rol
    FOR v_perm_key IN
      SELECT jsonb_array_elements_text(p_permissions -> v_role_key)
    LOOP
      IF NOT (v_perm_key = ANY(v_valid_keys)) THEN
        RAISE EXCEPTION 'Invalid permission key: ''%''. Check permissions.ts ALL_PERMISSION_KEYS', v_perm_key;
      END IF;
    END LOOP;
  END LOOP;

  -- Llegir valor antic per a l'auditoria (dins de la mateixa transacció)
  SELECT metadata -> 'role_permissions'
  INTO v_old_perms
  FROM data.tenants
  WHERE id = v_tenant_id;

  -- Actualitzar metadata: fusió shallow per preservar la resta de claus de metadata
  UPDATE data.tenants
  SET metadata = COALESCE(metadata, '{}') || jsonb_build_object(
    'role_permissions',       p_permissions,
    'permissions_updated_at', now(),
    'permissions_updated_by', auth.uid()
  )
  WHERE id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tenant % not found', v_tenant_id;
  END IF;

  -- Auditoria obligatòria (fire-and-forget via PERFORM — errors no trenquen la tx)
  PERFORM data.log_audit_event(
    v_tenant_id,
    auth.uid(),
    NULL,                        -- site_id = NULL (operació de tenant, no de site)
    'ROLE_PERMISSIONS_UPDATED',
    'tenant',
    v_tenant_id,
    jsonb_build_object(
      'old', COALESCE(v_old_perms, '{}'::jsonb),
      'new', p_permissions
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION api.update_tenant_role_permissions(jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_tenant_role_permissions(jsonb, uuid) TO authenticated;
