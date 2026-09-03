# Cues a Supabase amb PGMQ

## 1) Visió general (genèrica)

El flux correcte, en aquest projecte, no és "pgcron -> pgnet -> Edge Function -> pgmq".
El flux base és aquest:

1. L'app (normalment una RPC PL/pgSQL) crea o modifica una entitat de negoci.
2. A la mateixa transacció, encua una tasca amb `pgmq.send('nom_cua', payload)`.
3. Un dispatcher periòdic (pg_cron) crida una funció SQL interna (`data.invoke_*_worker`).
4. Aquesta funció SQL fa una petició HTTP asíncrona amb pg_net (`extensions.http_post`) a l'Edge Function worker.
5. El worker processa un batch de la cua via `QueueRunner` i arxiva/reintenta/DLQ segons resultat.

Resum curt:

`RPC transaccional -> PGMQ -> (pg_cron -> pg_net) -> Edge Function worker -> QueueRunner`

Nota important:

- A `email_send_queue` hi ha també un camí "instantani" addicional per trigger SQL sobre `pgmq.q_email_send_queue`, que invoca el worker via pg_net immediatament. El cron de 2 minuts queda com a xarxa de seguretat.

---

## 2) Què fa cada peça

### PGMQ

- És la cua persistent dins PostgreSQL.
- Desa missatges, controla visibilitat/retries i permet lectura per lots.
- En aquest repo, la creació de cues es fa per migració amb `pgmq.create('queue_name')`.

### pg_cron

- Programa execucions periòdiques dins PostgreSQL.
- Aquí s'utilitza per executar un `SELECT data.invoke_*_worker(...)` cada N minuts.
- No processa la feina de negoci directament: només dispara el dispatcher.

### pg_net

- Permet fer HTTP sortint des de PostgreSQL.
- El dispatcher SQL usa `extensions.http_post(...)` per cridar l'Edge Function worker.
- El retorn és un `request_id` i l'execució HTTP continua asíncronament.

### Edge Function worker + QueueRunner

- Valida `Authorization: Bearer <service_role_key>`.
- Llegeix un batch de la cua (`queueName`) i resol handlers per `task`.
- Gestiona idempotència, retries i DLQ amb la lib compartida `QueueRunner`.

**Credencials dins la funció (automàtiques):** Supabase injecta `SUPABASE_URL` i `SUPABASE_SERVICE_ROLE_KEY` a totes les Edge Functions automàticament, tant a cloud com en local. No cal cap configuració addicional. El nostre `_shared/supabase.ts` ja els llegeix amb `Deno.env.get("SUPABASE_URL")` i `Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")`.

---

## 3) Configuració a Supabase Cloud

### 3.1 Extensions i migracions

1. Aplica migracions que creen:
	 - Cua (`pgmq.create(...)`)
	 - Dispatcher SQL (`data.invoke_*_worker`)
	 - `cron.schedule(...)`
2. Les migracions del repo ja segueixen aquest patró per les cues actives.

### 3.2 Secrets de Vault per al dispatcher pg_net

Important: hi ha **dos usos de credencials completament separats**:

**A) Dins les Edge Functions** → automàtic, sense configuració

Supabase injecta a totes les Edge Functions per defecte:

- `SUPABASE_URL` — URL de l'API gateway del projecte
- `SUPABASE_SERVICE_ROLE_KEY` — clau service role (llegada per `_shared/supabase.ts`)
- `SUPABASE_ANON_KEY` — clau anon

No cal cap Vault ni secret manual per a l'ús intern de les funcions.

**B) Desde PostgreSQL cap a les Edge Functions** → requereix Vault

Les funcions dispatcher (`data.invoke_*_worker`) s'executen **dins de PostgreSQL** i fan una crida HTTP sortint via pg_net a l'Edge Function. PostgreSQL no té accés automàtic a les variables d'entorn de les Edge Functions, de manera que llegeix les credencials del Vault:

- `app_supabase_url` (p.ex. `https://<project-ref>.supabase.co`)
- `app_service_role_key` (service role key del projecte)

Sense aquests secrets al Vault, la funció dispatcher fa degradació controlada (warning i retorna `-1`). Configuració única per projecte:

```sql
SELECT vault.create_secret('https://<ref>.supabase.co', 'app_supabase_url');
SELECT vault.create_secret('<service_role_key>', 'app_service_role_key');
```

### 3.3 Edge Functions i JWT

Les functions worker cridades per pg_net han d'estar amb `verify_jwt = false` a `supabase/config.toml`, perquè no reben JWT d'usuari, sinó token tècnic service role per header `Authorization`.

En aquest repo ja consten:

- `process-email-queue`
- `process-deletion-queue`
- `process-reminders-queue`
- `process-project-events`

### 3.4 Verificació ràpida a Cloud

- Jobs cron:
	- `select jobid, jobname, schedule, active from cron.job order by jobname;`
- Cues PGMQ (exemple):
	- `select * from pgmq.metrics('email_send_queue');`
	- `select * from pgmq.metrics('reminders_queue');`

---

## 4) Simulació en local (Supabase amb contenidors)

**Variables automàtiques en local:** `supabase start` / `supabase functions serve` injecta automàticament `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` i `SUPABASE_ANON_KEY` a les funcions. **No cal cap `.env` manual per a les credencials bàsiques.**

**El que NO funciona en local:** el dispatcher SQL (`pg_net` des de PostgreSQL) no pot fer la crida HTTP a les Edge Functions pels límits de xarxa entre contenidors. Per tant, el cron automàtic no dispara els workers localment.

