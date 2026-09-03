-- =============================================================================
-- 03 — Pauses hospitality, calendaris 7d, festius CAT, overrides individuals
-- =============================================================================

INSERT INTO data.tenant_pause_configs (
  tenant_id, key, label_i18n, counts_as_work,
  default_duration_min, max_duration_minutes, is_active, sort_order
)
SELECT
  'a1000000-0000-0000-0000-000000000001',
  tpl.key, tpl.label_i18n, tpl.counts_as_work,
  tpl.default_duration_min, tpl.max_duration_minutes, true, tpl.sort_order
FROM data.system_pause_config_templates tpl
WHERE tpl.archetype_key = 'hospitality'
ON CONFLICT (tenant_id, key) DO NOTHING;

INSERT INTO data.calendar_groups (id, tenant_id, site_id, name, color, description, sort_order)
VALUES
  ('a4600000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', NULL,
   'Administració', '#3b82f6', 'Central i oficines', 1),
  ('a4600000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001',
   'Equip Eixample', '#f97316', 'Plantilla operatiu Eixample (7 dies)', 2),
  ('a4600000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002',
   'Equip Diagonal', '#10b981', 'Plantilla operatiu Diagonal (7 dies)', 3)
ON CONFLICT (id) DO NOTHING;

-- Admin: Dl–Dv partida 09–14 + 15–18
INSERT INTO data.calendar_group_weekly_intervals (
  tenant_id, group_id, day_of_week, day_type, work_start, work_end, work_intervals, valid_from
)
SELECT
  'a1000000-0000-0000-0000-000000000001',
  'a4600000-0000-0000-0000-000000000001',
  d.dow, 'work', '09:00'::time, '18:00'::time,
  '[{"start":"09:00","end":"14:00"},{"start":"15:00","end":"18:00"}]'::jsonb,
  '2020-01-01'::date
FROM generate_series(1, 5) AS d(dow)
ON CONFLICT DO NOTHING;

INSERT INTO data.calendar_group_weekly_intervals (
  tenant_id, group_id, day_of_week, day_type, work_start, work_end, work_intervals, valid_from
)
VALUES
  ('a1000000-0000-0000-0000-000000000001', 'a4600000-0000-0000-0000-000000000001',
   0, 'non_working', NULL, NULL, NULL, '2020-01-01'),
  ('a1000000-0000-0000-0000-000000000001', 'a4600000-0000-0000-0000-000000000001',
   6, 'non_working', NULL, NULL, NULL, '2020-01-01')
ON CONFLICT DO NOTHING;

-- Equip locals: 7 dies, franja tipica 10:00–15:00 + 18:00–23:00 (dinar+sopar)
INSERT INTO data.calendar_group_weekly_intervals (
  tenant_id, group_id, day_of_week, day_type, work_start, work_end, work_intervals, valid_from
)
SELECT
  'a1000000-0000-0000-0000-000000000001',
  g.id,
  d.dow,
  'work',
  '10:00'::time,
  '23:00'::time,
  '[{"start":"10:00","end":"15:00"},{"start":"18:00","end":"23:00"}]'::jsonb,
  '2020-01-01'::date
FROM (VALUES
  ('a4600000-0000-0000-0000-000000000002'::uuid),
  ('a4600000-0000-0000-0000-000000000003'::uuid)
) AS g(id)
CROSS JOIN generate_series(0, 6) AS d(dow)
ON CONFLICT DO NOTHING;

-- Assign calendar groups
UPDATE data.employees SET calendar_group_id = 'a4600000-0000-0000-0000-000000000001'
WHERE id IN (
  'a4000000-0000-0000-0000-000000000021',
  'a4000000-0000-0000-0000-000000000022',
  'a4000000-0000-0000-0000-000000000023'
);

UPDATE data.employees SET calendar_group_id = 'a4600000-0000-0000-0000-000000000002'
WHERE site_id = 'a3000000-0000-0000-0000-000000000001';

UPDATE data.employees SET calendar_group_id = 'a4600000-0000-0000-0000-000000000003'
WHERE site_id = 'a3000000-0000-0000-0000-000000000002';

