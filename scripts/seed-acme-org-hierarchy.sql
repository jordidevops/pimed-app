-- =============================================================================
-- Seed opcional: jerarquia de reporting Acme Corp (demo organigrama)
-- =============================================================================
-- Ús (SQL Editor / psql, amb DB ja seedada):
--   \i scripts/seed-acme-org-hierarchy.sql
--
-- Idempotent: neteja managers d’Acme i torna a assignar l’arbre.
-- Gràcia  = 30000000-0000-0000-0000-000000000001
-- Sants   = 30000000-0000-0000-0000-000000000002
-- Alice   = 40000000-0000-0000-0000-000000000001  (arrel Gràcia)
-- Caterina= 40000000-0000-0000-0000-000000000034  (arrel Sants)
-- =============================================================================

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice uuid := '40000000-0000-0000-0000-000000000001';
  v_marta uuid := '40000000-0000-0000-0000-000000000012';
  v_julia uuid := '40000000-0000-0000-0000-000000000015';
  v_josep uuid := '40000000-0000-0000-0000-000000000025';
  v_laia uuid := '40000000-0000-0000-0000-000000000008';
  v_caterina uuid := '40000000-0000-0000-0000-000000000034';
  v_angels uuid := '40000000-0000-0000-0000-000000000040';
  v_gloria uuid := '40000000-0000-0000-0000-000000000032';
BEGIN
  -- Neteja (evita cicles en reassignar)
  UPDATE data.employees
  SET manager_employee_id = NULL
  WHERE tenant_id = v_tenant
    AND id::text LIKE '40000000-0000-0000-0000-%';

  -- ── Gràcia: Alice (Manager) ───────────────────────────────────────────────
  UPDATE data.employees SET manager_employee_id = v_alice
  WHERE id IN (
    '40000000-0000-0000-0000-000000000002', -- Charlie
    '40000000-0000-0000-0000-000000000003', -- Dave
    v_marta, v_julia, v_josep, v_laia
  );

  -- Equip Marta (Cap d'obra)
  UPDATE data.employees SET manager_employee_id = v_marta
  WHERE id IN (
    '40000000-0000-0000-0000-000000000009',
    '40000000-0000-0000-0000-000000000011',
    '40000000-0000-0000-0000-000000000013',
    '40000000-0000-0000-0000-000000000014',
    '40000000-0000-0000-0000-000000000016',
    '40000000-0000-0000-0000-000000000023'
  );

  -- Equip Júlia (Encarregada)
  UPDATE data.employees SET manager_employee_id = v_julia
  WHERE id IN (
    '40000000-0000-0000-0000-000000000005',
    '40000000-0000-0000-0000-000000000006',
    '40000000-0000-0000-0000-000000000007',
    '40000000-0000-0000-0000-000000000017',
    '40000000-0000-0000-0000-000000000019',
    '40000000-0000-0000-0000-000000000020'
  );

  -- Equip Josep (Cap d'obra)
  UPDATE data.employees SET manager_employee_id = v_josep
  WHERE id IN (
    '40000000-0000-0000-0000-000000000021',
    '40000000-0000-0000-0000-000000000027',
    '40000000-0000-0000-0000-000000000028',
    '40000000-0000-0000-0000-000000000029',
    '40000000-0000-0000-0000-000000000030'
  );

  -- Equip Laia (Administració)
  UPDATE data.employees SET manager_employee_id = v_laia
  WHERE id IN (
    '40000000-0000-0000-0000-000000000010',
    '40000000-0000-0000-0000-000000000018',
    '40000000-0000-0000-0000-000000000022',
    '40000000-0000-0000-0000-000000000024',
    '40000000-0000-0000-0000-000000000026'
  );

  -- ── Sants: Caterina (Cap d'obra) ──────────────────────────────────────────
  UPDATE data.employees SET manager_employee_id = v_caterina
  WHERE id IN (
    v_angels,
    v_gloria,
    '40000000-0000-0000-0000-000000000031',
    '40000000-0000-0000-0000-000000000033',
    '40000000-0000-0000-0000-000000000035',
    '40000000-0000-0000-0000-000000000043',
    '40000000-0000-0000-0000-000000000047'
  );

  -- Equip Àngels (Encarregada)
  UPDATE data.employees SET manager_employee_id = v_angels
  WHERE id IN (
    '40000000-0000-0000-0000-000000000037',
    '40000000-0000-0000-0000-000000000039',
    '40000000-0000-0000-0000-000000000041',
    '40000000-0000-0000-0000-000000000042',
    '40000000-0000-0000-0000-000000000044',
    '40000000-0000-0000-0000-000000000045',
    '40000000-0000-0000-0000-000000000046',
    '40000000-0000-0000-0000-000000000049'
  );

  -- Equip Glòria (Administració)
  UPDATE data.employees SET manager_employee_id = v_gloria
  WHERE id IN (
    '40000000-0000-0000-0000-000000000036',
    '40000000-0000-0000-0000-000000000038',
    '40000000-0000-0000-0000-000000000048'
  );

  -- Segona línia Sants: Núria Vidal (Cap d'obra) com a arrel addicional
  -- (manager NULL — queda com a segona arrel del centre)

  RAISE NOTICE 'Acme org hierarchy seeded (Alice@Gràcia, Caterina+Núria@Sants).';
END $$;