**Solució recomanada per a proves locals:** invocar directament el worker via `curl`. La service role key la trobaràs a `supabase status`.

Patró de prova local:

1. Arrenca Supabase local (`supabase start`).
2. Arrenca les funcions en un segon terminal (`supabase functions serve`).
3. Obté la service role key (`supabase status`).
4. Invoca el worker amb `curl`:

```bash
curl -X POST http://127.0.0.1:54321/functions/v1/process-reminders-queue \
	-H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
	-H "Content-Type: application/json" \
	-d '{"batch_size":20}'
```

```PS
Invoke-WebRequest -Uri "http://127.0.0.1:54321/functions/v1/process-email-queue" `
  -Method Post `
  -Headers @{ "Authorization" = "Bearer eyJhb..." } `
  -ContentType "application/json" `
  -Body "{}"
```

Exemples equivalents:

```bash
curl -X POST http://127.0.0.1:54321/functions/v1/process-email-queue \
	-H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
	-H "Content-Type: application/json" \
	-d '{}'

curl -X POST http://127.0.0.1:54321/functions/v1/process-deletion-queue \
	-H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
	-H "Content-Type: application/json" \
	-d '{"batch_size":10}'

curl -X POST http://127.0.0.1:54321/functions/v1/process-project-events \
	-H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
	-H "Content-Type: application/json" \
	-d '{"batch_size":25}'
```

Nota:

- Al moment actual del repo, `supabase/config.toml` i `.env` de tenant-portal estan en ports locals `54321/54322/...`.
- Si canvies ports locals, adapta l'URL dels exemples.

---

## 5) Cues actuals i estat d'implementació

### 5.1 Cues actives (creades + worker + cron)

| Cua PGMQ | Worker | Dispatch | Estat | Detall funcional |
|---|---|---|---|---|
| `email_send_queue` | `process-email-queue` | Trigger instantani + cron cada 2 min | Implementada | Enviament email, lock singleton i multi-batch |
| `trash_deletion_queue` | `process-deletion-queue` | cron cada 5 min | Implementada | Esborrat físic storage (Supabase/BYOS) |
| `reminders_queue` | `process-reminders-queue` | cron cada 1 min | Implementada | Materialitza recordatoris i encua email |
| `project_events` | `process-project-events` | cron cada 3 min | Implementada | Processa `PROJECT_CREATED` (notificacions + calendari) |

### 5.1b Jobs pg_cron SQL directes (sense PGMQ)

| Job | Schedule | Estat | Detall |
|---|---|---|---|
| `queue-expired-trash` | `0 3 * * *` UTC | Implementada | Marca nodes a la paperera expirada |
| `cleanup-pending-uploads` | `*/30 * * * *` | Implementada | Esborra uploads pending expirats (30 min) |
| `cleanup-orphan-ai-chat-attachments` | `17 * * * *` UTC | Implementada | TTL 90d adjunts `source: ai-chat` orfes; lock anti-solapament; mètriques + log persistent |
| `reconcile-storage-usage-weekly` | `43 4 * * 0` UTC | Implementada | Reconciliació setmanal de `storage_usage` (drift detection/correction) |

Smoke test manual (service_role): `SELECT api.run_ai_chat_orphan_cleanup_service();`
Reconciliació manual (service_role): `SELECT api.reconcile_storage_usage_service(NULL, 50);`

### 5.2 Cues previstes (documentades, no creades al schema actual)

| Cua prevista | Worker previst | Estat | Origen documental |
|---|---|---|---|
| `integration_queue` | `process-integration-queue` | Planificada | Arquitectura async (mòdul integracions) |
| `ai_queue` | `process-ai-queue` | Planificada | Arquitectura async (mòdul IA) |
| `maintenance_queue` | `process-maintenance-queue` | Planificada | Arquitectura async (manteniments) |
| `attendance_recompute_queue` | `process-attendance-queue` | Planificada | Arquitectura Time Attendance |

---

## 6) Patró recomanat per afegir una cua nova

Checklist curt:

1. Migració SQL:
	 - `select pgmq.create('nova_queue');`
	 - `create or replace function data.invoke_nova_queue_worker(...) returns bigint ...`
	 - `select cron.schedule(..., 'SELECT data.invoke_nova_queue_worker(...)');`
2. Worker Edge Function:
	 - `supabase/functions/process-nova-queue/index.ts`
	 - `QueueRunner({ queueName: 'nova_queue', handlers: {...}, db: createAdminClient() })`
3. Config:
	 - `[functions.process-nova-queue]`
	 - `verify_jwt = false`
4. Vault a cloud (per al dispatcher pg_net, no per a la funció en si):
	 - `SELECT vault.create_secret('<url>', 'app_supabase_url');`
	 - `SELECT vault.create_secret('<key>', 'app_service_role_key');`
5. Validació:
	 - Test local amb `curl`
	 - Comprovació de `cron.job` i `pgmq.metrics(...)`

---

## 7) Errors habituals a evitar

- Encua des de TypeScript directament en lloc d'una RPC transaccional.
- Dependre només de cron quan necessites baixa latència (cas email instantani).
- Oblidar `verify_jwt = false` en workers interns.
- No usar idempotency key estable al payload.
- Barrejar noms de cues legacy (`email_queue`) amb el nom canònic actual (`email_send_queue`).
- Confondre els dos usos de credencials: dins les Edge Functions (`SUPABASE_SERVICE_ROLE_KEY`) és automàtic; al dispatcher pg_net des de PostgreSQL necessita Vault (`app_service_role_key`).

