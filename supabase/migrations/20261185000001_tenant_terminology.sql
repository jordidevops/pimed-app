-- Tenant vocabulary overlay on sector_profiles.labels.
-- Allowlist: project, project_plural, contact, contacts, price_sheet.
-- Additive plural seed; wipe terminology only when sector_profile_id changes.

INSERT INTO data.settings_registry
  (setting_key, scope, required_permission, owner_only, is_active, description)
VALUES
  ('terminology', 'tenant', 'settings.manage', false, true,
   'Overlay de vocabulari del tenant sobre les etiquetes de sector')
ON CONFLICT (setting_key) DO UPDATE SET
  scope = EXCLUDED.scope,
  required_permission = EXCLUDED.required_permission,
  owner_only = EXCLUDED.owner_only,
  is_active = EXCLUDED.is_active,
  description = EXCLUDED.description,
  updated_at = now();

UPDATE data.sector_profiles
SET labels = labels
  || CASE WHEN COALESCE(labels->>'project_plural', '') = ''
     THEN '{"project_plural":"Ordres de servei"}'::jsonb ELSE '{}'::jsonb END
  || CASE WHEN COALESCE(labels->>'contacts', '') = ''
     THEN '{"contacts":"Clients"}'::jsonb ELSE '{}'::jsonb END
WHERE archetype = 'field_service';

UPDATE data.sector_profiles
SET labels = labels
  || CASE WHEN COALESCE(labels->>'project_plural', '') = ''
     THEN '{"project_plural":"Expedients"}'::jsonb ELSE '{}'::jsonb END
  || CASE WHEN COALESCE(labels->>'contacts', '') = ''
     THEN '{"contacts":"Clients"}'::jsonb ELSE '{}'::jsonb END
WHERE archetype = 'practice';

UPDATE data.sector_profiles
SET labels = labels
  || CASE WHEN COALESCE(labels->>'project_plural', '') = ''
     THEN '{"project_plural":"Reserves"}'::jsonb ELSE '{}'::jsonb END
  || CASE WHEN COALESCE(labels->>'contacts', '') = ''
     THEN '{"contacts":"Hostes"}'::jsonb ELSE '{}'::jsonb END
WHERE archetype = 'hospitality';

UPDATE data.sector_profiles
SET labels = labels
  || CASE WHEN COALESCE(labels->>'project_plural', '') = ''
     THEN '{"project_plural":"Comandes"}'::jsonb ELSE '{}'::jsonb END
  || CASE WHEN COALESCE(labels->>'contacts', '') = ''
     THEN '{"contacts":"Clients"}'::jsonb ELSE '{}'::jsonb END
WHERE archetype = 'workshop_maker';

