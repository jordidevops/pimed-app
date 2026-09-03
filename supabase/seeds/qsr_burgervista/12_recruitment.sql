-- =============================================================================
-- 12 — Recruitment: feature flag, settings, postings, applicants, applications
-- =============================================================================
-- IDs: a82… (postings/apps), uses public_sites a800… and job_positions a410…
-- Tenant: a1000000-0000-0000-0000-000000000001 (BurgerVista)

INSERT INTO data.tenant_feature_overrides (tenant_id, feature_key, override_status)
VALUES (
  'a1000000-0000-0000-0000-000000000001',
  'recruitment_enabled',
  true
)
ON CONFLICT (tenant_id, feature_key) DO UPDATE
SET override_status = EXCLUDED.override_status;

INSERT INTO data.recruitment_settings (
  tenant_id,
  default_max_retention_months,
  privacy_policy_url,
  rights_sla_days,
  rejection_notify_policy,
  import_legal_basis
)
VALUES (
  'a1000000-0000-0000-0000-000000000001',
  12,
  'https://burgervista.demo/privacitat',
  30,
  'on_decision',
  'legitimate_interest'
)
ON CONFLICT (tenant_id) DO UPDATE
SET
  privacy_policy_url = EXCLUDED.privacy_policy_url,
  updated_at = now();

-- Ensure default pipeline stages exist (trigger also runs on settings insert)
SELECT data.seed_default_pipeline_stages('a1000000-0000-0000-0000-000000000001');

-- Postings (draft first, then link sites, then publish)
INSERT INTO data.job_postings (
  id, tenant_id, site_id, job_position_id, title, description, public_slug, status, created_by
)
VALUES
  (
    'a8200000-0000-0000-0000-000000000001',
    'a1000000-0000-0000-0000-000000000001',
    'a3000000-0000-0000-0000-000000000001',
    'a4100000-0000-0000-0000-000000000007',
    'Cuiner/a grill — Eixample',
    'Busquem cuiner/a de grill per torns de migdia i vespre. Experiència en QSR valorada.',
    'cuiner-grill-eixample',
    'draft',
    'a2000000-0000-0000-0000-000000000001'
  ),
  (
    'a8200000-0000-0000-0000-000000000002',
    'a1000000-0000-0000-0000-000000000001',
    'a3000000-0000-0000-0000-000000000001',
    'a4100000-0000-0000-0000-000000000009',
    'Mostrador / caixa — Eixample',
    'Atenció al client, caixa i preparació de comandes. Horari flexible.',
    'mostrador-eixample',
    'draft',
    'a2000000-0000-0000-0000-000000000001'
  ),
  (
    'a8200000-0000-0000-0000-000000000003',
    'a1000000-0000-0000-0000-000000000001',
    'a3000000-0000-0000-0000-000000000002',
    'a4100000-0000-0000-0000-000000000010',
    'Expedició / domicili — Diagonal',
    'Preparació i entrega de comandes a domicili. Carnet B valorat.',
    'expedicio-diagonal',
    'draft',
    'a2000000-0000-0000-0000-000000000001'
  ),
  (
    'a8200000-0000-0000-0000-000000000004',
    'a1000000-0000-0000-0000-000000000001',
    NULL,
    'a4100000-0000-0000-0000-000000000013',
    'Suport floater (esborrany)',
    'Oferta en preparació — encara no publicada.',
    'floater-borrador',
    'draft',
    'a2000000-0000-0000-0000-000000000001'
  )
ON CONFLICT (id) DO UPDATE SET
  title = EXCLUDED.title,
  description = EXCLUDED.description,
  job_position_id = EXCLUDED.job_position_id;

INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
VALUES
  ('a8200000-0000-0000-0000-000000000001', 'a8000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001'),
  ('a8200000-0000-0000-0000-000000000002', 'a8000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001'),
  ('a8200000-0000-0000-0000-000000000003', 'a8000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001')
ON CONFLICT DO NOTHING;

UPDATE data.job_postings
SET status = 'published', updated_at = now()
WHERE id IN (
  'a8200000-0000-0000-0000-000000000001',
  'a8200000-0000-0000-0000-000000000002',
  'a8200000-0000-0000-0000-000000000003'
)
AND tenant_id = 'a1000000-0000-0000-0000-000000000001';

