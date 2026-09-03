-- =============================================================================
-- 05 — Torns Obertura→Tancament, coverage pic domicili, slots 2 setmanes
-- =============================================================================

-- Plantilles de torn per seu
INSERT INTO data.work_shifts (id, tenant_id, site_id, name, color, start_time, end_time, default_location_id, is_active)
VALUES
  -- Eixample
  ('a6000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Obertura', '#64748b', '06:30', '10:00',
   'a5000000-0000-0000-0000-000000000001', true),
  ('a6000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Esmorzar', '#94a3b8', '08:00', '12:00',
   'a5000000-0000-0000-0000-000000000002', true),
  ('a6000000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Dinar', '#f97316', '11:30', '16:00',
   'a5000000-0000-0000-0000-000000000001', true),
  ('a6000000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Tarda', '#eab308', '15:30', '19:00',
   'a5000000-0000-0000-0000-000000000002', true),
  ('a6000000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Sopar', '#0ea5e9', '18:30', '23:00',
   'a5000000-0000-0000-0000-000000000004', true),
  ('a6000000-0000-0000-0000-000000000006', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Tancament', '#334155', '22:00', '00:30',
   'a5000000-0000-0000-0000-000000000001', true),
  -- Diagonal
  ('a6000000-0000-0000-0000-000000000011', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Obertura', '#64748b', '06:30', '10:00',
   'a5000000-0000-0000-0000-000000000011', true),
  ('a6000000-0000-0000-0000-000000000012', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Esmorzar', '#94a3b8', '08:00', '12:00',
   'a5000000-0000-0000-0000-000000000012', true),
  ('a6000000-0000-0000-0000-000000000013', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Dinar', '#f97316', '11:30', '16:00',
   'a5000000-0000-0000-0000-000000000011', true),
  ('a6000000-0000-0000-0000-000000000014', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Tarda', '#eab308', '15:30', '19:00',
   'a5000000-0000-0000-0000-000000000012', true),
  ('a6000000-0000-0000-0000-000000000015', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Sopar', '#0ea5e9', '18:30', '23:00',
   'a5000000-0000-0000-0000-000000000014', true),
  ('a6000000-0000-0000-0000-000000000016', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Tancament', '#334155', '22:00', '00:30',
   'a5000000-0000-0000-0000-000000000011', true)
ON CONFLICT (id) DO NOTHING;

-- Coverage: sopar + cap de setmana — cuina + expedició (pic domicili)
INSERT INTO data.coverage_demands (
  id, tenant_id, site_id, role_id, kind, day_of_week, demand_date,
  start_time, end_time, required_min, required_target, required_max,
  priority, source, name, effective_from, is_active
)
SELECT
  ('a6100000-0000-0000-0000-' || lpad(to_hex(1000 + row_number() OVER ()), 12, '0'))::uuid,
  'a1000000-0000-0000-0000-000000000001',
  s.site_id,
  r.role_id,
  'recurring',
  d.dow,
  NULL,
  '18:30'::time,
  '23:00'::time,
  r.rmin, r.rtarget, r.rmax,
  80,
  'manual',
  'Pic sopar / domicili — ' || r.rname,
  '2026-01-01'::date,
  true
FROM (VALUES
  ('a3000000-0000-0000-0000-000000000001'::uuid),
  ('a3000000-0000-0000-0000-000000000002'::uuid)
) AS s(site_id)
CROSS JOIN (VALUES
  ('a4900000-0000-0000-0000-000000000003'::uuid, 'cuina', 1, 2, 3),
  ('a4900000-0000-0000-0000-000000000005'::uuid, 'expedicio', 1, 1, 2)
) AS r(role_id, rname, rmin, rtarget, rmax)
CROSS JOIN (VALUES (5), (6), (0), (1), (2), (3), (4)) AS d(dow)
ON CONFLICT DO NOTHING;

-- Slots published: 2 setmanes ISO (dilluns actual ±)
DO $$
DECLARE
  v_monday date := date_trunc('week', (now() AT TIME ZONE 'Europe/Madrid')::date)::date;
  -- PG date_trunc('week') = Monday when DateStyle ISO
  v_d date;
  v_i int;
  v_seq int := 0;
  v_slot_id uuid;
