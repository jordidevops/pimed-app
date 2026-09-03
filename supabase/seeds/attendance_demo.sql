-- Seed demo — horaris, calendaris laborals i fitxatges Acme Corp (2 mesos)
-- Carregat automàticament després de seed.sql via config.toml [db.seed].sql_paths

-- ─── Pauses tipificades (Acme Corp) ─────────────────────────────────────────
-- La migració v2 seeda només tenants existents al moment d'aplicar-la; seed.sql crea
-- Acme/Beta després → sense aquest bloc, PunchPage no mostra botons de pausa.

INSERT INTO data.tenant_pause_configs (
  tenant_id, key, label_i18n, counts_as_work,
  default_duration_min, max_duration_minutes, is_active, sort_order
)
SELECT
  t.id,
  tpl.key, tpl.label_i18n, tpl.counts_as_work,
  tpl.default_duration_min, tpl.max_duration_minutes, true, tpl.sort_order
FROM data.tenants t
CROSS JOIN data.system_pause_config_templates tpl
WHERE t.id IN (
  '10000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000002'
)
AND tpl.archetype_key = 'generic'
ON CONFLICT (tenant_id, key) DO NOTHING;

-- ─── Grups de calendari ───────────────────────────────────────────────────────

INSERT INTO data.calendar_groups (id, tenant_id, site_id, name, color, description, sort_order)
VALUES
  ('46000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000001', NULL,
   'Oficina', '#3b82f6', 'Personal administratiu i direcció', 1),
  ('46000000-0000-0000-0000-000000000002',
   '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001',
   'Taller Gràcia', '#10b981', 'Operaris i tècnics del taller', 2),
  ('46000000-0000-0000-0000-000000000003',
   '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000002',
   'Obres Sants', '#f59e0b', 'Equips d''obres i manteniment', 3)
ON CONFLICT (id) DO NOTHING;

