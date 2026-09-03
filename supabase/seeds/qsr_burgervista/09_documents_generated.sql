-- =============================================================================
-- 09 — Documents generats des de plantilles + assignacions portal
-- =============================================================================

INSERT INTO data.documents (
  id, tenant_id, site_id, title, entity_type, entity_id, required_permissions
)
VALUES
  -- Entregues uniforme
  ('a7200000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Entrega uniforme — Irene Gómez',
   'employee', 'a4000000-0000-0000-0000-000000000007', '{}'),
  ('a7200000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Entrega uniforme — Marc Vidal',
   'employee', 'a4000000-0000-0000-0000-000000000004', '{}'),
  ('a7200000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Entrega uniforme — Oriol Font',
   'employee', 'a4000000-0000-0000-0000-000000000017', '{}'),
  ('a7200000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Entrega uniforme — Adrià Serra',
   'employee', 'a4000000-0000-0000-0000-000000000018', '{}'),
  -- Formacions
  ('a7200000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Formació higiene — Marc Vidal',
   'employee', 'a4000000-0000-0000-0000-000000000004', '{}'),
  ('a7200000-0000-0000-0000-000000000006', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Formació higiene — Irene Gómez',
   'employee', 'a4000000-0000-0000-0000-000000000007', '{}'),
  ('a7200000-0000-0000-0000-000000000007', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Formació higiene — Patricia Gil',
   'employee', 'a4000000-0000-0000-0000-000000000014', '{}'),
  -- Protocol (tenant-wide doc)
  ('a7200000-0000-0000-0000-000000000010', 'a1000000-0000-0000-0000-000000000001',
   NULL, 'Protocol registre horari BurgerVista 2026',
   NULL, NULL, '{}'),
  -- Checklists setmana
  ('a7200000-0000-0000-0000-000000000011', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Checklist obertura — Eixample (setmana actual)',
   'site', 'a3000000-0000-0000-0000-000000000001', '{}'),
  ('a7200000-0000-0000-0000-000000000012', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Checklist tancament — Diagonal (setmana actual)',
   'site', 'a3000000-0000-0000-0000-000000000002', '{}'),
  ('a7200000-0000-0000-0000-000000000013', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Checklist expedició — Eixample',
   'site', 'a3000000-0000-0000-0000-000000000001', '{}'),
  -- Acollida
  ('a7200000-0000-0000-0000-000000000014', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Acollida — Alex Muñoz',
   'employee', 'a4000000-0000-0000-0000-000000000009', '{}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.document_versions (
  id, document_id, version_number, storage_type, file_path_or_url, mime_type, size_bytes, created_by
)
VALUES
  ('a7300000-0000-0000-0000-000000000001', 'a7200000-0000-0000-0000-000000000001', 1,
   'external_link', 'seed://burgervista/uniforme-irene.html', 'text/html', 1200,
   'a2000000-0000-0000-0000-000000000004'),
  ('a7300000-0000-0000-0000-000000000002', 'a7200000-0000-0000-0000-000000000002', 1,
   'external_link', 'seed://burgervista/uniforme-marc.html', 'text/html', 1100,
   'a2000000-0000-0000-0000-000000000004'),
  ('a7300000-0000-0000-0000-000000000003', 'a7200000-0000-0000-0000-000000000003', 1,
   'external_link', 'seed://burgervista/uniforme-oriol.html', 'text/html', 1100,
   'a2000000-0000-0000-0000-000000000006'),
  ('a7300000-0000-0000-0000-000000000004', 'a7200000-0000-0000-0000-000000000004', 1,
   'external_link', 'seed://burgervista/uniforme-adria.html', 'text/html', 1100,
   'a2000000-0000-0000-0000-000000000006'),
  ('a7300000-0000-0000-0000-000000000005', 'a7200000-0000-0000-0000-000000000005', 1,
   'external_link', 'seed://burgervista/formacio-marc.html', 'text/html', 900,
   'a2000000-0000-0000-0000-000000000004'),
  ('a7300000-0000-0000-0000-000000000006', 'a7200000-0000-0000-0000-000000000006', 1,
   'external_link', 'seed://burgervista/formacio-irene.html', 'text/html', 900,
   'a2000000-0000-0000-0000-000000000004'),
  ('a7300000-0000-0000-0000-000000000007', 'a7200000-0000-0000-0000-000000000007', 1,
   'external_link', 'seed://burgervista/formacio-patricia.html', 'text/html', 900,
   'a2000000-0000-0000-0000-000000000006'),
  ('a7300000-0000-0000-0000-000000000010', 'a7200000-0000-0000-0000-000000000010', 1,
   'external_link', 'seed://burgervista/protocol-horari-2026.html', 'text/html', 2000,
   'a2000000-0000-0000-0000-000000000001'),
  ('a7300000-0000-0000-0000-000000000011', 'a7200000-0000-0000-0000-000000000011', 1,
   'external_link', 'seed://burgervista/checklist-obertura-eixample.html', 'text/html', 800,
   'a2000000-0000-0000-0000-000000000005'),
  ('a7300000-0000-0000-0000-000000000012', 'a7200000-0000-0000-0000-000000000012', 1,
   'external_link', 'seed://burgervista/checklist-tancament-diagonal.html', 'text/html', 800,
   'a2000000-0000-0000-0000-000000000007'),
  ('a7300000-0000-0000-0000-000000000013', 'a7200000-0000-0000-0000-000000000013', 1,
   'external_link', 'seed://burgervista/checklist-expedicio.html', 'text/html', 700,
   'a2000000-0000-0000-0000-000000000005'),
  ('a7300000-0000-0000-0000-000000000014', 'a7200000-0000-0000-0000-000000000014', 1,
   'external_link', 'seed://burgervista/acollida-alex.html', 'text/html', 600,
   'a2000000-0000-0000-0000-000000000004')