-- Applicants
INSERT INTO data.applicants (
  id, tenant_id, email, full_name, phone, email_verified_at
)
VALUES
  ('a8210000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'aina.grill@example.com', 'Aina Martí', '+34611100001', now() - interval '5 days'),
  ('a8210000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001', 'pol.cuina@example.com', 'Pol Serra', '+34611100002', now() - interval '4 days'),
  ('a8210000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001', 'laia.counter@example.com', 'Laia Puig', '+34611100003', now() - interval '3 days'),
  ('a8210000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000001', 'oriol.caixa@example.com', 'Oriol Domènech', NULL, now() - interval '2 days'),
  ('a8210000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000001', 'marta.delivery@example.com', 'Marta Riera', '+34611100005', now() - interval '6 days'),
  ('a8210000-0000-0000-0000-000000000006', 'a1000000-0000-0000-0000-000000000001', 'jan.bike@example.com', 'Jan Costa', '+34611100006', now() - interval '1 day'),
  ('a8210000-0000-0000-0000-000000000007', 'a1000000-0000-0000-0000-000000000001', 'nina.sala@example.com', 'Nina Valls', '+34611100007', now() - interval '8 days'),
  ('a8210000-0000-0000-0000-000000000008', 'a1000000-0000-0000-0000-000000000001', 'eric.prep@example.com', 'Èric Font', NULL, now() - interval '10 days'),
  ('a8210000-0000-0000-0000-000000000009', 'a1000000-0000-0000-0000-000000000001', 'sofia.wa@example.com', 'Sofia Navarro', '+34611100009', now() - interval '12 hours'),
  ('a8210000-0000-0000-0000-000000000010', 'a1000000-0000-0000-0000-000000000001', 'toni.qr@example.com', 'Toni Alsina', '+34611100010', now() - interval '7 days')
ON CONFLICT (id) DO NOTHING;

-- Applications across stages (tenant default stage names)
DO $$
DECLARE
  v_tenant uuid := 'a1000000-0000-0000-0000-000000000001';
  v_rebut uuid;
  v_revisio uuid;
  v_entrevista uuid;
  v_oferta uuid;
  v_descart uuid;
BEGIN
  SELECT id INTO v_rebut FROM data.pipeline_stages
  WHERE tenant_id = v_tenant AND job_posting_id IS NULL AND name = 'Rebut' LIMIT 1;
  SELECT id INTO v_revisio FROM data.pipeline_stages
  WHERE tenant_id = v_tenant AND job_posting_id IS NULL AND name = 'En revisió' LIMIT 1;
  SELECT id INTO v_entrevista FROM data.pipeline_stages
  WHERE tenant_id = v_tenant AND job_posting_id IS NULL AND name = 'Entrevista' LIMIT 1;
  SELECT id INTO v_oferta FROM data.pipeline_stages
  WHERE tenant_id = v_tenant AND job_posting_id IS NULL AND name = 'Oferta' LIMIT 1;
  SELECT id INTO v_descart FROM data.pipeline_stages
  WHERE tenant_id = v_tenant AND job_posting_id IS NULL AND name = 'Descart' LIMIT 1;

  INSERT INTO data.applications (
    id, tenant_id, job_posting_id, applicant_id, stage_id,
    retention_preference, retention_months, purge_at, source, created_at
  )
  VALUES
    ('a8220000-0000-0000-0000-000000000001', v_tenant, 'a8200000-0000-0000-0000-000000000001',
     'a8210000-0000-0000-0000-000000000001', v_rebut,
     'delete_after_months', 6, now() + interval '6 months', 'web', now() - interval '5 days'),
    ('a8220000-0000-0000-0000-000000000002', v_tenant, 'a8200000-0000-0000-0000-000000000001',
     'a8210000-0000-0000-0000-000000000002', v_revisio,
     'delete_after_months', 6, now() + interval '6 months', 'qr', now() - interval '4 days'),
    ('a8220000-0000-0000-0000-000000000003', v_tenant, 'a8200000-0000-0000-0000-000000000001',
     'a8210000-0000-0000-0000-000000000008', v_entrevista,
     'delete_on_process_end', NULL, now() + interval '12 months', 'web', now() - interval '10 days'),
    ('a8220000-0000-0000-0000-000000000004', v_tenant, 'a8200000-0000-0000-0000-000000000002',
     'a8210000-0000-0000-0000-000000000003', v_rebut,
     'delete_after_months', 6, now() + interval '6 months', 'whatsapp', now() - interval '3 days'),
    ('a8220000-0000-0000-0000-000000000005', v_tenant, 'a8200000-0000-0000-0000-000000000002',
     'a8210000-0000-0000-0000-000000000004', v_entrevista,
     'delete_after_months', 6, now() + interval '6 months', 'web', now() - interval '2 days'),
    ('a8220000-0000-0000-0000-000000000006', v_tenant, 'a8200000-0000-0000-0000-000000000002',
     'a8210000-0000-0000-0000-000000000009', v_revisio,
     'delete_after_months', 6, now() + interval '6 months', 'whatsapp', now() - interval '12 hours'),
    ('a8220000-0000-0000-0000-000000000007', v_tenant, 'a8200000-0000-0000-0000-000000000003',
     'a8210000-0000-0000-0000-000000000005', v_oferta,
     'delete_after_months', 6, now() + interval '6 months', 'web', now() - interval '6 days'),
    ('a8220000-0000-0000-0000-000000000008', v_tenant, 'a8200000-0000-0000-0000-000000000003',
     'a8210000-0000-0000-0000-000000000006', v_rebut,
     'delete_after_months', 6, now() + interval '6 months', 'manual', now() - interval '1 day'),
    ('a8220000-0000-0000-0000-000000000009', v_tenant, 'a8200000-0000-0000-0000-000000000003',
     'a8210000-0000-0000-0000-000000000007', v_descart,
     'delete_on_process_end', NULL, now() + interval '30 days', 'web', now() - interval '8 days'),
    ('a8220000-0000-0000-0000-000000000010', v_tenant, 'a8200000-0000-0000-0000-000000000001',
     'a8210000-0000-0000-0000-000000000010', v_rebut,
     'delete_after_months', 6, now() + interval '6 months', 'qr', now() - interval '7 days')
  ON CONFLICT (id) DO NOTHING;
END $$;

DO $$
BEGIN
  RAISE NOTICE 'BurgerVista recruitment seed OK: 3 live postings + 1 draft, 10 applications';
END $$;
