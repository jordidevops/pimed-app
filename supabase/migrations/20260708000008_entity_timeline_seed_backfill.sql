-- =============================================================================
-- Entity Timeline — backfill risk rules + playbooks per tenants existents
-- (les migracions 080001/080002 sembraven abans del seed.sql local)
-- =============================================================================

SELECT data.seed_entity_risk_rules_for_tenant(t.id)
FROM data.tenants t;

SELECT data.seed_employee_termination_playbooks(t.id)
FROM data.tenants t;
