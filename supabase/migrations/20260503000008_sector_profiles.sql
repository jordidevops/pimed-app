-- =============================================================================
-- Migració 8: Sector Profiles + Onboarding Wizard
-- =============================================================================
-- Propòsit: permetre que cada tenant triï el seu sector/vertical en el
-- primer accés (wizard d'onboarding) i obtingui una configuració inicial
-- (llavor de catàleg, etiquetes, etc.) adaptada al seu negoci.
--
-- Conté:
--   1. data.sector_profiles — taula de receptes per sector (gestió via admin)
--   2. ALTER TABLE data.tenants — afegeix sector_profile_id (FK a sector_profiles)
--   3. RLS data.sector_profiles — lectura per autenticats, escriptura admin/service
--   4. Seed inicial: 5 perfils (field_service, practice, hospitality, workshop_maker, generic)
--   5. api.sector_profiles — vista pública (security_invoker)
--   6. api.my_tenant (REPLACE) — ara inclou sector_profile_id + archetype + sector_icon
--   7. api.apply_sector_recipe(p_sector_profile_id, p_company_name?) — RPC
--      · Actualitza data.tenants.sector_profile_id
--      · Opcional: actualitza data.tenants.name si p_company_name no és buit
--      · Sembla ítems de catàleg (catalog_seed) si és el primer cop
--      · Registra audit TENANT_ARCHETYPE_SET
--
-- PATRONS:
--   · RLS classica: jwt_user_tenants() per a la vista my_tenant (sense canvis d'esquema RLS)
--   · sector_profiles és una taula de sistema (no tenant-scoped): no té RLS de tenant
--   · La RPC apply_sector_recipe és SECURITY INVOKER: el update de data.tenants
--     queda cobert per la policy "tenants: owner pot modificar" (rol 'owner')
--   · La inserció de catalog_items queda coberta per la policy existent (owner/manager)
--   · Audit via data.log_audit_event()
-- =============================================================================


-- ============================================================================
-- 1. data.sector_profiles
-- Taula de receptes de sector. Gestionada per l'admin-portal (no per tenants).
-- No té tenant_id: és global, read-only per als tenants.
-- ============================================================================

CREATE TABLE data.sector_profiles (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

  archetype            text        NOT NULL,
    -- Clau de sector: 'field_service' | 'practice' | 'hospitality' |
    --                 'workshop_maker' | 'generic'

  vertical             text,
    -- Sub-sector lliure (ex: 'plomeria', 'fisioterapia'). NULL = genèric de l'archetype.

  display_name_ca      text        NOT NULL,
    -- Nom llegible en català per mostrar al wizard (ex: 'Serveis al Camp')

  description_ca       text,
    -- Subtítol/descripció per al wizard (ex: 'Instal·ladors, tècnics, SAT...')

  icon                 text,
    -- Emoji o codi d'icona (ex: '🔧'). El frontend el renderitza directament.

  labels               jsonb       NOT NULL DEFAULT '{}',
    -- Etiquetes personalitzades de UI per a aquest sector.
    -- Ex: { "project": "Ordre de servei", "contact": "Client" }
    -- Usat en el futur per mostrar textos adaptats al sector.

  catalog_seed         jsonb       NOT NULL DEFAULT '[]',
    -- Array d'ítems de catàleg inicials que es creen en aplicar la recepta.
    -- Ex: [{"kind":"service","name":"Visita tècnica","unit":"visita","unit_price":65,"tax_rate":21}]
    -- Permet als tenants tenir un punt de partida sense haver de crear tot des de zero.

  calendar_event_types jsonb       NOT NULL DEFAULT '[]',
    -- Tipus d'events de calendari suggerits (reservat per a funcionalitat futura).

  sort_order           integer     NOT NULL DEFAULT 0,
    -- Ordre de mostra al wizard (menor = primer).

  is_active            boolean     NOT NULL DEFAULT true,
    -- Perfil visible al wizard? false = ocult (per manteniment o retirada).

  created_at           timestamptz NOT NULL DEFAULT now()
  -- Nota: no UNIQUE inline per (archetype, vertical) perquè en PostgreSQL
  -- NULL != NULL en constraints i permetria duplicats quan vertical=NULL.
  -- Unicitat gestionada amb índexs parcials NULL-safe (veure sota).
);

COMMENT ON TABLE data.sector_profiles
  IS 'Receptes de sector per a l''onboarding wizard. Una fila per archetype (vertical=NULL = genèrica). '
     'Gestionada per l''admin-portal. Els tenants l''apliquen via api.apply_sector_recipe.';

COMMENT ON COLUMN data.sector_profiles.catalog_seed
  IS 'Array JSONB [{kind,name,unit,unit_price,tax_rate}]. S''insereix a data.catalog_items en aplicar la recepta (primera vegada).';

COMMENT ON COLUMN data.sector_profiles.labels
  IS 'Etiquetes UI adaptades al sector: { "project": "...", "contact": "..." }. Frontend les llegeix per personalitzar textos.';

-- Índexs únics parcials (NULL-safe):
--   · En PostgreSQL la constraint UNIQUE estàndard tracta NULL != NULL, cosa que
--     permetria múltiples files amb (archetype='foo', vertical=NULL).
--   · Dos índexs parcials cobreixen totes les casuístiques sense aquest buit.
CREATE UNIQUE INDEX uq_sector_profiles_archetype_null_vert
  ON data.sector_profiles (archetype)
  WHERE vertical IS NULL;

CREATE UNIQUE INDEX uq_sector_profiles_archetype_vert
  ON data.sector_profiles (archetype, vertical)
  WHERE vertical IS NOT NULL;


-- ============================================================================
-- 2. ALTER data.tenants — afegir sector_profile_id
-- Columna nullable: NULL = tenant no ha completat l'onboarding.
-- El frontend interpreta NULL com "cal mostrar el wizard".
-- ============================================================================

ALTER TABLE data.tenants
  ADD COLUMN sector_profile_id uuid REFERENCES data.sector_profiles(id) ON DELETE SET NULL;

COMMENT ON COLUMN data.tenants.sector_profile_id
  IS 'Recepta de sector aplicada en l''onboarding. NULL = onboarding pendent. '
     'S''assigna via api.apply_sector_recipe.';


-- ============================================================================
-- 3. RLS data.sector_profiles
-- Lectura: tots els autenticats (és catàleg públic del sistema).
-- Escriptura: només service_role / prisma_admin (bypass RLS des de l'admin).
-- ============================================================================

ALTER TABLE data.sector_profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "sector_profiles: lectura per autenticats"
  ON data.sector_profiles
  FOR SELECT
  TO authenticated
  USING (is_active = true);

-- Sense policies d'INSERT/UPDATE/DELETE per a authenticated:
-- les escriptures les fa prisma_admin (BYPASSRLS) des de l'admin-portal.
GRANT SELECT ON data.sector_profiles TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.sector_profiles TO prisma_admin, service_role;


-- ============================================================================
-- 4. Seed inicial: 5 perfils d'archetype
-- Cobreix els casos d'ús principals del MVP. Els admins poden afegir-ne més.
-- ============================================================================

INSERT INTO data.sector_profiles
  (archetype, vertical, display_name_ca, description_ca, icon, sort_order, labels, catalog_seed)
VALUES
  -- field_service: tècnics, instal·ladors, SAT, manteniment
  (
    'field_service', NULL,
    'Serveis al Camp',
    'Instal·ladors, tècnics de manteniment, serveis d''assistència tècnica (SAT).',
    '🔧',
    10,
    '{"project": "Ordre de servei", "contact": "Client"}'::jsonb,
    '[
      {"kind":"service","name":"Visita tècnica",      "unit":"visita","unit_price":65,  "tax_rate":21},
      {"kind":"service","name":"Hora de treball",     "unit":"h",     "unit_price":45,  "tax_rate":21},
      {"kind":"service","name":"Hora extra / festiu", "unit":"h",     "unit_price":60,  "tax_rate":21},
      {"kind":"product","name":"Desplaçament",        "unit":"km",    "unit_price":0.35,"tax_rate":21}
    ]'::jsonb
  ),

  -- practice: consultors, advocats, metges, psicòlegs, gestors
  (
    'practice', NULL,
    'Despatx Professional',
    'Advocats, consultors, metges, psicòlegs, assessors fiscals i gestors.',
    '⚖️',
    20,
    '{"project": "Expedient", "contact": "Client"}'::jsonb,
    '[
      {"kind":"service","name":"Hora de consultoria",  "unit":"h","unit_price":120,"tax_rate":21},
      {"kind":"service","name":"Consulta estàndard",   "unit":"u","unit_price":80, "tax_rate":21},
      {"kind":"service","name":"Primera visita",       "unit":"u","unit_price":60, "tax_rate":21},
      {"kind":"service","name":"Informe / dictamen",   "unit":"u","unit_price":150,"tax_rate":21}
    ]'::jsonb
  ),

  -- hospitality: restaurants, hotels, càtering, bars
  (
    'hospitality', NULL,
    'Hostaleria i Restauració',
    'Restaurants, hotels, càtering, bars i allotjaments turístics.',
    '🍽️',
    30,
    '{"project": "Reserva", "contact": "Hoste"}'::jsonb,
    '[
      {"kind":"product","name":"Àpat menú del dia",    "unit":"u","unit_price":14,  "tax_rate":10},
      {"kind":"product","name":"Menú degustació",      "unit":"u","unit_price":45,  "tax_rate":10},
      {"kind":"service","name":"Servei de càtering",   "unit":"u","unit_price":25,  "tax_rate":10},
      {"kind":"service","name":"Nit d''allotjament",   "unit":"nit","unit_price":90,"tax_rate":10}
    ]'::jsonb
  ),

  -- workshop_maker: tallers mecànics, fusters, dissenyadors, makers
  (
    'workshop_maker', NULL,
    'Taller i Fabricació',
    'Tallers mecànics, fusters, serralleries, dissenyadors i makers.',
    '🛠️',
    40,
    '{"project": "Comanda", "contact": "Client"}'::jsonb,
    '[
      {"kind":"service","name":"Hora de taller",       "unit":"h","unit_price":55,"tax_rate":21},
      {"kind":"service","name":"Hora disseny/CAD",     "unit":"h","unit_price":70,"tax_rate":21},
      {"kind":"product","name":"Material (genèric)",   "unit":"u","unit_price":0, "tax_rate":21},
      {"kind":"service","name":"Envio i logística",    "unit":"u","unit_price":15,"tax_rate":21}
    ]'::jsonb
  ),

  -- generic: ús general sense sector definit
  (
    'generic', NULL,
    'Ús General',
    'Sense sector específic. Pots personalitzar el catàleg posteriorment.',
    '🏢',
    99,
    '{}'::jsonb,
    '[]'::jsonb
  )
