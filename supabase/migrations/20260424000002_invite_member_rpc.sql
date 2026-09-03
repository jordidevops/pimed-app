-- =============================================================================
-- invite-member: RPC segura per upsert de profile + tenant_members + audit
-- Evita accés directe a schema data via PostgREST (Invalid schema: data).
-- =============================================================================

CREATE OR REPLACE FUNCTION api.upsert_invited_member(
  p_tenant_id uuid,
  p_user_id uuid,
  p_site_id uuid,
  p_role text,
  p_invited_by uuid,
  p_email text,
  p_new_invite boolean
)
RETURNS TABLE (membership_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_membership_id uuid;
BEGIN
  -- Manté el perfil en sync per a joins i UI.
  INSERT INTO data.profiles (id, email)
  VALUES (p_user_id, p_email)
  ON CONFLICT (id) DO UPDATE
    SET email = EXCLUDED.email,
        updated_at = now();

  SELECT tm.id
  INTO v_membership_id
  FROM data.tenant_members tm
  WHERE tm.tenant_id = p_tenant_id
    AND tm.user_id = p_user_id
    AND (
      (p_site_id IS NULL AND tm.site_id IS NULL)
      OR tm.site_id = p_site_id
    )
  LIMIT 1;

  IF v_membership_id IS NOT NULL THEN
    UPDATE data.tenant_members
    SET role = p_role,
        is_active = true,
        invited_by = p_invited_by
    WHERE id = v_membership_id;
  ELSE
    INSERT INTO data.tenant_members (
      tenant_id,
      user_id,
      site_id,
      role,
      is_active,
      invited_by
    )
    VALUES (
      p_tenant_id,
      p_user_id,
      p_site_id,
      p_role,
      true,
      p_invited_by
    )
    RETURNING id INTO v_membership_id;
  END IF;

  -- Auditoria: fire-and-forget semàntic a nivell SQL.
  BEGIN
    INSERT INTO data.audit_logs (
      tenant_id,
      user_id,
      site_id,
      action,
      entity_type,
      entity_id,
      payload
    )
    VALUES (
      p_tenant_id,
      p_invited_by,
      p_site_id,
      'MEMBER_INVITE_EMAIL_SENT',
      'tenant_member',
      v_membership_id,
      jsonb_build_object(
        'invited_email', p_email,
        'invited_user_id', p_user_id,
        'role', p_role,
        'site_id', p_site_id,
        'new_invite', p_new_invite
      )
    );
  EXCEPTION WHEN OTHERS THEN
    -- No bloquejar el flux principal per error d'auditoria.
    NULL;
  END;

  RETURN QUERY SELECT v_membership_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.upsert_invited_member(uuid, uuid, uuid, text, uuid, text, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION api.upsert_invited_member(uuid, uuid, uuid, text, uuid, text, boolean) FROM anon;
REVOKE EXECUTE ON FUNCTION api.upsert_invited_member(uuid, uuid, uuid, text, uuid, text, boolean) FROM authenticated;
GRANT EXECUTE ON FUNCTION api.upsert_invited_member(uuid, uuid, uuid, text, uuid, text, boolean) TO service_role;
