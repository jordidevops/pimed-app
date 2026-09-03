-- =============================================================================
-- Migració: 20260520000002_fix_patch_theme_security_definer
-- Descripció: Canvia api.patch_public_site_theme a SECURITY DEFINER per
--   permetre cridar data.log_audit_event() (que no té GRANT a 'authenticated').
--   Afegeix autorització manual equivalent a la policy RLS d'UPDATE.
-- Motiu del canvi:
--   La versió anterior usava SECURITY INVOKER, però cridava data.log_audit_event()
--   que només té EXECUTE per a 'postgres'. Totes les funcions que criden
--   log_audit_event han d'usar SECURITY DEFINER i fer la validació manualment.
-- Patró de seguretat:
--   · SECURITY DEFINER + SET search_path = data, public (evita search_path injection)
--   · Validació manual: jwt_user_tenants() -> tenant_id ->> 'global_role' IN ('owner','manager')
--   · Equivalent a la policy RLS "public_sites: owner/manager pot modificar"
-- =============================================================================

CREATE OR REPLACE FUNCTION api.patch_public_site_theme(
  p_id      uuid,
  p_section text,   -- 'header' | 'footer' | 'colors' | 'branding'
  p_patch   jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id       uuid := data.active_tenant_id();
  v_user_role       text;
  v_current_section jsonb;
  v_merged_section  jsonb;
  v_action          text;
  v_changed_keys    jsonb;
BEGIN
  -- Validació de context de tenant
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'missing_tenant_context'
      USING HINT = 'Envia la capçalera x-tenant-id amb el UUID del tenant.';
  END IF;

  -- Autorització manual (SECURITY DEFINER bypassa RLS):
  -- equivalent a la policy UPDATE "public_sites: owner/manager pot modificar"
  v_user_role := data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role';
  IF v_user_role IS NULL OR v_user_role NOT IN ('owner', 'manager') THEN
    RAISE insufficient_privilege
      USING HINT = 'Necessites rol owner o manager per modificar el tema del portal.';
  END IF;

  -- Validació de secció permesa
  IF p_section NOT IN ('header', 'footer', 'colors', 'branding') THEN
    RAISE EXCEPTION 'invalid_section: Secció "%" no permesa. Usa: header, footer, colors, branding.',
      p_section
      USING ERRCODE = 'P0001';
  END IF;

  -- Llegir secció actual
  SELECT COALESCE(theme_config->p_section, '{}'::jsonb)
    INTO v_current_section
    FROM data.public_sites
   WHERE id = p_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found'
      USING HINT = 'El public_site no existeix o no pertany al tenant actiu.';
  END IF;

  -- Merge superficial: claus de p_patch sobreescriuen les existents, la resta es conserva
  v_merged_section := v_current_section || p_patch;

  -- Claus canviades per al log d'auditoria (sense valors, per privacitat)
  SELECT jsonb_agg(k)
    INTO v_changed_keys
    FROM jsonb_object_keys(p_patch) k;

  -- Aplicar patch: actualitza NOMÉS la secció, no el jsonb complet
  UPDATE data.public_sites
     SET theme_config = jsonb_set(
           COALESCE(theme_config, '{}'),
           ARRAY[p_section],
           v_merged_section
         ),
         updated_at   = now()
   WHERE id        = p_id
     AND tenant_id = v_tenant_id;

  -- Auditoria: distingueix logo (canvi de branding.logo_url) de tema genèric
  v_action := CASE
    WHEN p_section = 'branding' AND (p_patch ? 'logo_url') THEN 'PUBLIC_SITE_LOGO_UPDATED'
    ELSE 'PUBLIC_SITE_THEME_UPDATED'
  END;

  PERFORM data.log_audit_event(
    v_tenant_id,
    auth.uid(),
    NULL,
    v_action,
    'public_site',
    p_id,
    jsonb_build_object(
      'section',      p_section,
      'changed_keys', v_changed_keys
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.patch_public_site_theme(uuid, text, jsonb) TO authenticated;