ON CONFLICT (id) DO NOTHING;

-- Protocol assignat a empleats de local (mostra)
INSERT INTO data.employee_portal_document_assignments (
  id, tenant_id, employee_id, assignment_kind, document_version_id, published_at, published_by
)
SELECT
  ('a7400000-0000-0000-0000-' || lpad(to_hex(1000 + row_number() OVER (ORDER BY e.id)), 12, '0'))::uuid,
  'a1000000-0000-0000-0000-000000000001',
  e.id,
  'attendance_protocol',
  'a7300000-0000-0000-0000-000000000010',
  now() - interval '30 days',
  'a2000000-0000-0000-0000-000000000001'
FROM data.employees e
WHERE e.tenant_id = 'a1000000-0000-0000-0000-000000000001'
  AND e.site_id IS NOT NULL
  AND e.status = 'active'
ON CONFLICT (employee_id, document_version_id) DO NOTHING;

-- Formació assignada a cuina/expedició
INSERT INTO data.employee_portal_document_assignments (
  id, tenant_id, employee_id, assignment_kind, document_version_id, published_at, published_by, acknowledged_at
)
VALUES
  ('a7400000-0000-0000-0000-000000000201', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000004', 'onboarding',
   'a7300000-0000-0000-0000-000000000005', now() - interval '20 days',
   'a2000000-0000-0000-0000-000000000004', now() - interval '19 days'),
  ('a7400000-0000-0000-0000-000000000202', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000007', 'onboarding',
   'a7300000-0000-0000-0000-000000000006', now() - interval '20 days',
   'a2000000-0000-0000-0000-000000000004', now() - interval '18 days'),
  ('a7400000-0000-0000-0000-000000000203', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000014', 'onboarding',
   'a7300000-0000-0000-0000-000000000007', now() - interval '15 days',
   'a2000000-0000-0000-0000-000000000006', now() - interval '14 days')
ON CONFLICT (employee_id, document_version_id) DO NOTHING;