CREATE OR REPLACE FUNCTION data.fold_terminology_value(p_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT translate(
    lower(p_value),
    'àáâäãåèéêëìíîïòóôöõùúûüçñýÿ·',
    'aaaaaaeeeeiiiiooooouuuucnyy '
  );
$$;

CREATE OR REPLACE FUNCTION data.sanitize_terminology_value(p_raw text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_clean text;
  v_rest  text;
  v_allowed text :=
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 ''-·?¿!'
    || 'àáâäãåèéêëìíîïòóôöõùúûüçñýÿÀÁÂÄÃÅÈÉÊËÌÍÎÏÒÓÔÖÕÙÚÛÜÇÑÝŸ';
BEGIN
  IF p_raw IS NULL THEN
    RETURN NULL;
  END IF;
  IF p_raw ~ '[<>]' OR p_raw ~* 'https?://' THEN
    RETURN NULL;
  END IF;
  v_clean := btrim(regexp_replace(p_raw, '\s+', ' ', 'g'));
  IF char_length(v_clean) < 2 OR char_length(v_clean) > 40 THEN
    RETURN NULL;
  END IF;
  v_rest := translate(v_clean, v_allowed, '');
  IF v_rest <> '' THEN
    RETURN NULL;
  END IF;
  IF data.fold_terminology_value(v_clean) IN (
    'pressupost', 'pressupostos', 'presupuesto', 'presupuestos',
    'albara', 'albaran', 'albarans', 'albaranes',
    'factura', 'facturas'
  ) THEN
    RETURN NULL;
  END IF;
  RETURN v_clean;
END;
$$;

CREATE OR REPLACE FUNCTION data.sanitize_terminology_map(p_map jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_out jsonb := '{}'::jsonb;
  v_key text;
  v_clean text;
BEGIN
  IF jsonb_typeof(p_map) IS DISTINCT FROM 'object' THEN
    RETURN '{}'::jsonb;
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(p_map)
  LOOP
    CONTINUE WHEN v_key NOT IN ('project', 'project_plural', 'contact', 'contacts', 'price_sheet');
    v_clean := data.sanitize_terminology_value(p_map->>v_key);
    IF v_clean IS NOT NULL THEN
      v_out := v_out || jsonb_build_object(v_key, v_clean);
    END IF;
  END LOOP;
  RETURN v_out;
END;
$$;

REVOKE ALL ON FUNCTION data.fold_terminology_value(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.sanitize_terminology_value(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.sanitize_terminology_map(jsonb) FROM PUBLIC;

CREATE OR REPLACE FUNCTION api.update_tenant_settings(
  p_settings  JSONB,
  p_tenant_id UUID DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id UUID;
  v_key       text;
  v_patch     jsonb;
BEGIN
  v_tenant_id := COALESCE(p_tenant_id, data.active_tenant_id());

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'No active tenant: pass p_tenant_id or set x-tenant-id header';
  END IF;

  IF jsonb_typeof(p_settings) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'p_settings must be a JSON object';
  END IF;

  v_patch := p_settings;
  IF v_patch ? 'terminology' THEN
    IF jsonb_typeof(v_patch->'terminology') IS DISTINCT FROM 'object' THEN
      v_patch := jsonb_set(v_patch, '{terminology}', '{}'::jsonb);
    ELSE
      v_patch := jsonb_set(
        v_patch,
        '{terminology}',
        data.sanitize_terminology_map(v_patch->'terminology')
      );
    END IF;
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(v_patch)
  LOOP
    PERFORM data.assert_setting_write_access(v_tenant_id, 'tenant', v_key, NULL);
  END LOOP;

  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}') || v_patch
  WHERE id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tenant % not found', v_tenant_id;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION api.update_tenant_settings(JSONB, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_tenant_settings(JSONB, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION api.apply_sector_recipe(
  p_sector_profile_id uuid,
  p_company_name      text DEFAULT NULL,
  p_tenant_id         uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id        uuid;
  v_header_tenant_id uuid := data.active_tenant_id();
  v_owner_tenant_count int := 0;
  v_caller_role      text;
  v_profile          data.sector_profiles;
  v_item             jsonb;
  v_is_first_time    boolean := false;
  v_current_profile  uuid;
  v_pos_count        int := 0;
  v_pos_seeded       int := 0;
  v_pos_item         jsonb;
BEGIN
  IF p_tenant_id IS NOT NULL THEN
    v_tenant_id := p_tenant_id;
  ELSIF v_header_tenant_id IS NOT NULL THEN
    v_tenant_id := v_header_tenant_id;
  ELSE
    SELECT COUNT(*)
      INTO v_owner_tenant_count
      FROM jsonb_each(data.jwt_user_tenants()) AS kv(key, val)
     WHERE (kv.val->>'global_role') = 'owner';

    IF v_owner_tenant_count > 1 THEN
      RAISE EXCEPTION 'ambiguous_tenant_context: Cal enviar x-tenant-id quan ets owner de múltiples tenants'
        USING ERRCODE = 'P0001';
    END IF;

    SELECT (kv.key)::uuid
      INTO v_tenant_id
      FROM jsonb_each(data.jwt_user_tenants()) AS kv(key, val)
     WHERE (kv.val->>'global_role') = 'owner'
     LIMIT 1;
  END IF;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'missing_tenant_context: Cal enviar la capçalera x-tenant-id o tenir un token vàlid amb claims de tenant'
      USING ERRCODE = 'P0001';
  END IF;

  v_caller_role := data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role';
  IF v_caller_role IS DISTINCT FROM 'owner' THEN
    RAISE EXCEPTION 'permission_denied: Només els owners poden aplicar la recepta de sector'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_profile FROM data.sector_profiles WHERE id = p_sector_profile_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'sector_profile_not_found: El perfil de sector % no existeix', p_sector_profile_id
      USING ERRCODE = 'P0003';
  END IF;

  SELECT sector_profile_id
    INTO v_current_profile
    FROM data.tenants
   WHERE id = v_tenant_id;

  v_is_first_time := (v_current_profile IS NULL);

  UPDATE data.tenants
  SET
    sector_profile_id = p_sector_profile_id,
    name              = COALESCE(NULLIF(trim(p_company_name), ''), name),
    settings          = CASE
      WHEN v_current_profile IS DISTINCT FROM p_sector_profile_id
      THEN COALESCE(settings, '{}'::jsonb) - 'terminology'
      ELSE settings
    END,
    updated_at        = now()
  WHERE id = v_tenant_id;

  IF v_is_first_time AND jsonb_array_length(v_profile.catalog_seed) > 0 THEN
    FOR v_item IN SELECT jsonb_array_elements(v_profile.catalog_seed) LOOP
      INSERT INTO data.catalog_items (
        tenant_id,
        kind,
        name,
        unit,
        unit_price,
        tax_rate,
        is_active
      )
      VALUES (
        v_tenant_id,
        (v_item->>'kind')::data.catalog_item_kind,
        v_item->>'name',
        COALESCE(v_item->>'unit', 'u'),
        COALESCE((v_item->>'unit_price')::numeric, 0),
        COALESCE((v_item->>'tax_rate')::numeric, 21),
        true
      );
    END LOOP;
  END IF;

  SELECT count(*) INTO v_pos_count
  FROM data.job_positions
  WHERE tenant_id = v_tenant_id;

  IF v_pos_count = 0 THEN
    FOR v_pos_item IN
      SELECT jsonb_array_elements(data.default_job_positions_for_archetype(v_profile.archetype))
    LOOP
      INSERT INTO data.job_positions (tenant_id, code, name, is_active)
      VALUES (
        v_tenant_id,
        NULLIF(btrim(v_pos_item->>'code'), ''),
        btrim(v_pos_item->>'name'),
        true
      )
      ON CONFLICT DO NOTHING;
      v_pos_seeded := v_pos_seeded + 1;
    END LOOP;
  END IF;

  PERFORM data.log_audit_event(
    v_tenant_id,
    auth.uid(),
    NULL,
    'TENANT_ARCHETYPE_SET',
    'tenant',
    v_tenant_id,
    jsonb_build_object(
      'sector_profile_id',     p_sector_profile_id,
      'archetype',             v_profile.archetype,
      'vertical',              v_profile.vertical,
      'company_name_updated',  (p_company_name IS NOT NULL AND trim(p_company_name) <> ''),
      'catalog_items_seeded',  CASE WHEN v_is_first_time THEN jsonb_array_length(v_profile.catalog_seed) ELSE 0 END,
      'job_positions_seeded',  v_pos_seeded,
      'is_first_onboarding',   v_is_first_time
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.apply_sector_recipe(uuid, text, uuid) TO authenticated;

COMMENT ON FUNCTION api.apply_sector_recipe(uuid, text, uuid)
  IS 'Aplica la recepta de sector: sector_profile_id, catàleg productes (primer cop) '
     'i llocs de treball per arquetip si el tenant no en té cap. '
     'Esborra settings.terminology només si canvia sector_profile_id.';
