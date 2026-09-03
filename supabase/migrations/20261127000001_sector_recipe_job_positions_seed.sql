-- =============================================================================
-- Seed default job_positions (llocs de treball) per arquetip on apply_sector_recipe
-- =============================================================================

CREATE OR REPLACE FUNCTION data.default_job_positions_for_archetype(p_archetype text)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(coalesce(p_archetype, 'generic'))
    WHEN 'hospitality' THEN
      '[
        {"code":"DIR","name":"Directora / Director"},
        {"code":"CAP_TORN","name":"Cap de torn"},
        {"code":"CAMBRER","name":"Cambrer/a"},
        {"code":"CUINER","name":"Cuiner/a"},
        {"code":"HOSTESSA","name":"Hostessa"},
        {"code":"ADMIN","name":"Administració"}
      ]'::jsonb
    WHEN 'field_service' THEN
      '[
        {"code":"CAP_OBRA","name":"Cap d''obra"},
        {"code":"OFICIAL","name":"Oficial"},
        {"code":"AJUDANT","name":"Ajudant"},
        {"code":"TECNIC","name":"Tècnic"},
        {"code":"ADMIN","name":"Administració"}
      ]'::jsonb
    WHEN 'practice' THEN
      '[
        {"code":"SOCI","name":"Soci/a"},
        {"code":"PROF","name":"Professional"},
        {"code":"ADMIN","name":"Administració"}
      ]'::jsonb
    WHEN 'workshop_maker' THEN
      '[
        {"code":"RESP","name":"Responsable taller"},
        {"code":"OPERARI","name":"Operari"},
        {"code":"COMERCIAL","name":"Comercial"},
        {"code":"ADMIN","name":"Administració"}
      ]'::jsonb
    ELSE
      '[
        {"code":"MANAGER","name":"Manager"},
        {"code":"TECNIC","name":"Tècnic"},
        {"code":"ADMIN","name":"Administració"},
        {"code":"OPERARI","name":"Operari"}
      ]'::jsonb
  END;
$$;

COMMENT ON FUNCTION data.default_job_positions_for_archetype(text) IS
  'Catàleg inicial de llocs de treball (job_positions) per arquetip de sector.';

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

  -- Llocs de treball: només si el tenant encara no en té
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
     'i llocs de treball per arquetip si el tenant no en té cap.';

NOTIFY pgrst, 'reload schema';