BEGIN
  FOR v_i IN 0..13 LOOP
    v_d := v_monday + v_i;

    -- Eixample: director obertura (dl–dv), cap matí dinar, cap tarda sopar, cuina+expedició sopar
    IF EXTRACT(DOW FROM v_d) BETWEEN 1 AND 5 THEN
      v_seq := v_seq + 1;
      v_slot_id := ('a6200000-0000-4000-8000-' || lpad(to_hex(v_seq), 12, '0'))::uuid;
      INSERT INTO data.shift_slots (
        id, tenant_id, site_id, shift_id, employee_id, slot_date,
        start_time, end_time, location_id, role_id, status
      ) VALUES (
        v_slot_id, 'a1000000-0000-0000-0000-000000000001',
        'a3000000-0000-0000-0000-000000000001',
        'a6000000-0000-0000-0000-000000000001',
        'a4000000-0000-0000-0000-000000000001', v_d,
        '06:30', '10:00', 'a5000000-0000-0000-0000-000000000001',
        'a4900000-0000-0000-0000-000000000001', 'published'
      ) ON CONFLICT DO NOTHING;
    END IF;

    v_seq := v_seq + 1;
    INSERT INTO data.shift_slots (
      id, tenant_id, site_id, shift_id, employee_id, slot_date,
      start_time, end_time, location_id, role_id, status
    ) VALUES (
      ('a6200000-0000-4000-8000-' || lpad(to_hex(v_seq), 12, '0'))::uuid,
      'a1000000-0000-0000-0000-000000000001',
      'a3000000-0000-0000-0000-000000000001',
      'a6000000-0000-0000-0000-000000000003',
      'a4000000-0000-0000-0000-000000000002', v_d,
      '11:30', '16:00', 'a5000000-0000-0000-0000-000000000002',
      'a4900000-0000-0000-0000-000000000002', 'published'
    ) ON CONFLICT DO NOTHING;

    v_seq := v_seq + 1;
    INSERT INTO data.shift_slots (
      id, tenant_id, site_id, shift_id, employee_id, slot_date,
      start_time, end_time, location_id, role_id, status
    ) VALUES (
      ('a6200000-0000-4000-8000-' || lpad(to_hex(v_seq), 12, '0'))::uuid,
      'a1000000-0000-0000-0000-000000000001',
      'a3000000-0000-0000-0000-000000000001',
      'a6000000-0000-0000-0000-000000000005',
      'a4000000-0000-0000-0000-000000000003', v_d,
      '18:30', '23:00', 'a5000000-0000-0000-0000-000000000002',
      'a4900000-0000-0000-0000-000000000002', 'published'
    ) ON CONFLICT DO NOTHING;

    v_seq := v_seq + 1;
    INSERT INTO data.shift_slots (
      id, tenant_id, site_id, shift_id, employee_id, slot_date,
      start_time, end_time, location_id, role_id, status
    ) VALUES (
      ('a6200000-0000-4000-8000-' || lpad(to_hex(v_seq), 12, '0'))::uuid,
      'a1000000-0000-0000-0000-000000000001',
      'a3000000-0000-0000-0000-000000000001',
      'a6000000-0000-0000-0000-000000000005',
      'a4000000-0000-0000-0000-000000000004', v_d,
      '18:30', '23:00', 'a5000000-0000-0000-0000-000000000001',
      'a4900000-0000-0000-0000-000000000003', 'published'
    ) ON CONFLICT DO NOTHING;

    v_seq := v_seq + 1;
    INSERT INTO data.shift_slots (
      id, tenant_id, site_id, shift_id, employee_id, slot_date,
      start_time, end_time, location_id, role_id, status
    ) VALUES (
      ('a6200000-0000-4000-8000-' || lpad(to_hex(v_seq), 12, '0'))::uuid,
      'a1000000-0000-0000-0000-000000000001',
      'a3000000-0000-0000-0000-000000000001',
      'a6000000-0000-0000-0000-000000000005',
      'a4000000-0000-0000-0000-000000000007', v_d,
      '18:30', '23:00', 'a5000000-0000-0000-0000-000000000004',
      'a4900000-0000-0000-0000-000000000005', 'published'
    ) ON CONFLICT DO NOTHING;

    -- Diagonal mirror (director + cap + cuina + expedició + DT al sopar)
    IF EXTRACT(DOW FROM v_d) BETWEEN 1 AND 5 THEN
      v_seq := v_seq + 1;
      INSERT INTO data.shift_slots (
        id, tenant_id, site_id, shift_id, employee_id, slot_date,
        start_time, end_time, location_id, role_id, status
      ) VALUES (
        ('a6200000-0000-4000-8000-' || lpad(to_hex(v_seq), 12, '0'))::uuid,
        'a1000000-0000-0000-0000-000000000001',
        'a3000000-0000-0000-0000-000000000002',
        'a6000000-0000-0000-0000-000000000011',
        'a4000000-0000-0000-0000-000000000011', v_d,
        '06:30', '10:00', 'a5000000-0000-0000-0000-000000000011',
        'a4900000-0000-0000-0000-000000000001', 'published'
      ) ON CONFLICT DO NOTHING;
    END IF;

    v_seq := v_seq + 1;
    INSERT INTO data.shift_slots (
      id, tenant_id, site_id, shift_id, employee_id, slot_date,
      start_time, end_time, location_id, role_id, status
    ) VALUES (
      ('a6200000-0000-4000-8000-' || lpad(to_hex(v_seq), 12, '0'))::uuid,
      'a1000000-0000-0000-0000-000000000001',
      'a3000000-0000-0000-0000-000000000002',
      'a6000000-0000-0000-0000-000000000015',
      'a4000000-0000-0000-0000-000000000013', v_d,
      '18:30', '23:00', 'a5000000-0000-0000-0000-000000000012',
      'a4900000-0000-0000-0000-000000000002', 'published'
    ) ON CONFLICT DO NOTHING;

    v_seq := v_seq + 1;
    INSERT INTO data.shift_slots (
      id, tenant_id, site_id, shift_id, employee_id, slot_date,
      start_time, end_time, location_id, role_id, status
    ) VALUES (
      ('a6200000-0000-4000-8000-' || lpad(to_hex(v_seq), 12, '0'))::uuid,
      'a1000000-0000-0000-0000-000000000001',
      'a3000000-0000-0000-0000-000000000002',
      'a6000000-0000-0000-0000-000000000015',
      'a4000000-0000-0000-0000-000000000017', v_d,
      '18:30', '23:00', 'a5000000-0000-0000-0000-000000000014',
      'a4900000-0000-0000-0000-000000000005', 'published'
    ) ON CONFLICT DO NOTHING;

    v_seq := v_seq + 1;
    INSERT INTO data.shift_slots (
      id, tenant_id, site_id, shift_id, employee_id, slot_date,
      start_time, end_time, location_id, role_id, status
    ) VALUES (
      ('a6200000-0000-4000-8000-' || lpad(to_hex(v_seq), 12, '0'))::uuid,
      'a1000000-0000-0000-0000-000000000001',
      'a3000000-0000-0000-0000-000000000002',
      'a6000000-0000-0000-0000-000000000015',
      'a4000000-0000-0000-0000-000000000018', v_d,
      '18:30', '23:00', 'a5000000-0000-0000-0000-000000000016',
      'a4900000-0000-0000-0000-000000000007', 'published'
    ) ON CONFLICT DO NOTHING;
  END LOOP;
END $$;

-- Opening mostra (Eixample sopar expedició)
INSERT INTO data.shift_openings (
  id, tenant_id, site_id, location_id, role_id, shift_id, opening_date,
  start_time, end_time, places_total, places_filled, claim_policy, status, title
)
VALUES (
  'a6300000-0000-0000-0000-000000000001',
  'a1000000-0000-0000-0000-000000000001',
  'a3000000-0000-0000-0000-000000000001',
  'a5000000-0000-0000-0000-000000000004',
  'a4900000-0000-0000-0000-000000000005',
  'a6000000-0000-0000-0000-000000000005',
  (date_trunc('week', (now() AT TIME ZONE 'Europe/Madrid')::date)::date + 5),
  '18:30', '23:00', 1, 0, 'manager_approval', 'open',
  'Reforç expedició divendres (pic apps)'
)
ON CONFLICT (id) DO NOTHING;
