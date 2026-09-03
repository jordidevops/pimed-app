De totes maneres, aprofitant aquest "Segons el pla actual", t'informo que **ja he executat la primera tasca de la Fase 0** a través de l'agent intern: he reescrit completament el fitxer prompt.md perquè quadri al 100% amb les decisions d'arquitectura del nostre `plan.md` (afegint l'idempotència, l'outbox d'IndexedDB, la vinculació polimòrfica documental i garantint que encola des del SQL).

Segons el pla actual, els propers passos lògics són:
*   **Fase 1 (Backend SQL):** Crear les migracions `20260506000001_project_extensions.sql` i `20260506000002_work_logs.sql` per afegir `asset_id`, crear la taula `data.work_logs`, `project_expenses`, RLS, etc.
*   **Fase 2 (Worker Async - Prioritat 0):** Crear la Edge Function `process-project-events` per desencallar la cua i gestionar alertes i calendari.

Vols que l'obrim ja pel codi de la **Fase 1** (migració DDL dels work logs) o prefereixes començar per la **Fase 2** (el Worker)?


Fase 2 implementada completament. Resum del que s'ha creat:

**Fitxers nous:**
- index.ts — Worker amb `QueueRunner`, `defaultTask: 'PROJECT_CREATED'` per gestionar missatges legacy (que porten `event` en lloc de `task`)
- 20260506000003_project_events_cron.sql — 3 blocs: RPC `api.handle_project_created_event`, dispatcher `data.invoke_project_events_worker` (Vault + pg_net), i pg_cron cada 3 minuts

**Fitxers modificats:**
- config.toml — `verify_jwt = false` per al nou worker
- 09-async-infrastructure.md — `project_events` afegit a la taula de cues actives

**Decisions de disseny importants:**
1. `defaultTask: 'PROJECT_CREATED'` — els missatges existents a la cua no porten el camp `task` que espera QueueRunner, sinó `event`. El `defaultTask` actua de fallback transparent.
2. `api.handle_project_created_event` és `SECURITY DEFINER` revocada de `PUBLIC/authenticated/anon` i concedida **únicament** a `service_role` — el worker mai s'ha de poder cridar des del frontend.
3. Calendar event idempotent — comprova `EXISTS` abans d'inserir, per si el worker es reintenta.

Per testejar localment quan `supabase start` estigui operatiu:
```bash
curl -X POST http://127.0.0.1:54321/functions/v1/process-project-events \
     -H "Authorization: Bearer <service_role_key>" \
     -H "Content-Type: application/json" -d '{"batch_size": 5}'
```


