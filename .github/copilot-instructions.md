# Regles del Projecte: Internacionalització (i18n)

Ets un expert en React i TypeScript. En aquest projecte, la internacionalització és obligatòria i segueix unes regles sintàctiques estrictes.

## Regla d'Or del Text al Frontend
Tots els strings visibles per l'usuari han d'utilitzar la llibreria `react-i18next` amb el mètode `t()`.

## Sintaxi Obligatòria
S'ha de fer servir SEMPRE el patró de "Clau amb Fallback" (dos arguments):
`{t('namespace.clau', 'Text per defecte en Català')}`

### Exemple Correcte:
- `const { t } = useTranslation('storage');`
- `{t('storage.actions.upload', 'Pujar fitxer')}`

### Prohibit:
- Prohibit posar text pla: `<span>Pujar fitxer</span>`
- Prohibit posar només la clau: `{t('storage.actions.upload')}`

## Procediment de Treball
Cada vegada que creis un component:
1. Utilitza el format de dos arguments.
2. Si crees claus noves, afegeix-les al fitxer `src/locales/ca/storage.json` mantenint l'estructura jeràrquica.
3. El text per defecte (segon argument) ha d'ajudar al debug i servir de fallback real.

---

# Regles del Projecte: Tipus de Base de Dades (database.types.ts)

## Quan cal regenerar els tipus

Cada vegada que es crea o modifica una migració SQL que afecti:
- Taules o columnes a `data.*`
- Vistes a `api.*`
- Funcions RPC exposades

Cal regenerar els tipus amb la comanda:
```powershell
supabase gen types typescript --local 2>$null | Set-Content "apps/tenant-portal/src/types/database.types.ts" -Encoding utf8
Copy-Item "apps/tenant-portal/src/types/database.types.ts" "supabase/functions/_shared/database.types.ts"
```

## On viuen els tipus i per què en dos llocs

| Fitxer | Consumidor | Motiu |
|--------|-----------|-------|
| `apps/tenant-portal/src/types/database.types.ts` | Frontend React (Vite) | Autocompletat de `supabase-js` al portal |
| `supabase/functions/_shared/database.types.ts` | Edge Functions (Deno) | Les funcions no poden importar des de `apps/` |

## Ús obligatori als clients Supabase

Les funcions `createAdminClient()` i `createUserClient()` de `_shared/supabase.ts` ja estan tipades amb `createClient<Database, "api">`. No cal re-tipar-les a cada Edge Function.

Al frontend, el client de `src/lib/supabase.ts` ha d'usar també el genèric:
```typescript
import type { Database } from "@/types/database.types";
export const supabase = createClient<Database>("URL", "ANON_KEY");
```

## Regla d'Or dels Tipus

Mai escriguis tipus manuals per a les respostes de Supabase. Usa sempre els tipus generats:
```typescript
// ✅ Correcte
import type { Database } from "@/types/database.types";
type EmailDomain = Database["api"]["Views"]["email_domains"]["Row"];

// ❌ Prohibit
interface EmailDomain { id: string; domain: string; ... }
```

---

# Context Ràpid del Sistema (Arquitectura + Seguretat)

Aquest apartat explica a qualsevol model AI com funciona l'app de forma real i actual.

## 1) Apps i responsabilitats

### tenant-portal (Vite + React)
- Client app pels usuaris finals del tenant.
- Accés a dades via `supabase-js` i PostgREST sobre l'schema `api`.
- Subjecte a RLS (no hi ha bypass).

### admin-portal (Next.js + Prisma)
- Backoffice de la startup (`admin` / `support`).
- Opera principalment sobre `data.*` via Prisma + credencial amb bypass RLS.
- IMPORTANT: El bypass és per operacions de dades d'admin, NO per dissenyar migracions.

## 2) Schemes i flux de dades

- `data.*`: taules reals (privades).
- `api.*`: vistes i funcions exposades a PostgREST (`security_invoker = true` quan toca).
- Els clients de frontend han de parlar amb `api.*` (no directament amb `data.*`).

## 3) Model multi-tenant + multi-site

- `data.tenants`: organitzacions.
- `data.sites`: locals/seus dins de cada tenant.
- `data.tenant_members`: membresia usuari-tenant amb:
  - `site_id IS NULL`: rol global del tenant.
  - `site_id IS NOT NULL`: rol limitat a un site concret.

