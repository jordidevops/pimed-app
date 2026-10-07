# F9 EXPLAIN notes (CF-28)

> **Estat:** metodologia + mini + **medium** ANALYZE locals. Gate F / SLO staging / full §9.2 **oberts**.  
> Throughput poll/reconcile: veure `08-fase-docuseal.md` (tall escala 2026-10-07).

## Com executar

1. Generar seed: `node scripts/commercial-f9-scale-seed.mjs --profile mini|medium --out scripts/out/f9-<profile>.sql`
2. Aplicar a DB descartable (no seeds normals).
3. Executar: `psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f scripts/commercial-f9-explain.sql`
4. Enganxar conclusions a «Resultats en viu».

Perfil `full` (§9.2): només staging; no commitar l’SQL generat.

## Queries §9.3 — plantilles i índexs esperats

| # | Query | Objectiu / índex esperat |
|---|--------|-------------------------|
| 1 | Request a fitxa comercial | `uq_cdr_open_document` |
| 2 | Pendents tenant | `idx_cdr_tenant_open_created` (partial `status=open`) |
| 3 | Pendents portal compte | `idx_cdr_tenant_client_status` |
| 4 | Llista portal quotes/agreements | `idx_commercial_documents_portal_quotes` / sales client indexes |
| 5 | Llista DN | sales DN indexes |
| 6 | Llista factures | sales invoice indexes |
| 7 | Detall factura + allocations | joins scoped |
| 8 | Lookup token hash | `idx_cdat_active_hash` / unique hash |
| 9 | Job expiry batch | `idx_cdr_open_expires` |
| 10 | Ops metrics proxy | `commercial_ops_metric_events` |

## Gate (buffers/plans)

Acceptable sense SLO p95 de staging:

- Cap Seq Scan **global** en llistes scoped (filtre `tenant_id` / account).
- Files llegides proporcionals a `LIMIT`/pàgina, no al catàleg sencer del tenant gran.
- Equality columns abans del cursor al pla.
- Sense `OFFSET` profund als list RPCs (keyset).

**Sense evidència ANALYZE, no afegir índexos.**

## Resultats en viu

### Mini (2026-10-07)

Entorn: local Docker `supabase_db_cavalle-app`, seed **mini** (200 docs / 200 requests). Log: `scripts/out/commercial-f9-explain-mini.log` (no commit).

| Query | Conclusió |
|-------|-----------|
| Q1–Q10 | Acceptable a volum petit; Q2/Q4 seq per taula petita |

### Medium (2026-10-07)

Entorn: mateix Docker, seed **medium** (5k docs / 5k requests + 20 small tenants). Log: `scripts/out/commercial-f9-explain-medium.log` (no commit).

| Query | Conclusió | Data |
|-------|-----------|------|
| Q1 | Index `uq_cdr_open_document` | 2026-10-07 |
| Q2 | **Abans:** Seq Scan ~4052 open rows per LIMIT 50. **Després** `00013` `idx_cdr_tenant_open_created`: Index Scan, buffers ~LIMIT | 2026-10-07 |
| Q3 | Index Only Scan `idx_cdr_tenant_client_status` | 2026-10-07 |
| Q4 | Seq Scan ~5k tenant+client (planner a medium; index portal_quotes existeix; sense nou índex especulatiu) | 2026-10-07 |
| Q5–Q7 | Indexes sales / nested loop; volum baix DN/invoice al seed | 2026-10-07 |
| Q8 | Seq Scan taula tokens buida | 2026-10-07 |
| Q9 | Index `idx_cdr_open_expires` | 2026-10-07 |
| Q10 | Seq Scan mètriques ~1 fila | 2026-10-07 |

Índex afegit: [`20261229000013_commercial_f9_scale_medium_indexes.sql`](../../../supabase/migrations/20261229000013_commercial_f9_scale_medium_indexes.sql).

## Residual

- SLO p95 (§9.4) sense staging comparable.
- Perfil full 100k+ sense màquina dedicada.
- UAT 9xxx / Gate F global obert.
- Q4 a medium encara pot seq-scan; reavaluar amb `full` abans de més índexs.
- Poll/reconcile throughput: mitigat (veure `08-fase-docuseal.md`); no és DoD d’aquest document EXPLAIN.
