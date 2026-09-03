-- =============================================================================
-- Cleanup — smoke_ehr_employees_fixtures.sql
-- =============================================================================
-- Esborra NOMÉS files amb prefix UUID e1000000-… / e4100000-… (posicions QA)
-- No toca seed Alice/Charlie ni altres dades.
-- =============================================================================

BEGIN;

DELETE FROM data.employee_asset_return_checklist_items
WHERE checklist_id IN (
  SELECT id FROM data.employee_asset_return_checklists
  WHERE employee_id IN (
    'e1000000-0000-0000-0000-000000000001',
    'e1000000-0000-0000-0000-000000000002',
    'e1000000-0000-0000-0000-000000000003'
  )
);

DELETE FROM data.employee_asset_return_checklists
WHERE employee_id IN (
  'e1000000-0000-0000-0000-000000000001',
  'e1000000-0000-0000-0000-000000000002',
  'e1000000-0000-0000-0000-000000000003'
);

DELETE FROM data.employee_asset_assignments
WHERE id IN (
  'e1000000-0000-0000-0000-000000000031',
  'e1000000-0000-0000-0000-000000000032'
);

DELETE FROM data.assets
WHERE id IN (
  'e1000000-0000-0000-0000-000000000021',
  'e1000000-0000-0000-0000-000000000022'
);

DELETE FROM data.employment_contract_notice_log
WHERE contract_id IN (
  'e1000000-0000-0000-0000-000000000011',
  'e1000000-0000-0000-0000-000000000012',
  'e1000000-0000-0000-0000-000000000013'
);

DELETE FROM data.employment_contracts
WHERE id IN (
  'e1000000-0000-0000-0000-000000000011',
  'e1000000-0000-0000-0000-000000000012',
  'e1000000-0000-0000-0000-000000000013'
);

DELETE FROM data.employee_certifications
WHERE id IN (
  'e1000000-0000-0000-0000-000000000051',
  'e1000000-0000-0000-0000-000000000052'
);

DELETE FROM data.compliance_requirement_rules
WHERE id IN (
  'e1000000-0000-0000-0000-000000000041',
  'e1000000-0000-0000-0000-000000000042'
);

DELETE FROM data.employee_skills
WHERE id = 'e1000000-0000-0000-0000-000000000064';

DELETE FROM data.skills
WHERE id = 'e1000000-0000-0000-0000-000000000062';

DELETE FROM data.skill_levels
WHERE id = 'e1000000-0000-0000-0000-000000000063';

DELETE FROM data.skill_types
WHERE id = 'e1000000-0000-0000-0000-000000000061';

DELETE FROM data.employee_lifecycle_events
WHERE employee_id IN (
  'e1000000-0000-0000-0000-000000000001',
  'e1000000-0000-0000-0000-000000000002',
  'e1000000-0000-0000-0000-000000000003'
);

DELETE FROM data.employees
WHERE id IN (
  'e1000000-0000-0000-0000-000000000001',
  'e1000000-0000-0000-0000-000000000002',
  'e1000000-0000-0000-0000-000000000003'
);

DELETE FROM data.job_positions
WHERE id IN (
  'e4100000-0000-0000-0000-000000000001',
  'e4100000-0000-0000-0000-000000000002',
  'e4100000-0000-0000-0000-000000000003'
);

COMMIT;

SELECT 'cleanup_done' AS status, now() AS at;
