# Runbook — Cua de recomputació d'assistència

> Cua: `attendance_recompute_queue`  
> Worker: Edge Function `process-attendance-queue`  
> Dispatcher: `data.invoke_attendance_queue_worker()` (pg_cron cada minut)  
> Pla: [plan.md](./plan.md) Fase 0 · Estat: [STATUS.md](./STATUS.md)

---

## SLOs objectiu

| Indicador | Objectiu |
|-----------|----------|
| `record_time_punch` p95 | < 400 ms |
| Recomputa diària p95 | < 30 s (condicions normals) |
| Frescor tauler managers | < 60 s |
| `oldest_msg_age_sec` cua | < 300 s en operació normal |

---

## Comprovació ràpida

### Salut de la cua (service_role)

```sql
SELECT api.get_attendance_queue_health();
```

Camps clau:

| Camp | Significat | Alerta si |
|------|------------|-----------|
| `queue_length` | Missatges pendents | > 200 (`alert_backlog`) |
| `oldest_msg_age_sec` | Edat del missatge més antic | > 300 (`alert_stale_sec`) |
| `dlq_count` | Missatges a DLQ | > 0 (`alert_dlq`) |
| `catch_up_mode` | Dispatcher en mode recuperació | `true` durant pics |
| `cron_active` | Job pg_cron actiu | `false` |
| `recent_batches` | Últims 10 lots processats | molts `retried` / `dlqed` |

### PGMQ directe

```sql
SELECT * FROM pgmq.metrics('attendance_recompute_queue');

SELECT msg_id, read_ct, enqueued_at, message->>'employee_id' AS employee_id
FROM pgmq.q_attendance_recompute_queue
ORDER BY enqueued_at
LIMIT 20;
```

### Cron

```sql
SELECT jobid, jobname, schedule, active, command
FROM cron.job
WHERE jobname = 'process-attendance-queue-worker';
```

---

## Mode catch-up

Quan `queue_length` supera llindars, el dispatcher envia automàticament:

| Profunditat cua | `max_batches` per invocació | Batch size |
|-----------------|----------------------------|------------|
| ≤ 20 | 1 | 10–50 |
| 21–50 | 2 | fins a 50 |
| 51–100 | 3 | 50 |
| 101–200 | 5 | 50 |
| 201–500 | 8 | 50 |
| > 500 | 10 | 50 |

Invocació manual (recuperació immediata):

```powershell
$env:SUPABASE_SERVICE_ROLE_KEY = ((supabase status --output env 2>$null | Select-String "^SERVICE_ROLE_KEY=").ToString() -split "=", 2)[1].Trim('"')

Invoke-RestMethod -Uri "http://127.0.0.1:54321/functions/v1/process-attendance-queue" `
  -Method Post `
  -Headers @{
    "Authorization" = "Bearer $env:SUPABASE_SERVICE_ROLE_KEY"
    "Content-Type"  = "application/json"
  } `
  -Body '{"catch_up": true, "max_batches": 10, "batch_size": 50}'
```

Repetir fins que `queue_length = 0` o `total = 0` a la resposta.

---

## Proves de càrrega

```powershell
# Prerequisits: supabase start, migrations, seed, functions serve
.\supabase\tests\run_attendance_load_test.ps1

# Escenaris
npx tsx supabase/tests/attendance_load_test.ts --users 100 --concurrency 25
npx tsx supabase/tests/attendance_load_test.ts --users 1000 --concurrency 50
```

El script mesura p50/p95 de `record_time_punch`, buida la cua en mode catch-up i reporta l'estat final.

---

## Incidències habituals

### Backlog creixent (`queue_length` > 200)

1. Comprovar `cron_active = true`.
2. Comprovar que `process-attendance-queue` respon (logs Edge Function).
3. Invocar manualment catch-up (veure amunt).
4. Revisar `recent_batches` per errors recurrents.
5. Si `recompute_attendance_worker` lent: revisar càrrega DB (connexions, locks).

### Missatges a DLQ (`dlq_count` > 0)

```sql
SELECT id, original_msg_id, attempt_count, last_error_text, payload, created_at
FROM data.dlq_messages
WHERE queue_name = 'attendance_recompute_queue'
ORDER BY created_at DESC
LIMIT 20;
```

Accions:

- Corregir causa arrel (empleat esborrat, data invàlida, etc.).
- Reencuar manualment si cal després de corregir dades.
- No purgar DLQ sense revisió (traçabilitat legal).

### Cron inactiu o secrets Vault absents

`invoke_attendance_queue_worker` retorna `-1` (secrets) o `-2` (pg_net).

Local: assegurar `supabase functions serve` i que el cron local estigui actiu.

Cloud: verificar Vault `app_supabase_url` + `app_service_role_key` (veure `docs/queues.md` §3.2).

### Latència punch alta però cua estable

El problema és la RPC `record_time_punch`, no el worker:

- Revisar índexs `time_punches`.
- Pic concurrent: escalar connexions o reduir `concurrency` client.
- Geolocalització: no ha de bloquejar (timeout 3s al client).

---

## Escalat i límits

- **Batch màxim PGMQ:** 50 missatges per lectura.
- **Catch-up màxim:** 10 batches × 50 = 500 recomputes per invocació Edge (~2 min timeout HTTP).
- **Freqüència cron:** 1 min (pg_cron estàndard). En pic extrem: invocacions manuals addicionals.
- **Particionament:** no implementat; idempotency per `employee_id + work_date` evita duplicats de càlcul.

---

## Referències

- Migració: `supabase/migrations/20260806000001_attendance_queue_capacity.sql`
- Worker: `supabase/functions/process-attendance-queue/index.ts`
- Cues genèriques: `docs/queues.md`
- DEV: `DEV_RUNBOOK.md` § Control horari — proves de càrrega
