-- =============================================================================
-- Role Permissions RPCs — Gestió RBAC des del tenant-portal
--
-- Objectius:
--   1. api.get_tenant_role_permissions(p_tenant_id uuid DEFAULT NULL)
--      Lectura de l'estat actual del gestor de permisos per rol:
--        · current_customization: personalitzacions guardades al tenant
--        · defaults: permisos base sense personalització (espell de permissions.ts)
--        · effective: permisos acumulats calculats per rol (usar per display)
--        · updated_at / updated_by: per detectar JWT obsolet al frontend
--
--   2. api.update_tenant_role_permissions(p_permissions jsonb, p_tenant_id uuid DEFAULT NULL)
--      Escriptura owner-only sobre data.tenants.metadata->'role_permissions'.
--      Inclou validació de claus, auditoria i actualització de timestamps.
--
-- SEPARACIÓ DE DOMINIS (CRÍTIC):
--   · Escriu/llegeix ÚNICAMENT data.tenants.metadata->'role_permissions'
--   · No toca mai data.tenants.settings (motor de configuració operativa)
--   · El motor de settings queda 100% intacte
--
-- PARÀMETRE p_tenant_id (DEFAULT NULL):
--   · Permet al frontend passar el tenant_id directament i evitar la cursa de
--     timing entre el muntatge de la query (React Query) i la injecció del header
--     x-tenant-id (TenantContext.useEffect). Backward compat: si no es passa,
--     usa data.active_tenant_id() (header x-tenant-id).
--   · SEGURETAT: p_tenant_id no bypassa els checks d'accés — el JWT de l'usuari
--     autenticat ha de contenir el tenant_id per a que la crida sigui autoritzada.
--
-- PROPAGACIÓ JWT:
--   · Cada canvi actualitza metadata->'permissions_updated_at' i 'permissions_updated_by'
--   · El frontend compara aquest timestamp amb session.user.iat per detectar tokens obsolets
--   · La UI ha d'informar que els canvis són efectius al proper refresh de sessió (~60min)
--     o quan l'usuari fa log out/in
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. api.get_tenant_role_permissions
--    Accessible per qualsevol membre actiu del tenant (lectura no és sensible).
--    Retorna JSONB amb l'estructura completa per renderitzar l'editor de permisos.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_tenant_role_permissions(
  p_tenant_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id       uuid;
  v_custom_perms    jsonb;
  v_updated_at      timestamptz;
  v_updated_by      uuid;

  -- Permisos BASE per defecte (ha de coincidir amb BASE_ROLE_PERMISSIONS de permissions.ts)
  v_viewer_default  text[] := ARRAY[
    'storage.view', 'calendar.view', 'email.view', 'invoices.view',
    'members.view', 'sites.view', 'settings.view'
  ];
  v_member_default  text[] := ARRAY[
    'storage.upload', 'calendar.edit', 'email.send', 'invoices.edit'
  ];
  v_manager_default text[] := ARRAY[
    'storage.delete', 'calendar.manage', 'email.manage', 'invoices.manage',
    'members.invite', 'sites.create', 'settings.manage', 'permissions.manage'
  ];
BEGIN
  v_tenant_id := COALESCE(p_tenant_id, data.active_tenant_id());

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'No active tenant: pass p_tenant_id or set x-tenant-id header';
  END IF;

  -- Verifica que l'usuari autenticat pertany al tenant (p_tenant_id no bypassa ACL)
  IF NOT (data.jwt_user_tenants() ? v_tenant_id::text) THEN
    RAISE EXCEPTION 'Access denied for tenant %', v_tenant_id;
  END IF;

  SELECT
    t.metadata -> 'role_permissions',
    (t.metadata ->> 'permissions_updated_at')::timestamptz,
    (t.metadata ->> 'permissions_updated_by')::uuid
  INTO v_custom_perms, v_updated_at, v_updated_by
  FROM data.tenants t
  WHERE t.id = v_tenant_id;

  RETURN jsonb_build_object(
    -- Personalitzacions actuals guardades (buit si s'usen els defaults)
    'current_customization', COALESCE(v_custom_perms, '{}'::jsonb),

    -- Permisos base per defecte (espell de permissions.ts BASE_ROLE_PERMISSIONS)
    'defaults', jsonb_build_object(
      'viewer',  to_jsonb(v_viewer_default),
      'member',  to_jsonb(v_member_default),
      'manager', to_jsonb(v_manager_default)
    ),

    -- Permisos efectius calculats per rol (herència acumulativa + personalitzacions)
    -- Usar aquests per display; data.get_role_permissions ja aplica herència + custom
    'effective', jsonb_build_object(
      'owner',   to_jsonb(ARRAY['*']),
      'manager', to_jsonb(data.get_role_permissions('manager', v_custom_perms)),
      'member',  to_jsonb(data.get_role_permissions('member',  v_custom_perms)),
      'viewer',  to_jsonb(data.get_role_permissions('viewer',  v_custom_perms))
    ),

    -- Metadades de propagació JWT
    'updated_at', to_jsonb(v_updated_at),
    'updated_by', to_jsonb(v_updated_by)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_tenant_role_permissions(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_tenant_role_permissions(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. api.update_tenant_role_permissions
--    Escriptura OWNER-ONLY sobre metadata->'role_permissions'.
--
--    p_permissions: { "viewer": [...], "member": [...], "manager": [...] }
--    · Passa {} per eliminar totes les personalitzacions (torna a defaults).
--    · Claus de permís invàlides → EXCEPTION.
--    · Clau de rol 'owner' → EXCEPTION (l'owner no és personalitzable).
-- ---------------------------------------------------------------------------
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
    'storage.view',    'storage.upload',    'storage.delete',    'storage.manage',
    'calendar.view',   'calendar.edit',     'calendar.manage',
    'email.view',      'email.send',        'email.manage',
    'invoices.view',   'invoices.edit',     'invoices.manage',
    'members.view',    'members.invite',    'members.manage',
    'sites.view',      'sites.create',      'sites.manage',
    'settings.view',   'settings.manage',
    'permissions.manage'
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
