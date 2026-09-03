-- =============================================================================
-- Migration: 20260508000002_apply_sector_recipe_explicit_tenant.sql
-- Propòsit : Afegir p_tenant_id com a paràmetre explícit a api.apply_sector_recipe
--            per evitar la dependència del header x-tenant-id en el context
--            d'onboarding (on el client supabase-js pot no tenir el header posat
--            de forma fiable per a l'usuari multi-tenant).
--
-- Canvis:
--   · api.apply_sector_recipe ara accepta p_tenant_id uuid DEFAULT NULL
--   · Si p_tenant_id és proveït, té prioritat sobre x-tenant-id i JWT claims
--   · Backward-compatible: el paràmetre és opcional, els crida existents funcionen
-- =============================================================================

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
BEGIN
  -- Resolució de tenant: paràmetre explícit > header > claims JWT
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

  -- Validació: tenant actiu obligatori
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'missing_tenant_context: Cal enviar la capçalera x-tenant-id o tenir un token vàlid amb claims de tenant'
      USING ERRCODE = 'P0001';
  END IF;

  -- Check explícit de rol 'owner' (obligatori amb SECURITY DEFINER)
  v_caller_role := data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role';
  IF v_caller_role IS DISTINCT FROM 'owner' THEN
    RAISE EXCEPTION 'permission_denied: Només els owners poden aplicar la recepta de sector'
      USING ERRCODE = '42501';
  END IF;

  -- Carrega el perfil de sector
  SELECT * INTO v_profile FROM data.sector_profiles WHERE id = p_sector_profile_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'sector_profile_not_found: El perfil de sector % no existeix', p_sector_profile_id
      USING ERRCODE = 'P0003';
  END IF;

  -- Detecta si és el primer cop (per a la llavor de catàleg)
  SELECT sector_profile_id
    INTO v_current_profile
    FROM data.tenants
   WHERE id = v_tenant_id;

  v_is_first_time := (v_current_profile IS NULL);

  -- Actualitza el tenant: sector_profile_id i opcionalment el nom
  UPDATE data.tenants
  SET
    sector_profile_id = p_sector_profile_id,
    name              = COALESCE(NULLIF(trim(p_company_name), ''), name),
    updated_at        = now()
  WHERE id = v_tenant_id;

  -- Sembrar el catàleg — NOMÉS en el primer onboarding per evitar duplicats
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

  -- Registre d'auditoria
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
      'is_first_onboarding',   v_is_first_time
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.apply_sector_recipe(uuid, text, uuid) TO authenticated;

COMMENT ON FUNCTION api.apply_sector_recipe(uuid, text, uuid)
  IS 'Aplica la recepta de sector al tenant actiu: actualitza sector_profile_id, '
     'opcionalment el nom, i sembra el catàleg inicial (primer cop). '
     'Tenant resolt via COALESCE(p_tenant_id explícit, x-tenant-id header, JWT claims owner). '
     'Requereix rol owner al tenant actiu (check explícit via JWT claims).';