-- Overrides individuals: estudiants (caps de setmana / vespre)
INSERT INTO data.employee_weekly_intervals (
  tenant_id, employee_id, day_of_week, day_type, work_start, work_end, work_intervals, valid_from
)
SELECT
  'a1000000-0000-0000-0000-000000000001',
  e.id,
  d.dow,
  CASE WHEN d.dow IN (5, 6, 0) THEN 'work' ELSE 'non_working' END,
  CASE WHEN d.dow IN (5, 6, 0) THEN '18:00'::time ELSE NULL END,
  CASE WHEN d.dow IN (5, 6, 0) THEN '23:00'::time ELSE NULL END,
  CASE WHEN d.dow IN (5, 6, 0)
    THEN '[{"start":"18:00","end":"23:00"}]'::jsonb
    ELSE NULL END,
  '2026-01-01'::date
FROM (VALUES
  ('a4000000-0000-0000-0000-000000000009'::uuid),
  ('a4000000-0000-0000-0000-000000000019'::uuid)
) AS e(id)
CROSS JOIN generate_series(0, 6) AS d(dow)
ON CONFLICT DO NOTHING;

-- Cap torn tarda: només tarda/sopar
INSERT INTO data.employee_weekly_intervals (
  tenant_id, employee_id, day_of_week, day_type, work_start, work_end, work_intervals, valid_from
)
SELECT
  'a1000000-0000-0000-0000-000000000001',
  e.id,
  d.dow,
  'work',
  '15:30'::time,
  '23:30'::time,
  '[{"start":"15:30","end":"23:30"}]'::jsonb,
  '2026-01-01'::date
FROM (VALUES
  ('a4000000-0000-0000-0000-000000000003'::uuid),
  ('a4000000-0000-0000-0000-000000000013'::uuid)
) AS e(id)
CROSS JOIN generate_series(0, 6) AS d(dow)
ON CONFLICT DO NOTHING;

-- Festius Catalunya 2026
INSERT INTO data.holiday_calendars (id, tenant_id, name, country_code, region_code, year, is_active)
VALUES (
  'a4700000-0000-0000-0000-000000000001',
  'a1000000-0000-0000-0000-000000000001',
  'Festius Catalunya BurgerVista 2026',
  'ES', 'ES-CAT', 2026, true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.holidays (calendar_id, date, name, holiday_type)
VALUES
  ('a4700000-0000-0000-0000-000000000001', '2026-01-01', 'Cap d''Any', 'national'),
  ('a4700000-0000-0000-0000-000000000001', '2026-01-06', 'Reis', 'national'),
  ('a4700000-0000-0000-0000-000000000001', '2026-04-03', 'Divendres Sant', 'national'),
  ('a4700000-0000-0000-0000-000000000001', '2026-04-06', 'Dilluns de Pasqua', 'regional'),
  ('a4700000-0000-0000-0000-000000000001', '2026-05-01', 'Festa del Treball', 'national'),
  ('a4700000-0000-0000-0000-000000000001', '2026-06-24', 'Sant Joan', 'regional'),
  ('a4700000-0000-0000-0000-000000000001', '2026-09-11', 'Diada Nacional de Catalunya', 'regional'),
  ('a4700000-0000-0000-0000-000000000001', '2026-10-12', 'Festa Nacional d''Espanya', 'national'),
  ('a4700000-0000-0000-0000-000000000001', '2026-11-01', 'Tots Sants', 'national'),
  ('a4700000-0000-0000-0000-000000000001', '2026-12-06', 'Dia de la Constitució', 'national'),
  ('a4700000-0000-0000-0000-000000000001', '2026-12-08', 'Immaculada Concepció', 'national'),
  ('a4700000-0000-0000-0000-000000000001', '2026-12-25', 'Nadal', 'national'),
  ('a4700000-0000-0000-0000-000000000001', '2026-12-26', 'Sant Esteve', 'regional')
ON CONFLICT (calendar_id, date) DO NOTHING;

INSERT INTO data.tenant_holiday_calendar_assignments (tenant_id, calendar_id, priority)
VALUES ('a1000000-0000-0000-0000-000000000001', 'a4700000-0000-0000-0000-000000000001', 10)
ON CONFLICT DO NOTHING;

INSERT INTO data.site_holiday_calendar_assignments (site_id, calendar_id, priority)
VALUES
  ('a3000000-0000-0000-0000-000000000001', 'a4700000-0000-0000-0000-000000000001', 10),
  ('a3000000-0000-0000-0000-000000000002', 'a4700000-0000-0000-0000-000000000001', 10)
ON CONFLICT DO NOTHING;