-- ─── Base recurrent setmanal (ADR-0003) ──────────────────────────────────────
-- Patró de grup: consultat en viu pel resolver, no es materialitza per data.
-- Substitueix work_schedules + data.seed_acme_labor_calendar_weekly_base()
-- (que generava ~2 600 files d'overrides). Dl–Dv laboral, Ds–Dg no laborable.

INSERT INTO data.calendar_group_weekly_intervals (
  tenant_id, group_id, day_of_week, day_type, work_start, work_end, work_intervals, valid_from
)
SELECT
  '10000000-0000-0000-0000-000000000001',
  g.group_id, d.dow, 'work', d.work_start, d.work_end, d.work_intervals, '2020-01-01'
FROM (VALUES
  -- Oficina: Dl–Dv 08:30–14:00 + 15:00–17:00 (partida)
  ('46000000-0000-0000-0000-000000000001'::uuid, 1, '08:30'::time, '17:00'::time,
   '[{"start":"08:30","end":"14:00"},{"start":"15:00","end":"17:00"}]'::jsonb),
  ('46000000-0000-0000-0000-000000000001'::uuid, 2, '08:30'::time, '17:00'::time,
   '[{"start":"08:30","end":"14:00"},{"start":"15:00","end":"17:00"}]'::jsonb),
  ('46000000-0000-0000-0000-000000000001'::uuid, 3, '08:30'::time, '17:00'::time,
   '[{"start":"08:30","end":"14:00"},{"start":"15:00","end":"17:00"}]'::jsonb),
  ('46000000-0000-0000-0000-000000000001'::uuid, 4, '08:30'::time, '17:00'::time,
   '[{"start":"08:30","end":"14:00"},{"start":"15:00","end":"17:00"}]'::jsonb),
  ('46000000-0000-0000-0000-000000000001'::uuid, 5, '08:30'::time, '17:00'::time,
   '[{"start":"08:30","end":"14:00"},{"start":"15:00","end":"17:00"}]'::jsonb),
  -- Taller Gràcia: Dl–Dv 07:00–15:00
  ('46000000-0000-0000-0000-000000000002'::uuid, 1, '07:00'::time, '15:00'::time, '[{"start":"07:00","end":"15:00"}]'::jsonb),
  ('46000000-0000-0000-0000-000000000002'::uuid, 2, '07:00'::time, '15:00'::time, '[{"start":"07:00","end":"15:00"}]'::jsonb),
  ('46000000-0000-0000-0000-000000000002'::uuid, 3, '07:00'::time, '15:00'::time, '[{"start":"07:00","end":"15:00"}]'::jsonb),
  ('46000000-0000-0000-0000-000000000002'::uuid, 4, '07:00'::time, '15:00'::time, '[{"start":"07:00","end":"15:00"}]'::jsonb),
  ('46000000-0000-0000-0000-000000000002'::uuid, 5, '07:00'::time, '15:00'::time, '[{"start":"07:00","end":"15:00"}]'::jsonb),
  -- Obres Sants: Dl–Dv 07:30–16:00
  ('46000000-0000-0000-0000-000000000003'::uuid, 1, '07:30'::time, '16:00'::time, '[{"start":"07:30","end":"16:00"}]'::jsonb),
  ('46000000-0000-0000-0000-000000000003'::uuid, 2, '07:30'::time, '16:00'::time, '[{"start":"07:30","end":"16:00"}]'::jsonb),
  ('46000000-0000-0000-0000-000000000003'::uuid, 3, '07:30'::time, '16:00'::time, '[{"start":"07:30","end":"16:00"}]'::jsonb),
  ('46000000-0000-0000-0000-000000000003'::uuid, 4, '07:30'::time, '16:00'::time, '[{"start":"07:30","end":"16:00"}]'::jsonb),
  ('46000000-0000-0000-0000-000000000003'::uuid, 5, '07:30'::time, '16:00'::time, '[{"start":"07:30","end":"16:00"}]'::jsonb)
) AS d(group_id, dow, work_start, work_end, work_intervals)
JOIN (VALUES
  ('46000000-0000-0000-0000-000000000001'::uuid),
  ('46000000-0000-0000-0000-000000000002'::uuid),
  ('46000000-0000-0000-0000-000000000003'::uuid)
) AS g(group_id) ON g.group_id = d.group_id
ON CONFLICT ON CONSTRAINT uq_cgwi_group_dow_from DO NOTHING;

-- Cap de setmana no laborable per als 3 grups (Ds=6, Dg=0)
INSERT INTO data.calendar_group_weekly_intervals (
  tenant_id, group_id, day_of_week, day_type, valid_from
)
SELECT
  '10000000-0000-0000-0000-000000000001', g.group_id, dow, 'non_working', '2020-01-01'
FROM (VALUES
  ('46000000-0000-0000-0000-000000000001'::uuid),
  ('46000000-0000-0000-0000-000000000002'::uuid),
  ('46000000-0000-0000-0000-000000000003'::uuid)
) AS g(group_id)
CROSS JOIN (VALUES (0), (6)) AS wk(dow)
ON CONFLICT ON CONSTRAINT uq_cgwi_group_dow_from DO NOTHING;

-- Overrides individuals (empleats amb horari propi, diferent del seu grup):
-- caps d'obra/encarregats, administratius de Sants, i un empleat de cada 11 (torn tarda).
INSERT INTO data.employee_weekly_intervals (
  tenant_id, employee_id, day_of_week, day_type, work_start, work_end, work_intervals, valid_from
)
SELECT
  e.tenant_id, e.id, dow.d, 'work', p.work_start, p.work_end, p.work_intervals, '2020-01-01'
FROM data.employees e
LEFT JOIN data.job_positions jp ON jp.id = e.job_position_id
CROSS JOIN (VALUES (1), (2), (3), (4), (5)) AS dow(d)
CROSS JOIN LATERAL (
  SELECT
    CASE
      WHEN jp.name ILIKE 'Cap d%obra%' OR jp.name ILIKE 'Encarregad%'
        OR e.id = '40000000-0000-0000-0000-000000000012'::uuid -- Marta: cap d'obra
        THEN '08:00'::time
      WHEN jp.name ILIKE 'Administratiu%' AND e.site_id = '30000000-0000-0000-0000-000000000002'::uuid
        THEN '09:00'::time
      WHEN (abs(hashtext(e.id::text)) % 11) = 0
        THEN '14:00'::time
      ELSE NULL
    END AS work_start,
    CASE
      WHEN jp.name ILIKE 'Cap d%obra%' OR jp.name ILIKE 'Encarregad%'
        OR e.id = '40000000-0000-0000-0000-000000000012'::uuid
        THEN '17:00'::time
      WHEN jp.name ILIKE 'Administratiu%' AND e.site_id = '30000000-0000-0000-0000-000000000002'::uuid
        THEN '17:30'::time
      WHEN (abs(hashtext(e.id::text)) % 11) = 0
        THEN '22:00'::time
      ELSE NULL
    END AS work_end,
    CASE
      WHEN jp.name ILIKE 'Cap d%obra%' OR jp.name ILIKE 'Encarregad%'
        OR e.id = '40000000-0000-0000-0000-000000000012'::uuid
        THEN '[{"start":"08:00","end":"17:00"}]'::jsonb
      WHEN jp.name ILIKE 'Administratiu%' AND e.site_id = '30000000-0000-0000-0000-000000000002'::uuid
        THEN '[{"start":"09:00","end":"14:00"},{"start":"15:00","end":"17:30"}]'::jsonb
      WHEN (abs(hashtext(e.id::text)) % 11) = 0
        THEN '[{"start":"14:00","end":"22:00"}]'::jsonb
      ELSE NULL
    END AS work_intervals
) p
WHERE e.tenant_id = '10000000-0000-0000-0000-000000000001'
  AND e.status = 'active'
  AND p.work_intervals IS NOT NULL
ON CONFLICT ON CONSTRAINT uq_ewi_employee_dow_from DO NOTHING;

-- ─── Calendari de festius Catalunya (tenant Acme) ────────────────────────────

INSERT INTO data.holiday_calendars (id, tenant_id, name, country_code, region_code, year, is_active)
VALUES
  ('47000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000001',
   'Festius Catalunya Acme', 'ES', 'ES-CAT', NULL, true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.holidays (calendar_id, date, name, holiday_type)
VALUES
  ('47000000-0000-0000-0000-000000000001', '2025-01-01', 'Cap d''Any', 'national'),
  ('47000000-0000-0000-0000-000000000001', '2025-01-06', 'Reis', 'national'),
  ('47000000-0000-0000-0000-000000000001', '2025-04-18', 'Divendres Sant', 'national'),
  ('47000000-0000-0000-0000-000000000001', '2025-04-21', 'Dilluns de Pasqua', 'national'),
  ('47000000-0000-0000-0000-000000000001', '2025-05-01', 'Festa del Treball', 'national'),
  ('47000000-0000-0000-0000-000000000001', '2025-06-24', 'Sant Joan', 'regional'),
  ('47000000-0000-0000-0000-000000000001', '2025-08-15', 'Assumpció', 'national'),
  ('47000000-0000-0000-0000-000000000001', '2025-09-11', 'Diada de Catalunya', 'regional'),
  ('47000000-0000-0000-0000-000000000001', '2025-12-08', 'Immaculada', 'national'),
  ('47000000-0000-0000-0000-000000000001', '2025-12-25', 'Nadal', 'national'),
  ('47000000-0000-0000-0000-000000000001', '2025-12-26', 'Sant Esteve', 'regional'),
  ('47000000-0000-0000-0000-000000000001', '2026-01-01', 'Cap d''Any', 'national'),
  ('47000000-0000-0000-0000-000000000001', '2026-01-06', 'Reis', 'national'),
  ('47000000-0000-0000-0000-000000000001', '2026-04-03', 'Divendres Sant', 'national'),
  ('47000000-0000-0000-0000-000000000001', '2026-04-06', 'Dilluns de Pasqua', 'national'),
  ('47000000-0000-0000-0000-000000000001', '2026-05-01', 'Festa del Treball', 'national'),
  ('47000000-0000-0000-0000-000000000001', '2026-06-24', 'Sant Joan', 'regional'),
  ('47000000-0000-0000-0000-000000000001', '2026-08-15', 'Assumpció', 'national'),
  ('47000000-0000-0000-0000-000000000001', '2026-09-11', 'Diada de Catalunya', 'regional'),
  ('47000000-0000-0000-0000-000000000001', '2026-12-08', 'Immaculada', 'national'),
  ('47000000-0000-0000-0000-000000000001', '2026-12-25', 'Nadal', 'national'),
  ('47000000-0000-0000-0000-000000000001', '2026-12-26', 'Sant Esteve', 'regional'),
  -- Festa d'empresa
  ('47000000-0000-0000-0000-000000000001', '2026-05-15', 'Retir empresa Acme', 'tenant_custom')
ON CONFLICT (calendar_id, date) DO NOTHING;

INSERT INTO data.tenant_holiday_calendar_assignments (tenant_id, calendar_id, priority)
VALUES ('10000000-0000-0000-0000-000000000001', '47000000-0000-0000-0000-000000000001', 10)
ON CONFLICT (tenant_id, calendar_id) DO NOTHING;

INSERT INTO data.site_holiday_calendar_assignments (site_id, calendar_id, priority)
VALUES
  ('30000000-0000-0000-0000-000000000001', '47000000-0000-0000-0000-000000000001', 10),
  ('30000000-0000-0000-0000-000000000002', '47000000-0000-0000-0000-000000000001', 10)
ON CONFLICT (site_id, calendar_id) DO NOTHING;

-- Override local: tancament tècnic Gràcia (1 dia laborable del mes passat dinàmicament no cal —
-- posem un dia fix relatiu al seed: pont després de Sant Joan 2026)
INSERT INTO data.labor_calendar_overrides
  (id, tenant_id, site_id, calendar_date, day_type, day_name, work_intervals)
VALUES
  ('48000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001',
   '2026-06-25', 'vacation', 'Pont post-Sant Joan', NULL)
ON CONFLICT (id) DO NOTHING;

-- ─── Assignació de grups als empleats Acme ───────────────────────────────────
-- L'horari efectiu ve del calendar_group_id (base recurrent ADR-0003) més
-- els overrides individuals (employee_weekly_intervals) inserits més amunt.

UPDATE data.employees e
SET calendar_group_id = CASE
  WHEN (
      SELECT jp.name FROM data.job_positions jp WHERE jp.id = e.job_position_id
    ) ILIKE 'Administratiu%'
    OR e.id = '40000000-0000-0000-0000-000000000001'
    THEN '46000000-0000-0000-0000-000000000001'::uuid
  WHEN e.site_id = '30000000-0000-0000-0000-000000000002'
    THEN '46000000-0000-0000-0000-000000000003'::uuid
  ELSE '46000000-0000-0000-0000-000000000002'::uuid
END
WHERE e.tenant_id = '10000000-0000-0000-0000-000000000001'
  AND e.status = 'active';

-- Perfils de treball (Track G) per persones demo
UPDATE data.employees e
SET attendance_work_profile = CASE e.id
  WHEN '40000000-0000-0000-0000-000000000021'::uuid THEN 'mobile_peripatetic' -- Albert Font: camp
  ELSE 'fixed_site'
END
WHERE e.tenant_id = '10000000-0000-0000-0000-000000000001'
  AND e.status = 'active'
  AND e.id IN (
    '40000000-0000-0000-0000-000000000005',
    '40000000-0000-0000-0000-000000000008',
    '40000000-0000-0000-0000-000000000012',
    '40000000-0000-0000-0000-000000000021'
  );

-- Tokens portal dev addicionals (oficina + cap d'obra)
INSERT INTO data.employee_portal_tokens (
  id, tenant_id, employee_id, token_hash, label, is_active
)
VALUES
  (
    '50000000-0000-0000-0000-000000000003',
    '10000000-0000-0000-0000-000000000001',
    '40000000-0000-0000-0000-000000000008',
    digest('ep0-dev-acme-laia', 'sha256'),
    'Spike dev Acme Laia (oficina)',
    true
  ),
  (
    '50000000-0000-0000-0000-000000000004',
    '10000000-0000-0000-0000-000000000001',
    '40000000-0000-0000-0000-000000000012',
    digest('ep0-dev-acme-marta', 'sha256'),
    'Spike dev Acme Marta (cap obra)',
    true
  )
ON CONFLICT (id) DO NOTHING;

-- ─── EX-06.1 — Rols operatius demo (Acme) ────────────────────────────────────
-- Independent de job_positions: capacitats per cobertura SP-3.

INSERT INTO data.work_roles (id, tenant_id, site_id, key, name, sort_order, is_active)
VALUES
  ('49000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', NULL, 'electricista', 'Electricista', 10, true),
  ('49000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', NULL, 'mecanic', 'Mecànic', 20, true),
  ('49000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', NULL, 'magatzem', 'Magatzem', 30, true),
  ('49000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', NULL, 'oficina', 'Oficina', 40, true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.role_qualification_requirements (id, tenant_id, role_id, qualification_key, required, min_level, is_active)
VALUES
  ('49000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001',
   '49000000-0000-0000-0000-000000000001', 'bt_baixa_tensio', true, NULL, true),
  ('49000000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000001',
   '49000000-0000-0000-0000-000000000003', 'carretilla', true, NULL, true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employee_role_assignments (id, tenant_id, employee_id, role_id, level, is_primary, is_active)
VALUES
  ('49000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000005', '49000000-0000-0000-0000-000000000001', 2, true, true),
  ('49000000-0000-0000-0000-000000000022', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000008', '49000000-0000-0000-0000-000000000004', 1, true, true),
  ('49000000-0000-0000-0000-000000000023', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000022', '49000000-0000-0000-0000-000000000003', 1, true, true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employee_qualifications (id, tenant_id, employee_id, key, label, issued_at, expires_at, is_active)
VALUES
  ('49000000-0000-0000-0000-000000000031', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000005', 'bt_baixa_tensio', 'BT Baixa tensió',
   CURRENT_DATE - 90, CURRENT_DATE + 365, true),
  ('49000000-0000-0000-0000-000000000032', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000022', 'carretilla', 'Carretilla',
   CURRENT_DATE - 30, CURRENT_DATE + 180, true)
ON CONFLICT (id) DO NOTHING;

-- ─── EX-06.2 — Demanda cobertura demo (Acme Gràcia) ──────────────────────────
INSERT INTO data.coverage_demands (
  id, tenant_id, site_id, role_id, kind, day_of_week, demand_date,
  start_time, end_time, required_min, required_target, required_max,
  priority, source, name, effective_from, effective_to, is_active
)
VALUES
  (
    '4a000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',
    '30000000-0000-0000-0000-000000000001',
    '49000000-0000-0000-0000-000000000001',
    'recurring', 1, NULL,
    '08:00', '16:00', 1, 2, 3,
    50, 'manual', 'Electricistes dilluns', CURRENT_DATE - 30, NULL, true
  ),
  (
    '4a000000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000001',
    '30000000-0000-0000-0000-000000000001',
    '49000000-0000-0000-0000-000000000003',
    'recurring', 5, NULL,
    '09:00', '13:00', 1, 1, 2,
    60, 'manual', 'Magatzem divendres matí', CURRENT_DATE - 30, NULL, true
  )
ON CONFLICT (id) DO NOTHING;

-- Genera fitxatges demo (funció definida a migració 20260803000001)
SELECT data.seed_acme_attendance_punches();
