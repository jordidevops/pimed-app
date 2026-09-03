# AI Chat Orphan Cleanup Runbook

Runbook operatiu per al cleanup TTL d'adjunts `source = 'ai-chat'` i per al control de quota de storage.

## Scope

- Cleanup principal: `data.run_ai_chat_orphan_cleanup_logged(...)`
- Servei (service_role): `api.run_ai_chat_orphan_cleanup_service(...)`
- Reconciliacio quota (service_role): `api.reconcile_storage_usage_service(...)`
- Observabilitat: `data.ai_chat_orphan_cleanup_runs`

## Preconditions

- Aplicades migracions:
  - `20260701000001_ai_chat_attachment_refs_m1.sql`
  - `20260701000002_ai_chat_orphan_cleanup_hardening_m2.sql`
  - `20260701000003_ai_chat_cleanup_observability_reconcile_m3.sql`
- `pg_cron` disponible al projecte cloud.
- Execucio de consultes amb rol operatiu (`service_role`) quan calgui executar RPC.

## Query Pack

### 1) Backlog actual d'orfes TTL

```sql
SELECT COUNT(*) AS orphan_backlog
FROM data.file_nodes fn
WHERE fn.node_type = 'file'
  AND fn.is_deleted = false
  AND fn.processing_status = 'done'
  AND COALESCE(fn.metadata ->> 'source', '') = 'ai-chat'
  AND fn.created_at < now() - interval '90 days'
  AND NOT EXISTS (
    SELECT 1
    FROM data.ai_message_file_refs ref
    JOIN data.ai_conversations c ON c.id = ref.conversation_id
    WHERE ref.tenant_id = fn.tenant_id
      AND ref.file_id = fn.id
      AND c.status IN ('active', 'archived')
  );
```

Interpretacio:
- `0` a `baix`: estat saludable.
- Tendencia creixent durant diversos dies: revisar throughput (`batch_limit`, durada runs, errors).

### 2) Backlog per tenant (top N)

```sql
SELECT
  fn.tenant_id,
  COUNT(*) AS orphan_backlog,
  MIN(fn.created_at) AS oldest_candidate_at,
  MAX(fn.created_at) AS newest_candidate_at
FROM data.file_nodes fn
WHERE fn.node_type = 'file'
  AND fn.is_deleted = false
  AND fn.processing_status = 'done'
  AND COALESCE(fn.metadata ->> 'source', '') = 'ai-chat'
  AND fn.created_at < now() - interval '90 days'
  AND NOT EXISTS (
    SELECT 1
    FROM data.ai_message_file_refs ref
    JOIN data.ai_conversations c ON c.id = ref.conversation_id
    WHERE ref.tenant_id = fn.tenant_id
      AND ref.file_id = fn.id
      AND c.status IN ('active', 'archived')
  )
GROUP BY fn.tenant_id
ORDER BY orphan_backlog DESC
LIMIT 20;
```

Interpretacio:
- Detecta tenants amb acumulacio anomala.
- Si un tenant domina el backlog, prioritzar analisi de patrons d'us i volumen adjunts.

### 3) Durada i volum dels runs (ultimes 24h)

```sql
SELECT
  COUNT(*) AS runs_24h,
  AVG(duration_ms)::bigint AS avg_duration_ms,
  PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration_ms)::bigint AS p95_duration_ms,
  SUM(candidates) AS total_candidates,
  SUM(deleted) AS total_deleted,
  SUM(errors) AS total_errors,
  SUM(CASE WHEN locked_skip THEN 1 ELSE 0 END) AS locked_skips
FROM data.ai_chat_orphan_cleanup_runs
WHERE started_at >= now() - interval '24 hours';
```

Interpretacio:
- `p95_duration_ms` alt + `total_deleted` baix => possible contencio o query degradata.
- `locked_skips` > 0 de forma recurrent: revisar overlap de jobs/manual runs.

### 4) Error rate i anomalies recents (ultims 50 runs)

```sql
SELECT
  id,
  started_at,
  finished_at,
  duration_ms,
  candidates,
  deleted,
  errors,
  locked_skip,
  details
FROM data.ai_chat_orphan_cleanup_runs
ORDER BY started_at DESC
LIMIT 50;
```