### Regla de context de site
- `site_id NULL` en un recurs: recurs global del tenant.
- `site_id NOT NULL`: recurs específic d'un site.

## 4) Autenticació i claims

Sistema dual (intencional):

1. Camí ràpid (JWT claims):
	- Auth Hook `data.custom_access_token_hook(event jsonb)` injecta `app_metadata.user_tenants` al token.
	- RLS llegeix directament del JWT quan el claim hi és.

2. Fallback (cache SQL):
	- `data.user_permissions_cache` manté la mateixa estructura de permisos.
	- Trigger sobre `tenant_members` la recalcula automàticament.

Funció unificada:
- `data.jwt_user_tenants()` fa `COALESCE(JWT claim, cache, '{}')`.
- Això evita downtime durant transicions de token i manté coherència funcional.

## 5) Patró RLS real

En general, les polítiques han de seguir aquest patró:

- Pertinença tenant:
  - `data.jwt_user_tenants() ? tenant_id::text`
- Rol global:
  - `data.jwt_user_tenants() -> tenant_id::text ->> 'global_role'`
- Rol per site:
  - `data.jwt_user_tenants() -> tenant_id::text -> 'sites' ? site_id::text`
- Filtre tenant actiu (UX):
  - `data.active_tenant_id()` (header `x-tenant-id`)

## 6) Comportament esperat de permisos

- Usuari amb rol global (`owner/manager/member/viewer`): accés tenant-wide segons policy.
- Usuari site-only: només dades del seu site quan la policy és site-aware.
- `owner/manager` globals: operacions de gestió (membres, configuració, etc.) segons policy.

## 7) Sites i quota de plans

- `data.plans.max_sites` defineix límit de sites actius.
- Trigger `data.enforce_site_quota()` valida límit a nivell BD.
- `data.provision_tenant(name, slug, plan_id)` crea tenant + site inicial de forma atòmica.

## 8) Regles de treball per IA en aquest repo

1. Si toques SQL de `data.*`, `api.*` o RPC exposades:
	- Regenera `database.types.ts` amb la comanda oficial indicada a dalt.

2. Si toques frontend React:
	- Tots els textos visibles han d'anar amb `t('key', 'Fallback')`.

3. Si proposes canvis d'accés:
	- Assumeix sempre que tenant-portal va per PostgREST + RLS.
	- No assumeixis bypass RLS fora d'admin-portal/backoffice.

4. Si cal crear/editar polítiques:
	- Prioritza el patró `jwt_user_tenants()` i evita subconsultes costoses per fila.

5. Mantén comentaris de capçalera de migracions actualitzats:
	- Han de reflectir el patró real implementat, no un disseny antic.

