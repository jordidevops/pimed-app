-- =============================================================================
-- Smoke fixtures — Control horari EX-02…EX-05 (Acme Corp)
-- =============================================================================
-- Ús: enganxar a l'Editor SQL de Supabase (local o staging) DESPRÉS de
--      `supabase db reset` / seed (`seed.sql` + `attendance_demo.sql`).
--
-- No és una migració: és idempotent on és possible i pensat per proves manuals.
-- Guia: docs/plans/checkin/ex-smoke-checklist.md
--
-- IDs Acme (seed):
--   tenant  10000000-0000-0000-0000-000000000001
--   site    30000000-0000-0000-0000-000000000001  (Gràcia)
--   loc A   41000000-0000-0000-0000-000000000002  (Magatzem electric)
--   loc B   41000000-0000-0000-0000-000000000003  (Zona de muntatge)
--   emp     40000000-0000-0000-0000-000000000005  (Montserrat)
--   emp     40000000-0000-0000-0000-000000000008  (Laia)
--   emp     40000000-0000-0000-0000-000000000012  (Marta)
--   grup    46000000-0000-0000-0000-000000000002  (Taller Gràcia)
--
-- Documents smoke: SMOKE005A / SMOKE008B / SMOKE012C / SMOKE021D
-- PIN portal smoke: 1234
-- =============================================================================

BEGIN;

-- ─── 0. Sanity: tenant + seed base ───────────────────────────────────────────

DO $$
DECLARE
  v_groups int;
  v_weekly int;
  v_pauses int;
BEGIN
  SELECT count(*) INTO v_groups FROM data.calendar_groups
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001';
  SELECT count(*) INTO v_weekly FROM data.calendar_group_weekly_intervals
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001';
  SELECT count(*) INTO v_pauses FROM data.tenant_pause_configs
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001' AND is_active;

  IF v_groups < 3 OR v_weekly < 15 OR v_pauses < 1 THEN
    RAISE EXCEPTION
      'Seed Acme incomplet (groups=%, weekly=%, pauses=%). Executa db reset o attendance_demo.sql.',
      v_groups, v_weekly, v_pauses;
  END IF;

  RAISE NOTICE 'OK seed base: groups=%, weekly_intervals=%, pause_configs=%',
    v_groups, v_weekly, v_pauses;
END $$;

-- ─── 1. Documents d'identitat (ST-18a kiosk document_entry) ───────────────────

UPDATE data.employees
SET document_id = CASE id
  WHEN '40000000-0000-0000-0000-000000000005' THEN 'SMOKE005A'  -- Montserrat
  WHEN '40000000-0000-0000-0000-000000000008' THEN 'SMOKE008B'  -- Laia
  WHEN '40000000-0000-0000-0000-000000000012' THEN 'SMOKE012C'  -- Marta
  WHEN '40000000-0000-0000-0000-000000000021' THEN 'SMOKE021D'  -- Albert
  ELSE document_id
END
WHERE tenant_id = '10000000-0000-0000-0000-000000000001'
  AND id IN (
    '40000000-0000-0000-0000-000000000005',
    '40000000-0000-0000-0000-000000000008',
    '40000000-0000-0000-0000-000000000012',
    '40000000-0000-0000-0000-000000000021'
  );

-- ─── 2. PIN portal (ST-18 challenge kiosk + portal) ───────────────────────────
-- PIN de prova: 1234

UPDATE data.employee_portal_tokens t
SET
  pin_hash = data.hash_employee_portal_pin('1234'),
  pin_must_set = false,
  updated_at = now()
WHERE t.tenant_id = '10000000-0000-0000-0000-000000000001'
  AND t.employee_id IN (
    '40000000-0000-0000-0000-000000000005',
    '40000000-0000-0000-0000-000000000008',
    '40000000-0000-0000-0000-000000000012'
  )
  AND t.is_active;

-- ─── 3. Política canal de fitxatge (ST-10 / ST-10b) — estat inicial ───────────
-- Tenant: portal permès. Montserrat: herència. Laia: força portal. Marta: només estació.

UPDATE data.tenants
SET settings = coalesce(settings, '{}'::jsonb)
  || jsonb_build_object('punch_only_at_stations', false)
WHERE id = '10000000-0000-0000-0000-000000000001';

UPDATE data.employees
SET punch_only_at_stations = NULL
WHERE id = '40000000-0000-0000-0000-000000000005';

UPDATE data.employees
SET punch_only_at_stations = false
WHERE id = '40000000-0000-0000-0000-000000000008';

UPDATE data.employees
SET punch_only_at_stations = true
WHERE id = '40000000-0000-0000-0000-000000000012';

UPDATE data.calendar_groups
SET punch_only_at_stations = NULL
WHERE id = '46000000-0000-0000-0000-000000000002';

-- ─── 4. Plantilles de torn + slots setmana ISO actual (EX-04) ─────────────────

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_site   uuid := '30000000-0000-0000-0000-000000000001';
  v_loc_a  uuid := '41000000-0000-0000-0000-000000000002'; -- Magatzem electric
  v_loc_b  uuid := '41000000-0000-0000-0000-000000000003'; -- Zona de muntatge
  v_emp    uuid := '40000000-0000-0000-0000-000000000005';
  v_shift  uuid := '48000000-0000-0000-0000-00000000f001';
  v_monday date;
  v_slot_ok uuid := '49000000-0000-0000-0000-00000000f001';
  v_slot_wrong uuid := '49000000-0000-0000-0000-00000000f002';