Interpretacio:
- `errors > 0`: revisar warnings del job i possibles file nodes inconsistents.
- `locked_skip = true`: run descartat per lock (acceptable puntualment, no sostingut).

### 5) Drift quota: comparacio `storage_usage` vs realitat

```sql
WITH real_usage AS (
  SELECT
    fn.tenant_id,
    COUNT(*) FILTER (
      WHERE fn.node_type = 'file'
        AND fn.is_deleted = false
        AND fn.processing_status <> 'pending'
    )::integer AS real_file_count,
    COALESCE(SUM(fn.size_bytes) FILTER (
      WHERE fn.node_type = 'file'
        AND fn.is_deleted = false
        AND fn.processing_status <> 'pending'
    ), 0)::bigint AS real_committed_bytes,
    COALESCE(SUM(fn.size_bytes) FILTER (
      WHERE fn.node_type = 'file'
        AND fn.is_deleted = false
        AND fn.processing_status = 'pending'
    ), 0)::bigint AS real_reserved_bytes
  FROM data.file_nodes fn
  GROUP BY fn.tenant_id
)
SELECT
  COALESCE(su.tenant_id, ru.tenant_id) AS tenant_id,
  COALESCE(su.file_count, 0) AS tracked_file_count,
  COALESCE(ru.real_file_count, 0) AS real_file_count,
  COALESCE(su.committed_bytes, 0) AS tracked_committed_bytes,
  COALESCE(ru.real_committed_bytes, 0) AS real_committed_bytes,
  COALESCE(su.reserved_bytes, 0) AS tracked_reserved_bytes,
  COALESCE(ru.real_reserved_bytes, 0) AS real_reserved_bytes,
  (COALESCE(su.file_count, 0) - COALESCE(ru.real_file_count, 0)) AS file_count_drift,
  (COALESCE(su.committed_bytes, 0) - COALESCE(ru.real_committed_bytes, 0)) AS committed_drift_bytes,
  (COALESCE(su.reserved_bytes, 0) - COALESCE(ru.real_reserved_bytes, 0)) AS reserved_drift_bytes
FROM data.storage_usage su
FULL OUTER JOIN real_usage ru ON ru.tenant_id = su.tenant_id
WHERE
  COALESCE(su.file_count, 0) <> COALESCE(ru.real_file_count, 0)
  OR COALESCE(su.committed_bytes, 0) <> COALESCE(ru.real_committed_bytes, 0)
  OR COALESCE(su.reserved_bytes, 0) <> COALESCE(ru.real_reserved_bytes, 0)
ORDER BY ABS(COALESCE(su.committed_bytes, 0) - COALESCE(ru.real_committed_bytes, 0)) DESC
LIMIT 50;
```

Interpretacio:
- Resultat buit: no hi ha drift detectable.
- Si hi ha drift repetit, executar reconciliacio i investigar origen.

## Accions operatives

### Trigger manual cleanup

```sql
SELECT api.run_ai_chat_orphan_cleanup_service(90, 200);
```

### Reconciliacio quota (single tenant)

```sql
SELECT api.reconcile_storage_usage_service(p_tenant_id => '<tenant_uuid>'::uuid);
```

### Reconciliacio quota (batch)

```sql
SELECT api.reconcile_storage_usage_service(NULL, 50);
```

## Thresholds recomanats

- Backlog:
  - Alerta si creix durant 3 dies seguits o supera el volum normal del tenant.
- Errors:
  - Alerta immediata si `errors > 0` en 2 runs consecutius.
- Locked skips:
  - Alerta si `locked_skip` apareix en >20% dels runs en 24h.
- Drift quota:
  - Alerta si `committed_drift_bytes` absolut supera 1% de quota efectiva o un llindar fix (p. ex. 500MB).

## Escalation checklist

1. Verificar backlog, errors i p95 durada.
2. Executar un run manual amb `api.run_ai_chat_orphan_cleanup_service(...)`.
3. Si hi ha drift, executar `api.reconcile_storage_usage_service(...)`.
4. Revalidar amb les queries 1, 3 i 5.
5. Si persisteix:
   - revisar canvis recents en migracions de storage/chat,
   - revisar cues de `trash_deletion_queue` i salut del worker `process-deletion-queue`.