ON CONFLICT DO NOTHING;
-- Nota: no especifiquem target de conflicte perquè els índexs parcials NULL-safe
-- no es poden referenciar directament en ON CONFLICT. DO NOTHING és segur aquí
-- perquè l'únic conflicte possible és la unicitat d'archetype+vertical.


-- ============================================================================
-- 5. api.sector_profiles — vista pública per al wizard
-- security_invoker: la policy SELECT authenticated s'aplica automàticament.
-- ============================================================================

CREATE OR REPLACE VIEW api.sector_profiles
  WITH (security_invoker = true) AS
  SELECT
    id,
    archetype,
    vertical,
    display_name_ca,
    description_ca,
    icon,
    sort_order,
    labels,
    -- Nº d'ítems de catàleg que es crearan en aplicar la recepta
    jsonb_array_length(catalog_seed) AS catalog_seed_count,
    created_at
  FROM data.sector_profiles
  WHERE is_active = true
  ORDER BY sort_order;

GRANT SELECT ON api.sector_profiles TO authenticated;

COMMENT ON VIEW api.sector_profiles
  IS 'Catàleg de receptes de sector per al wizard d''onboarding. '
     'Lectura pública per a usuaris autenticats. DML exclusivament via admin-portal.';


-- ============================================================================
-- 6. api.my_tenant (REPLACE) — ara inclou info de sector
-- Afegim sector_profile_id, archetype, sector_display_name, sector_icon i labels.
-- El frontend les usa per:
--   · Detectar si l''onboarding ha estat completat (sector_profile_id IS NULL)
--   · Mostrar el sector actiu a la UI de perfil/settings
-- ============================================================================