BEGIN
  -- Dilluns ISO de la setmana actual a Europe/Madrid
  v_monday := (
    (now() AT TIME ZONE 'Europe/Madrid')::date
    - ((EXTRACT(ISODOW FROM (now() AT TIME ZONE 'Europe/Madrid')::date)::int) - 1)
  );

  INSERT INTO data.work_shifts (
    id, tenant_id, site_id, name, color, start_time, end_time,
    default_location_id, is_active
  )
  VALUES (
    v_shift, v_tenant, v_site,
    'Smoke Matí Taller', '#0ea5e9', '07:00', '15:00',
    v_loc_a, true
  )
  ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    default_location_id = EXCLUDED.default_location_id,
    is_active = true,
    start_time = EXCLUDED.start_time,
    end_time = EXCLUDED.end_time;

  DELETE FROM data.shift_slots
  WHERE tenant_id = v_tenant
    AND id IN (v_slot_ok, v_slot_wrong);

  -- Dilluns: ubicació = Magatzem (coincideix amb estació smoke típica)
  INSERT INTO data.shift_slots (
    id, tenant_id, site_id, shift_id, employee_id,
    slot_date, start_time, end_time, location_id, status
  )
  VALUES (
    v_slot_ok, v_tenant, v_site, v_shift, v_emp,
    v_monday,
    '07:00',
    '15:00',
    v_loc_a,
    'draft'
  );

  -- Dimarts: ubicació = Zona muntatge (ST-18c vs estació a Magatzem)
  INSERT INTO data.shift_slots (
    id, tenant_id, site_id, shift_id, employee_id,
    slot_date, start_time, end_time, location_id, status
  )
  VALUES (
    v_slot_wrong, v_tenant, v_site, v_shift, v_emp,
    v_monday + 1,
    '07:00',
    '15:00',
    v_loc_b,
    'draft'
  );

  RAISE NOTICE 'OK work_shift + 2 draft slots (Mon Magatzem, Tue Muntatge). Monday=%', v_monday;
  RAISE NOTICE 'Publica des de UI Planificació → Torns (preflight) abans de provar portal/estació.';
END $$;

-- ─── 5. Override calendari puntual (cascade) ─────────────────────────────────
-- Demà: vacation a nivell empleat Montserrat.
-- Resolver: labor_day_type vacation → day_type operatiu non_working.

INSERT INTO data.labor_calendar_overrides (
  id, tenant_id, site_id, group_id, employee_id,
  calendar_date, day_type, day_name, work_intervals
)
VALUES (
  '4a000000-0000-0000-0000-00000000f001',
  '10000000-0000-0000-0000-000000000001',
  NULL, NULL,
  '40000000-0000-0000-0000-000000000005',
  ((now() AT TIME ZONE 'Europe/Madrid')::date + 1),
  'vacation',
  'Smoke override vacances +1d',
  NULL
)
ON CONFLICT (id) DO UPDATE SET
  calendar_date = EXCLUDED.calendar_date,
  day_type = EXCLUDED.day_type,
  day_name = EXCLUDED.day_name;

-- ─── 6. Verificació ràpida resolver + polítiques ──────────────────────────────

SELECT
  'today' AS when_label,
  r->>'day_type' AS day_type,
  r->>'labor_day_type' AS labor_day_type,
  r->>'labor_source' AS labor_source,
  r->>'base_source' AS base_source,
  r->'work_intervals' AS work_intervals
FROM data.resolve_employee_work_plan(
  '40000000-0000-0000-0000-000000000005',
  (now() AT TIME ZONE 'Europe/Madrid')::date
) AS r;

SELECT
  'tomorrow_override' AS when_label,
  r->>'day_type' AS day_type,
  r->>'labor_day_type' AS labor_day_type,
  r->>'labor_source' AS labor_source
FROM data.resolve_employee_work_plan(
  '40000000-0000-0000-0000-000000000005',
  ((now() AT TIME ZONE 'Europe/Madrid')::date + 1)
) AS r;
-- Esperat: labor_day_type ~ vacation/leave, day_type = non_working

SELECT
  e.full_name,
  e.document_id,
  e.punch_only_at_stations AS emp_punch_only,
  data.resolve_punch_only_at_stations(e.id) AS resolved_punch_only,
  (SELECT count(*) FROM data.employee_portal_tokens t
   WHERE t.employee_id = e.id AND t.pin_hash IS NOT NULL AND t.is_active) AS tokens_with_pin
FROM data.employees e
WHERE e.id IN (
  '40000000-0000-0000-0000-000000000005',
  '40000000-0000-0000-0000-000000000008',
  '40000000-0000-0000-0000-000000000012'
)
ORDER BY e.full_name;
-- Esperat: Montserrat false (herència), Laia false, Marta true

COMMIT;

-- =============================================================================
-- Després de publicar slots des de la UI:
--
-- SELECT id, status, slot_date, location_id, publication_id
-- FROM data.shift_slots
-- WHERE id IN (
--   '49000000-0000-0000-0000-00000000f001',
--   '49000000-0000-0000-0000-00000000f002'
-- );
--
-- Neteja fixtures (opcional):
--
-- BEGIN;
-- DELETE FROM data.shift_slots WHERE id IN (
--   '49000000-0000-0000-0000-00000000f001',
--   '49000000-0000-0000-0000-00000000f002'
-- );
-- DELETE FROM data.work_shifts WHERE id = '48000000-0000-0000-0000-00000000f001';
-- DELETE FROM data.labor_calendar_overrides WHERE id = '4a000000-0000-0000-0000-00000000f001';
-- COMMIT;
-- =============================================================================
