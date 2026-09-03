-- =============================================================================
-- 10 — Portals públics per local + tokens portal empleat
-- =============================================================================

INSERT INTO data.public_sites (id, tenant_id, site_id, slug, name, status)
VALUES
  (
    'a8000000-0000-0000-0000-000000000001',
    'a1000000-0000-0000-0000-000000000001',
    'a3000000-0000-0000-0000-000000000001',
    'burgervista-eixample',
    'BurgerVista Eixample — Portal',
    'published'
  ),
  (
    'a8000000-0000-0000-0000-000000000002',
    'a1000000-0000-0000-0000-000000000001',
    'a3000000-0000-0000-0000-000000000002',
    'burgervista-diagonal',
    'BurgerVista Diagonal — Portal',
    'published'
  )
ON CONFLICT (id) DO UPDATE SET
  status = EXCLUDED.status,
  slug = EXCLUDED.slug,
  name = EXCLUDED.name;

-- Tokens portal (hash SHA-256 del secret en clar documentat al README)
INSERT INTO data.employee_portal_tokens (
  id, tenant_id, employee_id, token_hash, label, is_active, pin_hash, pin_must_set
)
VALUES
  ('a8100000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000001', digest('ep0-dev-bv-laura', 'sha256'),
   'Dev Laura', true, data.hash_employee_portal_pin('1234'), false),
  ('a8100000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000002', digest('ep0-dev-bv-pau', 'sha256'),
   'Dev Pau', true, data.hash_employee_portal_pin('1234'), false),
  ('a8100000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000007', digest('ep0-dev-bv-irene', 'sha256'),
   'Dev Irene expedició', true, data.hash_employee_portal_pin('1234'), false),
  ('a8100000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000011', digest('ep0-dev-bv-elena', 'sha256'),
   'Dev Elena', true, data.hash_employee_portal_pin('1234'), false),
  ('a8100000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000017', digest('ep0-dev-bv-oriol', 'sha256'),
   'Dev Oriol expedició', true, data.hash_employee_portal_pin('1234'), false),
  ('a8100000-0000-0000-0000-000000000006', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000004', digest('ep0-dev-bv-marc-vidal', 'sha256'),
   'Dev Marc cuina', true, data.hash_employee_portal_pin('1234'), false)
ON CONFLICT (id) DO NOTHING;

-- Sanity final
DO $$
DECLARE
  v_sites int;
  v_emps int;
  v_locs int;
BEGIN
  SELECT count(*) INTO v_sites FROM data.sites
  WHERE tenant_id = 'a1000000-0000-0000-0000-000000000001';
  SELECT count(*) INTO v_emps FROM data.employees
  WHERE tenant_id = 'a1000000-0000-0000-0000-000000000001' AND site_id IS NOT NULL;
  SELECT count(*) INTO v_locs FROM data.locations
  WHERE tenant_id = 'a1000000-0000-0000-0000-000000000001'
    AND metadata->>'channel' = 'delivery';

  RAISE NOTICE 'BurgerVista seed OK: sites=%, employees_local=%, delivery_zones=%',
    v_sites, v_emps, v_locs;

  IF v_sites < 2 OR v_emps < 20 OR v_locs < 2 THEN
    RAISE WARNING 'Seed BurgerVista incomplet (sites=%, emps=%, delivery_zones=%)',
      v_sites, v_emps, v_locs;
  END IF;
END $$;