CREATE OR REPLACE VIEW api.my_tenant
  WITH (security_invoker = true) AS
  SELECT
    t.id,
    t.name,
    t.slug,
    t.is_active,
    t.created_at,
    t.plan_id,
    p.name          AS plan_name,
    p.display_name  AS plan_display_name,
    p.max_members,
    p.max_storage_mb,
    p.max_sites,
    -- Sector / onboarding
    t.sector_profile_id,
    sp.archetype,
    sp.vertical                AS sector_vertical,
    sp.display_name_ca         AS sector_display_name,
    sp.icon                    AS sector_icon,
    sp.labels                  AS sector_labels
  FROM data.tenants t
  LEFT JOIN data.plans           p  ON p.id  = t.plan_id
  LEFT JOIN data.sector_profiles sp ON sp.id = t.sector_profile_id;

GRANT SELECT ON api.my_tenant TO authenticated;


-- ============================================================================
-- 7. api.apply_sector_recipe — RPC per completar l'onboarding
--
-- Paràmetres:
--   p_sector_profile_id uuid   — ID del perfil de sector triat
--   p_company_name      text?  — Nom confirmat/editat de l'empresa (pot ser buit)
--
-- Efectes:
--   · Actualitza data.tenants.sector_profile_id i (opcionalment) name
--   · Si és la primera vegada (sector_profile_id era NULL), sembra el catàleg
--   · Registra TENANT_ARCHETYPE_SET a audit_logs
--
-- SECURITY DEFINER amb check explícit d'owner per JWT claims.
--   · Es requereix per poder cridar data.log_audit_event() (helper privat)
--   · El control d'accés NO depèn de RLS aquí; es fa explícitament amb
--     data.jwt_user_tenants() -> tenant_id ->> 'global_role' = 'owner'.
--
-- Resolució de tenant actiu:
--   · Prioritza x-tenant-id (multi-tenant UX)
--   · Fallback a claims JWT (Auth Hooks) quan no hi ha header
--   · Si hi ha més d'un tenant owner i no hi ha header, llança error d'ambigüitat
--     per evitar aplicar la recepta al tenant incorrecte.
-- ============================================================================

CREATE OR REPLACE FUNCTION api.apply_sector_recipe(
  p_sector_profile_id uuid,
  p_company_name      text DEFAULT NULL
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
  -- Resolució de tenant: header primer, claims owner com a fallback
  IF v_header_tenant_id IS NOT NULL THEN
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
  -- (la policy "tenants: owner pot modificar" protegeix que només owners puguin fer-ho)
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
    NULL,                          -- sense context de site (operació a nivell tenant)
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

GRANT EXECUTE ON FUNCTION api.apply_sector_recipe(uuid, text) TO authenticated;

COMMENT ON FUNCTION api.apply_sector_recipe(uuid, text)
  IS 'Aplica la recepta de sector al tenant actiu: actualitza sector_profile_id, '
     'opcionalment el nom, i sembra el catàleg inicial (primer cop). '
  'Tenant resolt via COALESCE(x-tenant-id header, JWT claims owner). '
  'Requereix rol owner al tenant actiu (check explícit via JWT claims).';
