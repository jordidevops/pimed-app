# Smoke EHR fixtures — README

Arxius opcionals per proves manuals del mòdul Empleats (no formen part de `db reset`).

| Fitxer | Ús |
|--------|-----|
| [`smoke_ehr_employees_fixtures.sql`](./smoke_ehr_employees_fixtures.sql) | Enganxar a **SQL Editor** (o `psql`) després del seed |
| [`smoke_ehr_employees_fixtures_cleanup.sql`](./smoke_ehr_employees_fixtures_cleanup.sql) | Esborra només UUID `e1000000-…` |
| [`smoke_ehr_import_sample.csv`](./smoke_ehr_import_sample.csv) | UAT import CSV (1 create + 1 update Alice) |

**Checklist:** [`docs/plans/employees/ehr-uat-checklist.md`](../../docs/plans/employees/ehr-uat-checklist.md)

## Com executar (local)

1. Migracions + seed aplicats (`supabase db reset` o stack Docker en marxa).
2. Supabase Studio → SQL Editor → enganxa `smoke_ehr_employees_fixtures.sql` → Run.
3. Mira la taula final de verificació (`alice_certs=2`, `qa_smoke_employee=1`, …).
4. Login `alice@acme-corp.com` / `Test1234!` → `/employees` → cerca `QA Smoke`.

## Identificadors útils

- QA Smoke Employee: `e1000000-0000-0000-0000-000000000001`
- QA Offboard Employee: `e1000000-0000-0000-0000-000000000002`
- QA Beta Employee: `e1000000-0000-0000-0000-000000000003`
- Alice seed: `40000000-0000-0000-0000-000000000001` (certs tech + medical)