6. Protocol d'Auditoria (obligatori):
	- Qualsevol nova funcionalitat que impliqui un **canvi de cicle de vida d'una entitat** (creació, eliminació, activació/desactivació, canvi de rol, bloqueig, canvi de pla, enviament d'invitació) **ha de preveure el seu registre a `data.audit_logs`**.
	- **Accions de BD**: implementa un trigger PostgreSQL sobre la taula afectada. Usa `data.log_audit_event()` i el patró `COALESCE(auth.uid(), <camp_actor>)`.
	- **Accions de codi** (Edge Functions, Server Actions sense trigger): insereix directament a `data.audit_logs` un cop confirmada l'operació principal. Els errors d'audit no han de trencar el flux principal (tracta'ls com a "fire-and-forget" amb `console.warn`).
	- **Naming convention per a `action`**: usa MAJÚSCULES_AMB_GUIÓ_BAIX descriptiu. Exemples: `TENANT_PLAN_CHANGED`, `MEMBER_INVITED`, `SITE_DEACTIVATED`, `FILE_DELETED`.
	- **`entity_type`**: nom de la taula sense schema (ex: `'tenant'`, `'site'`, `'tenant_member'`, `'file'`).
	- **`payload`**: jsonb amb les dades mínimes per entendre el canvi (camps old/new, IDs relacionats). Evita dades sensibles (passwords, tokens).
	- **`user_id` NULL**: acceptable per a operacions de sistema (pg_cron, triggers sense context d'usuari). El camp `payload` ha de proporcionar context suficient.
	- La taula `data.audit_logs` ja té RLS habilitada. L'admin-portal hi accedeix via `prisma.$queryRaw` (BYPASSRLS).

---

# Infraestructura Asíncrona (PGMQ + QueueRunner)

## Quan cal encuar una tasca de fons

Encua des d'una **RPC PL/pgSQL** sempre que una acció d'usuari hagi de:
- Enviar email/SMS/WhatsApp.
- Materialitzar recordatoris de calendari.
- Esborrar objectes de Storage.
- Processar integracions externes.
- Executar tasques d'IA.

**Mai encuis des de codi TypeScript directament ni des de triggers SQL de negoci.**

## Patró transaccional obligatori

```sql
-- PL/pgSQL SECURITY INVOKER dins una sola transacció:
INSERT INTO data.<taula> (...) RETURNING id INTO v_id;
PERFORM data.log_audit_event('<ACTION>', '<entity>', v_id, payload);
PERFORM pgmq.send('<queue_name>', jsonb_build_object(
  'task',             'nom_del_handler',
  'tenant_id',        data.active_tenant_id(),
  'idempotency_key',  '<string-determinista>',
  'enqueued_at',      now(),
  'payload',          jsonb_build_object(...)
));
-- Si el INSERT falla → el pgmq.send reverteix automàticament
```

## Cues actives i workers

| Cua | Worker Edge Function | pg_cron |
|---|---|---|
| `email_send_queue` | `process-email-queue` | cada 2 min |
| `trash_deletion_queue` | `process-deletion-queue` | cada 5 min |
| `reminders_queue` | `process-reminders-queue` | cada 1 min |

## Com crear un nou worker

1. **Migració SQL** (`supabase/migrations/`): `SELECT pgmq.create('nova_queue');` + entrada a pg_cron.
2. **Edge Function** (`supabase/functions/process-nova-queue/index.ts`):

```typescript
import { QueueRunner } from '../_shared/queue-runtime.ts'
import { createAdminClient } from '../_shared/supabase.ts'

const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''

Deno.serve(async (req: Request) => {
  const auth = req.headers.get('Authorization') ?? ''
  if (auth !== `Bearer ${SERVICE_ROLE_KEY}`) {
    return new Response('Unauthorized', { status: 401 })
  }
  const runner = new QueueRunner({
    queueName: 'nova_queue',
    handlers: {
      nom_tasca: async (payload, ctx) => {
        // lògica: usa ctx.db (adminClient), filtra per payload.tenant_id
        return { success: true }
      },
    },
    db: createAdminClient(),
  })
  const summary = await runner.runBatch()
  return new Response(JSON.stringify(summary), { status: 200 })
})
```

3. **`supabase/config.toml`**: afegeix `verify_jwt = false` per al worker (les crides venen de pg_cron, no d'usuaris).

## Regles del worker

- **`service_role`** sempre (`createAdminClient()`). Cap RLS al worker.
- **`tenant_id` explícit** del payload en totes les queries. Mai "per a tots els tenants".
- **Una invocació = un batch**. Cap loop infinit.
- **Dedup, retry i DLQ** els gestiona `QueueRunner` automàticament.

## Idempotency key — convenció

Format: `<prefix>-<entity_id>-<discriminant>`. Exemples:
- `rem-<event_id>-<offset_min>` (recordatori)
- `del-<file_id>` (eliminació)
- `email-inv-<member_id>` (invitació)

## Notificacions in-app

`QueueRunner` crea una `data.notifications` automàticament per a fallades que arriben a DLQ (`severity='critical'`, dirigida als `owner` del tenant). Per enviar notificacions d'èxit des d'un handler:

```typescript
await ctx.emitNotification({
  user_id: payload.actor_user_id,
  kind: 'task_complete',
  severity: 'success',
  title_i18n: { ca: 'Exportació completada', es: 'Exportación completada', en: 'Export complete' },
  related_entity_type: 'async_task',
  related_entity_id: taskId,
})
```

## Referència completa

Consulta `docs/product-design/10-implemented-modules.md` §8 per a l'estructura completa de taules, RPCs i flux end-to-end amb exemples.