# Pla d'implementació — Timeline per Entitat

**Data:** Juny 2026 (revisat 2026-06-23 peer review #1; revisat 2026-06-23 revisió final #2; **estat implementació 2026-06-24**)  
**Estat:** **Fase 1 tancada** — **Fase 2 tancada** — **Fase 3 tancada** (F3.1–F3.9 fets)  
**Abast:** Comentaris, events d'auditoria humanitzats, mencions, tasques, adjunts, IA i webhooks (per fases)

---

## Resum executiu

La timeline per entitat unifica en una sola línia temporal:

1. **Events automàtics** de `data.audit_logs` (canvis d'estat, creacions, signatures, etc.)
2. **Comentaris manuals** de `data.entity_comments` (notes d'equip, mencions, tasques)

El sistema s'integra amb l'arquitectura existent (Supabase + RPCs `api.*` + Edge Functions + React tenant-portal) i respecta RBAC via `data.jwt_has_permission` i membres actius del tenant.

**Nota important:** la taula real és `data.audit_logs` (plural), no `audit_log`. El helper central és `data.log_audit_event(...)`.

---

## 0) Estat actual del repositori (baseline)

### Audit (`data.audit_logs`)

| Camp | Tipus | Notes |
|------|-------|-------|
| `id` | uuid | PK |
| `tenant_id` | uuid | FK tenants (nullable en cascades) |
| `user_id` | uuid | Actor (`profiles`) |
| `site_id` | uuid | Context opcional |
| `action` | text | Acció tipada en UPPER_SNAKE (p.ex. `EMPLOYEE_UPDATED`) |
| `entity_type` | text | Tipus d'entitat relacionada |
| `entity_id` | uuid | ID de l'entitat |
| `payload` | jsonb | Context (`old`/`new`, camps específics) |
| `created_at` | timestamptz | Ordenació timeline |

**Helper:** `data.log_audit_event(tenant_id, user_id, site_id, action, entity_type, entity_id, payload)` — SECURITY DEFINER, tolerant a errors (no trenca la transacció principal).

**Índex existent:** `idx_audit_logs_tenant_created_at_desc (tenant_id, created_at DESC)` — útil per backoffice, cal afegir índex per `(tenant_id, entity_type, entity_id, created_at DESC)` per timeline per entitat.

### `entity_type` ja registrats a l'audit (inventari parcial)

| entity_type | Exemples d'accions |
|-------------|-------------------|
| `employee` | `EMPLOYEE_CREATED`, `EMPLOYEE_UPDATED`, `EMPLOYEE_TERMINATED`, `EMPLOYEE_DELETED` |
| `contact` | `CONTACT_CREATED`, `CONTACT_UPDATED`, `CONTACT_ARCHIVED`, `CONTACT_UNARCHIVED`, `CONTACT_DELETED` |
| `contact_site` | `CONTACT_SITE_*` |
| `document` | `DOCUMENT_CREATED`, `DOCUMENT_UPDATED`, `DOCUMENT_DELETED` |
| `document_folder` | `DOCUMENT_FOLDER_*` |
| `document_version` | `DOCUMENT_VERSION_UPLOADED`, `DOCUMENT_VERSION_DELETED` |
| `document_template` | `TEMPLATE_*` |
| `signing_submission` | `SIGNING_SUBMISSION_*`, `SIGNING_SUBMISSION_REVIEWED` |
| `project` | `PROJECT_CREATED`, `PROJECT_STATUS_CHANGED`, `PROJECT_CALENDAR_*`, `PROJECT_NOTIFICATIONS_SENT` |
| `project_line` | `PROJECT_LINE_*` |
| `project_expense` / `project_material` | `PROJECT_EXPENSE_*`, `PROJECT_MATERIAL_*` |
| `work_log` | Events de registre d'hores |
| `calendar_event` | Events de calendari |
| `shift_slot` / `shift_swap_request` | Planificació de torns |
| `time_entry` / `time_punch` / `time_daily_summary` | Presència |
| `tenant` / `site` / `tenant_member` | Admin intern |
| `email_log` | `EMAIL_BODY_VIEWED` |
| `public_lead` | Leads del portal públic |

### Notificacions

El **Motor de Notificacions** (F0–F2) ja està implementat: `data.enqueue_notification_dispatch` → PGMQ `notification_dispatch_queue` → `process-notification-queue`. El catàleg inclou `MENTION_CREATED` (in-app + push + email segons preferències).

**Decisió revisada:** la timeline **no** crea `data.user_notifications` ni fa enviaments síncrons des de triggers. Les mencions i respostes s'encuen via el motor asíncron (mateix patró que `TASK_ASSIGNED` i `LEAD_RECEIVED`).

### RBAC

- Membres actius: `data.tenant_members` + JWT claims `app_metadata.user_tenants`
- Permisos granulars: `data.jwt_has_permission(tenant_id, permission, site_id?)`
- Exemples: `hr.manage`, `attendance.view_all`, `labor_calendar.manage`, `ai.use`
- Les pàgines de detall ja filtren per rol (`owner`/`manager`/`member`/`viewer`)

### Storage (adjunts)

Patró existent al tenant-portal (`storageService.ts`):

1. `request-upload` Edge Function → reserva `file_nodes` + URL pre-signada
2. PUT binari al storage
3. `confirm-upload` Edge Function → marca `processing_status = 'done'`

Cal reutilitzar-lo amb metadada `source: entity_comment` i prefix de path dedicat.

### IA (xat)

Tools existents (`supabase/functions/_shared/ai/tools/`):

- `query_employees`, `query_calendar_events`, `query_document_templates`
- Patró `defineTool({ name, risk, requiredPermission, execute })`
- Cal afegir `query_entity_timeline` amb el mateix patró de permisos

### Webhooks

- Existeix `docuseal-webhook` (signing inbound)
- **No hi ha** infraestructura genèrica de webhooks sortints per tenant
- L'arquitectura d'automatització V2 (`docs/plans/automatitzacio/arquitectura-automatitzacio-v2.md`) preveu events via `audit_logs` + PGMQ — alinear-hi la Fase 3

### UI de detall existent

| Entitat | Patró UI actual | Integració proposada |
|---------|------------------|---------------------|
| Empleats | Tabs: info, documents, timesheet, work_calendar | Afegir tab **Activitat** |
| Contactes | Seccions verticals (sense tabs) | Afegir secció **Activitat** al final o tab si es refactoritza |
| Projectes | Seccions apilades (tasks, lines, work logs) | Afegir secció **Activitat** |
| Documents | Pàgina de detall pròpia | Tab/secció **Activitat** |

**Decisió UI:** tab **Activitat** on ja hi ha tabs (`EmployeeDetailPage`); secció dedicada on no n'hi ha — canvi mínim i consistent.

---

## 1) Decisions de disseny prèvies

### D1 — On viu la humanització dels events d'audit

**Decisió:** model **híbrid estructurat**.

- **Backend (RPC):** retorna metadades normalitzades per event:
  - `kind: 'audit_event'`
  - `action`, `entity_type`, `entity_id`
  - `actor: { id, full_name, avatar_url }`
  - `payload` (jsonb brut)
  - `message_key` (p.ex. `timeline.audit.EMPLOYEE_UPDATED`)
  - `message_vars` (valors per interpolació: `{ old_status, new_status }`)
- **Frontend:** aplica plantilles i18n des d'un registre central `timelineAuditRegistry.ts`.

**Per què no només backend:** i18n (ca/es/en) i iteració de copy UX són més ràpides al client.  
**Per què no només frontend:** la lògica d'extracció de `old`/`new` del payload varia per acció; centralitzar-la al RPC evita duplicació i garanteix coherència per IA i webhooks.

**Extensibilitat:** afegir un `action` nou = 1 entrada al registre SQL de mapping (opcional) + 1 clau i18n + 1 funció extractora si cal.

---

### D2 — Format de mencions

**Decisió:** emmagatzematge canònic `[[@uuid|Display Name]]` dins `content`.

| Capa | Comportament |
|------|-------------|
| Composer | L'usuari escriu `@Jo` → autocomplete → insereix token intern |
| Render | Substitueix per enllaç/span `@Display Name` |
| DB | `mentions uuid[]` extret en INSERT/UPDATE via regex + validació que els UUIDs són membres actius del tenant |

**Alternatives descartades:**
- Markdown `@uuid` sol — no llegible en exportacions
- JSON separat del text — difícil d'editar

---

### D3 — Estructura de fils (`parent_id`)

**Decisió:** **dos nivells** (arrel + respostes directes), sense recursivitat infinita.

- `parent_id IS NULL` → comentari arrel (apareix a la timeline principal)
- `parent_id NOT NULL` → resposta; el `parent_id` ha d'apuntar sempre a un arrel (constraint o validació RPC)

**FK `parent_id`:** `ON DELETE RESTRICT` (no `SET NULL`). Un hard delete de l'arrel amb respostes ha de **fallar** a nivell de BD. El flux normal és **soft delete** (`deleted_at`), que preserva el fil amb placeholder (D4). La RPC `delete_entity_comment` només fa soft delete; el hard delete queda reservat a `service_role` i ha de rebutjar arrels amb `replies_count > 0`.

**Justificació:** mateix model que GitHub/Linear/Slack threads curts; evita arbres profunds i comentaris orfes que apareixen com a arrels.

---

### D4 — Comentaris esborrats (soft delete)

**Decisió:** **mostrar placeholder** `"Comentari eliminat"` preservant el fil.

- `deleted_at NOT NULL` → `content` no es retorna al client (o es retorna buit)
- Es manté `id`, `parent_id`, `created_at`, `user_id` per context del fil
- Les respostes continuen visibles sota el placeholder

---

### D5 — Vista timeline: VIEW vs RPC vs Edge

**Decisió:** **RPC PostgreSQL** `api.get_entity_timeline(...)`.

| Opció | Pros | Contres |
|-------|------|---------|
| VIEW | Simple lectura | No pot fer RBAC per entitat, ni paginació cursor, ni humanització |
| RPC | Permisos, cursor, agregació audit+comments, metadata | Cal mantenir SQL |
| Edge | Flexibilitat | Latència extra, duplicació lògica |

La RPC fa UNION ALL conceptual entre audit + comments arrel, ordenació per `created_at DESC`, cursor `(created_at, id)`.

**Tipus de retorn (`RETURNS jsonb`):** es manté per V1 perquè cada item és **heterogeni** (`audit_event` vs `comment` amb camps diferents) i la paginació va dins `page: { has_more, next_cursor, next_cursor_id }`. PostgREST no modela bé un `UNION` de formes diferents com a `SETOF record` tipat. **Compromís documentat:** el client TypeScript defineix tipus explícits (`TimelineItem`, `TimelinePage`); no dependre de codegen automàtic per aquesta RPC. Si en el futur cal filtrar per columna a PostgREST, es pot afegir una vista materialitzada o RPC secundària per audit-only / comments-only.

**Filtre temporal (escalabilitat):** paràmetres opcionals `p_date_from` / `p_date_to` per consultar un rang (p.ex. "activitat d'aquest mes") sense paginar tot l'historial.

---

### D6 — Notificacions de mencions (V1)

**Decisió revisada:** **asíncron via Motor de Notificacions** — cap enviament ni INSERT directe a `data.notifications` dins el trigger.

| Pas | On | Què |
|-----|-----|-----|
| 1 | Trigger `AFTER INSERT` (lleuger) | Crida `data.enqueue_entity_comment_notifications(p_comment_id)` |
| 2 | Funció SQL SECURITY DEFINER | Per cada destinatari (menció + autor del pare en reply), `data.enqueue_notification_dispatch` amb `eventType: MENTION_CREATED` |
| 3 | Worker | `process-notification-queue` (ja existent) |

**Regles:**
- Menció explícita `@user` → `MENTION_CREATED` al destinatari
- Resposta (`parent_id NOT NULL`) → notificar autor del pare (si diferent de l'autor de la resposta)
- No notificar l'autor del propi comentari
- `correlationId` determinista: `mention:{comment_id}:{user_id}` per idempotència

**Per què no síncron:** un comentari amb 10 mencions no ha de bloquejar la transacció d'inserció ni dependre de OneSignal/Resend en calent (mateix principi que `email_queue`).

**Pont `user_notifications`:** **descartat**. S'usa `data.notifications` (in-app) via `InAppAdapter` del motor.

---

### D7 — Adjunts de comentaris

**Decisió:** reutilitzar `request-upload` / `confirm-upload` amb:

- Path: `entity-comments/{tenantId}/{entityType}/{entityId}/{commentId}/{fileId}`
- `file_nodes.metadata.source = 'entity_comment'`
- `entity_comments.attachments` = jsonb array `[{ file_id, name, mime, size_bytes }]`

**Retenció:** soft delete del comentari **no** esborra fitxers; hard delete (admin/service) o TTL futur.

---

### D8 — Webhooks sortints

**Decisió:** **Fase 3**, alineats amb arquitectura d'automatització (PGMQ + Edge Function `dispatch-webhook`).

V1/V2 no bloquegen el llançament de timeline sense webhooks.

---

### D9 — Events d'audit: un registre per operació (`EMPLOYEE_UPDATED`)

**Decisió:** **1 fila `audit_logs` per operació de domini** (una transacció / una crida RPC), no 1 fila per camp canviat.

Format del `payload`:

```json
{
  "changes": [
    { "field": "status", "old": "active", "new": "terminated" },
    { "field": "job_title", "old": "Tècnic", "new": "Cap de zona" }
  ]
}
```

La humanització (`message_vars`) inclou `changes[]` sencer; el frontend pot mostrar:
- 1 canvi: *"ha canviat l'estat de Actiu a Baixa"*
- N canvis: *"ha actualitzat 3 camps: estat, càrrec, telèfon"*

Els triggers d'audit existents que avui escriuen per camp s'han d'**agrupar** abans d'insertar (o es refactoritza el helper per acceptar un array de canvis).

---

### D10 — Visibilitat de comentaris (`visibility`)

**Decisió:** camp des de la migració inicial per evitar refactor quan el contacte vegi la timeline al portal.

```sql
visibility text NOT NULL DEFAULT 'internal'
  CHECK (visibility IN ('internal', 'tenant_member', 'contact'))
```

| Valor | Qui pot veure (V1) |
|-------|---------------------|
| `internal` | Només membres amb permís d'edició/lectura interna (default) |
| `tenant_member` | Tots els membres del tenant que veuen l'entitat |
| `contact` | Reservat per Fase posterior (portal client); filtrat a RPC |

V1 només persisteix el camp; la UI mostra `internal` per defecte sense selector públic.

---

### D11 — Actors no humans (`actor_type`)

**Decisió:** comentaris i events poden tenir actor humà, IA o automatització.

A `entity_comments`:
- `user_id` **nullable** quan `actor_type IN ('ai', 'automation', 'system')`
- `actor_type text NOT NULL DEFAULT 'user'` CHECK (`user`, `ai`, `automation`, `system`)
- `actor_metadata jsonb` (opcional: `workflow_id`, `tool_name`, `model`)

A `audit_logs` (ja existent): continuar amb `payload.actor_type = 'ai'` per events generats per tools; la UI mostra icona distinta (robot/engranatge).

**Cas d'ús:** un workflow d'automatització deixa un comentari explicatiu a la timeline sense intervenció humana.

---

### D12 — Notes per a la IA (`is_ai_context_note`)

**Decisió:** boolean a `entity_comments` per marcar text que l'usuari escriu **expressament** perquè la IA el tingui en compte en futures converses sobre l'entitat.

- `is_ai_context_note boolean NOT NULL DEFAULT false`
- La tool `query_entity_timeline` accepta `includeAiContextNotes` i **prioritza** aquestes entrades al resum per al model
- Visual: badge discret "Nota per a la IA" al composer (toggle opcional)

Això connecta la timeline amb la **memòria persistent de la IA** (vegeu §5).

---

### D13 — Realtime (nous comentaris en temps real)

**Decisió:** V1 usa **refetch optimista** post-INSERT (simple, zero configuració). Fase 2 afegeix subscripció Supabase Realtime.

| Fase | Estratègia | Notes |
|------|-----------|-------|
| V1 | Client fa refetch parcial (primeres N files) després de INSERT propi | Resultat immediat per l'autor; altres usuaris veuen en propera càrrega |
| Fase 2 | Supabase Realtime `postgres_changes` filtrat per `entity_id` | Cada participant a la mateixa pàgina rep el nou comentari en temps real |

**Detalls Fase 2:**
```typescript
supabase.channel(`timeline:${entityType}:${entityId}`)
  .on('postgres_changes', {
    event: 'INSERT',
    schema: 'data',
    table: 'entity_comments',
    filter: `entity_id=eq.${entityId}`
  }, handleNewComment)
  .subscribe();
```
- RLS ja filtra per tenant; no cal canal autenticat especial
- Limit concurrència Realtime: vigilar a escala (Supabase Pro: 500 connexions simultànies)
- `UPDATE` (edicions, resolució tasca) i `DELETE` (soft: canvi `deleted_at`) igual via Realtime Fase 2

---

### D14 — Watermark de lectura per entitat

**Decisió:** taula lleugera `data.entity_timeline_watermarks` per mostrar badge "N items nous" per entitat, sense dependre de notificacions globals.

```sql
CREATE TABLE data.entity_timeline_watermarks (
  user_id       uuid NOT NULL REFERENCES data.profiles(id) ON DELETE CASCADE,
  tenant_id     uuid NOT NULL,
  entity_type   text NOT NULL,
  entity_id     uuid NOT NULL,
  last_seen_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, entity_type, entity_id)
);
```

- **RPC `mark_entity_timeline_seen(p_entity_type, p_entity_id)`** — `INSERT ... ON CONFLICT DO UPDATE`; cridat quan l'usuari obre el tab Activitat
- **Unread count:** `SELECT count(*) FROM (audit + comments) WHERE created_at > watermark.last_seen_at`; calculat a la mateixa crida `get_entity_timeline` com a camp `page.unread_since_last_visit`
- Valor UX alt: el tab Activitat pot mostrar badge `●` o `(3 nous)` sense cap infraestructura extra

---

### D15 — Historial d'edicions de comentaris

**Decisió:** taula `data.entity_comment_revisions` per traçabilitat en entorns HR/legal. Implica que **cap edició és silenciosa**.

```sql
CREATE TABLE data.entity_comment_revisions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  comment_id  uuid NOT NULL REFERENCES data.entity_comments(id) ON DELETE CASCADE,
  tenant_id   uuid NOT NULL,
  user_id     uuid REFERENCES data.profiles(id),  -- qui ha editat
  content_before text NOT NULL,
  edited_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_entity_comment_revisions_comment
  ON data.entity_comment_revisions (comment_id, edited_at DESC);
```

- El trigger `trg_entity_comments_updated_at` s'amplia (o un trigger separat) per inserir a `entity_comment_revisions` quan `content` canvia
- RPC `get_entity_comment_revisions(p_comment_id)` — accessible a autors + managers; mostra "editat N vegades" a la UI
- Finestra d'edició opcional (D9a — decisió oberta): permetre editar sense registrar revisió dins els primers N minuts (com Slack); per ara es registra sempre per ser conservadors en HR

---

### D16 — Versionat de contracte de payload

**Decisió:** afegir `schema_version: 1` al payload de comentaris retornats per la RPC i als webhooks, per evitar trencaments en futures evolucions.

- `entity_comments.actor_metadata` pot incloure `schema_version` per tipus custom
- Webhooks (Fase 3): header `X-Webhook-Schema-Version: 1`; el payload sempre inclou `"schema_version": 1` al nivell arrel
- Quan evolucionem el format, incrementem versió + documentem canvis al CHANGELOG d'integradors
- **Benefici immediat:** la tool IA `query_entity_timeline` pot fer parsing defensiu per versió

---

### D17 — Rendiment de `can_view_entity` / `can_edit_entity`

**Decisió:** les funcions RBAC s'han de marcar `STABLE` i implementar amb `CASE entity_type` inline per evitar plans de consulta subòptims.

**Problema:** si `can_view_entity` fa JOIN o subquery per cada fila, el pla d'execució de la RLS pot multiplicar el cost per N files retornades.

**Solució:**
```sql
CREATE OR REPLACE FUNCTION data.can_view_entity(
  p_user_id uuid, p_tenant_id uuid, p_entity_type text,
  p_entity_id uuid, p_site_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT CASE p_entity_type
    WHEN 'employee' THEN data.jwt_has_permission(p_tenant_id, 'hr.view', p_site_id)
    WHEN 'contact'  THEN /* membre actiu del tenant */ TRUE
    WHEN 'project'  THEN /* membre actiu */            TRUE
    WHEN 'document' THEN data.jwt_has_permission(p_tenant_id, 'documents.view', p_site_id)
    ELSE FALSE
  END;
$$;
```
- `LANGUAGE sql` + `STABLE` permet al planner fer inlining i evitar crida de funció per fila
- **Alternativa per RLS pesada:** moure la validació d'entitat a la RPC (`set-based check` a l'inici) i simplificar la RLS a `tenant_id = active_tenant_id() AND EXISTS(tenant_members)` — la RPC és el punt d'autorització real
- Mesura: benchmarcar amb `EXPLAIN ANALYZE` sobre entitats amb >1.000 comentaris

---

## 2) Model de dades complet

### 2.1 `data.entity_comments`

```sql
CREATE TABLE data.entity_comments (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id             uuid REFERENCES data.sites(id) ON DELETE SET NULL,
  entity_type         text NOT NULL,
  entity_id           uuid NOT NULL,
  user_id             uuid REFERENCES data.profiles(id),  -- NULL si actor_type != 'user'
  actor_type          text NOT NULL DEFAULT 'user'
                      CHECK (actor_type IN ('user', 'ai', 'automation', 'system')),
  actor_metadata      jsonb NOT NULL DEFAULT '{}',
  content             text NOT NULL,
  parent_id           uuid REFERENCES data.entity_comments(id) ON DELETE RESTRICT,
  mentions            uuid[] NOT NULL DEFAULT '{}',
  attachments         jsonb NOT NULL DEFAULT '[]',
  visibility          text NOT NULL DEFAULT 'internal'
                      CHECK (visibility IN ('internal', 'tenant_member', 'contact')),
  is_task             boolean NOT NULL DEFAULT false,
  is_ai_context_note  boolean NOT NULL DEFAULT false,
  due_date            timestamptz,  -- opcional Fase 2
  resolved_at         timestamptz,
  resolved_by         uuid REFERENCES data.profiles(id),
  pinned_at           timestamptz,  -- Fase 2
  pinned_by           uuid REFERENCES data.profiles(id),
  edited_at           timestamptz,
  revision_count      integer NOT NULL DEFAULT 0,       -- desnormalitzat per UI "editat N vegades"
  reply_count         integer NOT NULL DEFAULT 0,       -- desnormalitzat per evitar COUNT(*) a cada RPC
  deleted_at          timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT entity_comments_content_not_empty
    CHECK (length(trim(content)) > 0 OR deleted_at IS NOT NULL),

  CONSTRAINT entity_comments_no_self_parent
    CHECK (parent_id IS NULL OR parent_id <> id),

  CONSTRAINT entity_comments_user_required_for_human
    CHECK (actor_type = 'user' AND user_id IS NOT NULL
        OR actor_type <> 'user')
);

-- Només un nivell de profunditat: parent ha de ser arrel
-- (validat també a RPC insert/update)
CREATE OR REPLACE FUNCTION data.entity_comments_parent_must_be_root()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.parent_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.entity_comments p
      WHERE p.id = NEW.parent_id
        AND p.parent_id IS NULL
        AND p.tenant_id = NEW.tenant_id
        AND p.entity_type = NEW.entity_type
        AND p.entity_id = NEW.entity_id
        AND p.deleted_at IS NULL
    ) THEN
      RAISE EXCEPTION 'parent_id must reference a root comment on the same entity';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE INDEX idx_entity_comments_timeline
  ON data.entity_comments (tenant_id, entity_type, entity_id, created_at DESC)
  WHERE deleted_at IS NULL AND parent_id IS NULL;

-- Inclou arrels esborrades (placeholders D4) per a la RPC de timeline
CREATE INDEX idx_entity_comments_roots_all
  ON data.entity_comments (tenant_id, entity_type, entity_id, created_at DESC)
  WHERE parent_id IS NULL;

CREATE INDEX idx_entity_comments_replies
  ON data.entity_comments (parent_id, created_at ASC)
  WHERE deleted_at IS NULL;

CREATE INDEX idx_entity_comments_mentions_gin
  ON data.entity_comments USING gin (mentions);

CREATE INDEX idx_entity_comments_open_tasks
  ON data.entity_comments (tenant_id, entity_type, entity_id)
  WHERE is_task = true AND resolved_at IS NULL AND deleted_at IS NULL;

-- Índex per ai_context_notes (tool IA amb includeAiContextNotes)
CREATE INDEX idx_entity_comments_ai_context
  ON data.entity_comments (tenant_id, entity_type, entity_id, created_at DESC)
  WHERE is_ai_context_note = true AND deleted_at IS NULL;

-- Manteniment de reply_count desnormalitzat
CREATE OR REPLACE FUNCTION data.entity_comments_update_reply_count()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' AND NEW.parent_id IS NOT NULL THEN
    UPDATE data.entity_comments
    SET reply_count = reply_count + 1
    WHERE id = NEW.parent_id;
  ELSIF TG_OP = 'UPDATE'
    AND NEW.deleted_at IS NOT NULL
    AND OLD.deleted_at IS NULL
    AND NEW.parent_id IS NOT NULL THEN
    -- soft delete d'una resposta: decrementar
    UPDATE data.entity_comments
    SET reply_count = GREATEST(reply_count - 1, 0)
    WHERE id = NEW.parent_id;
  END IF;
  RETURN NULL;
END;
$$;
```

### 2.2 Taules auxiliars (D14, D15)

```sql
-- D14: Watermarks de lectura per entitat+usuari
CREATE TABLE data.entity_timeline_watermarks (
  user_id      uuid NOT NULL REFERENCES data.profiles(id) ON DELETE CASCADE,
  tenant_id    uuid NOT NULL,
  entity_type  text NOT NULL,
  entity_id    uuid NOT NULL,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, entity_type, entity_id)
);

CREATE INDEX idx_entity_timeline_watermarks_tenant
  ON data.entity_timeline_watermarks (tenant_id, entity_type, entity_id);

-- D15: Historial d'edicions
CREATE TABLE data.entity_comment_revisions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  comment_id     uuid NOT NULL REFERENCES data.entity_comments(id) ON DELETE CASCADE,
  tenant_id      uuid NOT NULL,
  user_id        uuid REFERENCES data.profiles(id),
  content_before text NOT NULL,
  edited_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_entity_comment_revisions_comment
  ON data.entity_comment_revisions (comment_id, edited_at DESC);
```

### 2.3 Índex audit per timeline

```sql
CREATE INDEX IF NOT EXISTS idx_audit_logs_entity_timeline
  ON data.audit_logs (tenant_id, entity_type, entity_id, created_at DESC);
```

### 2.4 Notificacions i retenció

**In-app:** `data.notifications` via Motor de Notificacions (`MENTION_CREATED`). Sense taula `user_notifications` paral·lela.

**Retenció `data.notifications`:** alineada amb el pla de notificacions — particions/TTL a F3 del motor; la timeline no afegeix una cua pròpia. Per comentaris esborrats, les notificacions ja enviades es mantenen (historial de safata).

**Cleanup comentaris:** opcional `pg_cron` futur per arxivar comentaris `deleted_at < now() - interval '2 years'` (compliance HR); V1 no esborra.

### 2.5 Webhooks (Fase 3)

```sql
CREATE TABLE data.tenant_webhooks (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  label         text NOT NULL,
  endpoint_url  text NOT NULL,
  secret        text NOT NULL,  -- per HMAC-SHA256
  events        text[] NOT NULL DEFAULT '{}',
  entity_types  text[],         -- NULL = tots
  is_active     boolean NOT NULL DEFAULT true,
  created_by    uuid REFERENCES data.profiles(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE data.webhook_delivery_log (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  webhook_id      uuid NOT NULL REFERENCES data.tenant_webhooks(id) ON DELETE CASCADE,
  event_type      text NOT NULL,
  payload         jsonb NOT NULL,
  status          text NOT NULL DEFAULT 'pending',  -- pending|delivered|failed
  attempts        integer NOT NULL DEFAULT 0,
  last_attempt_at timestamptz,
  response_status integer,
  response_body   text,
  created_at      timestamptz NOT NULL DEFAULT now()
);
```

### 2.6 RLS (patró projecte)

**Principi:** lectura només si l'usuari pot veure l'entitat pare; escriptura segons permisos d'edició de l'entitat.

```sql
-- Lectura: membre actiu del tenant + permís de lectura sobre entity_type
CREATE POLICY entity_comments_select ON data.entity_comments
  FOR SELECT TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND EXISTS (
      SELECT 1 FROM data.tenant_members tm
      WHERE tm.tenant_id = entity_comments.tenant_id
        AND tm.user_id = auth.uid()
        AND tm.is_active = true
    )
    AND data.can_view_entity(auth.uid(), tenant_id, entity_type, entity_id, site_id)
  );

-- Inserció/edició: mateix + permís d'escriptura
-- (implementar data.can_view_entity / data.can_edit_entity com helpers SECURITY DEFINER)
```

**Nota:** cal crear `data.can_view_entity` / `data.can_edit_entity` com a mapatge inicial:

| entity_type | Permís lectura | Permís escriptura |
|-------------|----------------|-------------------|
| `employee` | `hr.view` o rol manager+ | `hr.manage` |
| `contact` | membre actiu | manager+ |
| `project` | membre actiu | manager+ o permís projecte |
| `document` | ACL del document (`required_permissions`) | mateix ACL write |

Aquest mapatge evoluciona per entitat; V1 cobreix `employee`, `contact`, `project`, `document`.

### 2.7 Triggers

| Trigger | Quan | Acció |
|---------|------|-------|
| `trg_entity_comments_updated_at` | BEFORE UPDATE | `set_updated_at()` |
| `trg_entity_comments_extract_mentions` | BEFORE INSERT/UPDATE | extreu `mentions[]` del `content` |
| `trg_entity_comments_enqueue_notifications` | AFTER INSERT | `data.enqueue_entity_comment_notifications(id)` → PGMQ (asíncron) |
| `trg_entity_comments_audit_task_resolved` | AFTER UPDATE | si `resolved_at` passa de NULL → valor, escriu audit `COMMENT_TASK_RESOLVED` |
| `trg_entity_comments_reply_count` | AFTER INSERT/UPDATE | manté `reply_count` desnormalitzat al pare (D15) |
| `trg_entity_comments_revisions` | AFTER UPDATE | si `content` canvia: INSERT a `entity_comment_revisions` + `revision_count++` (D15) |
| `trg_entity_comments_enqueue_webhook` | AFTER INSERT/UPDATE | **Fet** — PGMQ `webhook_dispatch_queue` |

---

## 3) RPCs i Edge Functions

### 3.1 RPCs principals (`api.*`)

| RPC | Rol | Responsabilitat |
|-----|-----|-----------------|
| `get_entity_timeline(p_entity_type, p_entity_id, p_limit, p_cursor, p_cursor_id, p_include_audit, p_tasks_only, p_date_from, p_date_to)` | authenticated | Timeline unificada paginada |
| `get_entity_comment_replies(p_comment_id, p_limit, p_offset)` | authenticated | Respostes d'un arrel |
| `insert_entity_comment(...)` | authenticated | Crear comentari/resposta; valida profunditat, permisos, mencions |
| `update_entity_comment(p_id, p_content, p_is_task, p_due_date)` | authenticated | Editar (només autor o manager+) |
| `delete_entity_comment(p_id)` | authenticated | Soft delete |
| `resolve_entity_comment_task(p_id, p_resolved boolean)` | authenticated | Marcar/desmarcar tasca |
| `get_entity_open_tasks(p_entity_type, p_entity_id)` | authenticated | Tasques pendents d'una entitat |
| `get_my_open_tasks(p_limit, p_cursor)` | authenticated | Tasques pendents assignades/mencionades (Fase 2) |
| `search_tenant_members_for_mention(p_query, p_limit)` | authenticated | Autocomplete @mentions |
| `mark_entity_timeline_seen(p_entity_type, p_entity_id)` | authenticated | Actualitza watermark (D14); retorna `unread_count` |
| `get_entity_comment_revisions(p_comment_id)` | authenticated | Historial d'edicions (D15); només autor + manager+ |
| `get_user_notifications` | — | **Substituït** per vista `api.notifications` + motor existent |
| `mark_notification_read` | authenticated | Ja existeix: `api.mark_notification_read` |

**Signatura timeline (proposta):**

```sql
CREATE OR REPLACE FUNCTION api.get_entity_timeline(
  p_entity_type   text,
  p_entity_id     uuid,
  p_limit         integer DEFAULT 30,
  p_cursor        timestamptz DEFAULT NULL,
  p_cursor_id     uuid DEFAULT NULL,
  p_include_audit boolean DEFAULT true,
  p_tasks_only    boolean DEFAULT false,
  p_date_from     timestamptz DEFAULT NULL,
  p_date_to       timestamptz DEFAULT NULL
)
RETURNS jsonb;
```

**Retorn (per item):**

```json
{
  "items": [
    {
      "kind": "audit_event",
      "id": "...",
      "created_at": "...",
      "actor": { "id": "...", "full_name": "..." },
      "action": "EMPLOYEE_UPDATED",
      "message_key": "timeline.audit.EMPLOYEE_UPDATED",
      "message_vars": {
        "changes": [
          { "field": "status", "old": "active", "new": "terminated" }
        ],
        "change_count": 1
      },
      "payload": {}
    },
    {
      "kind": "comment",
      "id": "...",
      "created_at": "...",
      "author": { "id": "...", "full_name": "...", "avatar_url": "...", "actor_type": "user" },
      "content": "Text amb [[@uuid|Nom]]",
      "content_html": null,
      "mentions": [{ "id": "...", "full_name": "..." }],
      "attachments": [],
      "visibility": "internal",
      "is_task": true,
      "is_ai_context_note": false,
      "pinned_at": null,
      "resolved_at": null,
      "replies_count": 2,
      "replies_preview": [],
      "deleted": false
    }
  ],
  "page": {
    "has_more": true,
    "next_cursor": "...",
    "next_cursor_id": "...",
    "unread_since_last_visit": 3,
    "schema_version": 1
  }
}
```

### 3.2 Humanització — registre d'accions (mostra)

| action | message_key | message_vars (extractors) |
|--------|-------------|---------------------------|
| `EMPLOYEE_CREATED` | `timeline.audit.EMPLOYEE_CREATED` | `{ name: payload.full_name }` |
| `EMPLOYEE_UPDATED` | `timeline.audit.EMPLOYEE_UPDATED` | `payload.changes[]` — **1 event per operació** (D9) |
| `EMPLOYEE_TERMINATED` | `timeline.audit.EMPLOYEE_TERMINATED` | `{ name, ends_on }` |
| `CONTACT_ARCHIVED` | `timeline.audit.CONTACT_ARCHIVED` | `{ name }` |
| `DOCUMENT_VERSION_UPLOADED` | `timeline.audit.DOCUMENT_VERSION_UPLOADED` | `{ version, file_name }` |
| `SIGNING_SUBMISSION_STATUS_CHANGED` | `timeline.audit.SIGNING_STATUS` | `{ old_status, new_status }` |
| `PROJECT_STATUS_CHANGED` | `timeline.audit.PROJECT_STATUS` | `{ old, new }` |
| `COMMENT_TASK_RESOLVED` | `timeline.audit.TASK_RESOLVED` | `{ resolver_name, task_preview }` |
| `AI_DOCUMENT_GENERATED` | `timeline.audit.AI_ACTION` | `{ tool, model, actor_type: 'ai' }` |

**Events IA:** quan l'Edge Function o tool generi un document/acció, cridar `log_audit_event` amb:
- `user_id` = usuari que ha iniciat el xat
- `payload.actor_type = 'ai'`, `payload.tool_name`, `payload.model`

Plantilla: *"La IA (via {{tool_name}}) ha generat {{artifact}} en nom de {{user_name}}"*.

Implementació: funció SQL `data.timeline_audit_message_vars(p_action, p_payload)` amb CASE per acció; fallback genèric `timeline.audit.GENERIC`.

**Funció d'encuat de mencions (D6):**

```sql
CREATE OR REPLACE FUNCTION data.enqueue_entity_comment_notifications(p_comment_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_comment record;
  v_parent_author uuid;
  v_recipient uuid;
BEGIN
  SELECT * INTO v_comment FROM data.entity_comments WHERE id = p_comment_id;
  IF NOT FOUND THEN RETURN; END IF;

  -- Mencions explícites
  FOREACH v_recipient IN ARRAY v_comment.mentions LOOP
    IF v_recipient IS DISTINCT FROM v_comment.user_id THEN
      PERFORM data.enqueue_notification_dispatch(
        v_comment.tenant_id,
        v_recipient,
        'MENTION_CREATED',
        jsonb_build_object(
          'comment_id', v_comment.id,
          'entity_type', v_comment.entity_type,
          'entity_id', v_comment.entity_id,
          'author_id', v_comment.user_id
        ),
        'mention:' || p_comment_id::text || ':' || v_recipient::text
      );
    END IF;
  END LOOP;

  -- Autor del pare en resposta
  IF v_comment.parent_id IS NOT NULL THEN
    SELECT user_id INTO v_parent_author
    FROM data.entity_comments WHERE id = v_comment.parent_id;
    IF v_parent_author IS NOT NULL
       AND v_parent_author IS DISTINCT FROM v_comment.user_id
       AND NOT (v_parent_author = ANY(v_comment.mentions)) THEN
      PERFORM data.enqueue_notification_dispatch(
        v_comment.tenant_id,
        v_parent_author,
        'MENTION_CREATED',
        jsonb_build_object(
          'comment_id', v_comment.id,
          'entity_type', v_comment.entity_type,
          'entity_id', v_comment.entity_id,
          'author_id', v_comment.user_id,
          'is_reply', true
        ),
        'reply:' || p_comment_id::text || ':' || v_parent_author::text
      );
    END IF;
  END IF;
END;
$$;
```

El trigger només crida aquesta funció; cap I/O extern ni INSERT síncron a canals de lliurament.

### 3.3 Edge Functions

| Function | Fase | Responsabilitat |
|----------|------|-----------------|
| `request-upload` | V1 | Estendre per acceptar `source: 'entity_comment'` + validar quota |
| `confirm-upload` | V1 | Sense canvis estructurals; vincular `file_id` al comentari des del client o RPC |
| `dispatch-webhook` | V3 | Enviament asíncron amb HMAC, reintents, SSRF check |
| `process-webhook-queue` | V3 | Worker PGMQ (QueueRunner) |

**Seguretat webhooks (Fase 3):**
- Validació SSRF de `endpoint_url` (bloquejar IPs privades, localhost, metadata endpoints)
- Signatura `X-Webhook-Signature: sha256=...` amb secret del tenant
- Timeout 10s, màx 5 reintents amb backoff exponencial

---

## 4) Components UI (tenant-portal)

| Component | Responsabilitat |
|-----------|-----------------|
| `EntityTimeline` | Container: infinite scroll, filtres (tasques, audit, dates), loading/error |
| `TimelineEvent` | Event d'audit humanitzat: icona per `action`, actor (humà/IA/automation), temps relatiu, diff destacat |
| `TimelineComment` | Comentari arrel: autor, contingut amb mencions, adjunts, badge tasca/IA/pinned, accions |
| `TimelineCommentReply` | Resposta inline sota l'arrel |
| `TimelineComposer` | Textarea + @mentions autocomplete + adjunts + toggle "És una tasca" + toggle "Nota per a la IA" (Fase 2) |
| `TaskBadge` | Checkbox visual + estat pendent/resolt |
| `MentionAutocomplete` | Cerca membres del tenant (`search_tenant_members_for_mention`) |
| `TimelineAttachmentList` | Llista d'adjunts amb preview/download via storage URLs |
| `EntityActivityTab` | Wrapper per integrar timeline a pàgines de detall |

### Integració per pàgina

1. **`EmployeeDetailPage`**: nou tab `activity` a `EmployeeDetailTabs`
2. **`ContactDetailPage`**: secció `<EntityTimeline entityType="contact" entityId={id} />` després de dades principals
3. **`ProjectDetailPage`**: secció Activitat després del header
4. **`DocumentDetailPage`**: tab/secció Activitat

### Deep links (V1)

Format: `/employees/{id}?tab=activity&comment={commentId}`

El component llegeix query params i fa scroll + highlight temporal al comentari/event.

---

## 5) Integració IA — memòria persistent per entitat

La timeline no és només UI: és el **context persistent** que la IA carrega quan l'usuari parla d'una entitat concreta.

### Tool `query_entity_timeline` ✅ (2026-06-24)

Implementat a `supabase/functions/_shared/ai/tools/query-entity-timeline.ts`. Crida `api.get_entity_timeline_for_ai` amb `tenant_id` + `user_id` del context i verifica `can_view_entity`.

```typescript
// supabase/functions/_shared/ai/tools/query-entity-timeline.ts
export const queryEntityTimelineTool = defineTool({
  name: "query_entity_timeline",
  risk: "read",
  requiredPermission: "ai.use",
  // ...
});
```

**Permisos:** reutilitzar el mateix `can_view_entity` que la UI. La IA **no pot** veure timelines d'entitats inaccessibles per l'usuari del prompt.

### Càrrega automàtica de context (Fase 2 IA)

Quan el xat detecta referència a una entitat resolta (p.ex. "com va l'empleat Joan Martí?"), el router d'agents pot cridar `query_entity_timeline` **proactivament** abans de respondre — sense que l'usuari ho demani explícitament. Això diferencia l'experiència d'un ERP tradicional: la resposta incorpora historial real (canvis d'estat, notes d'RRHH, tasques resoltes), no només l'estat actual de les taules.

### Notes per a la IA (`is_ai_context_note`)

L'usuari pot marcar un comentari com a "nota per a la IA" (toggle al composer). Aquestes entrades es prioritzen al context del model i es mostren amb badge discret a la UI. Equivalent conceptual als "AI context blocks" de Notion.

**Casos d'ús:**
- "Resumeix l'activitat recent de l'empleat Joan" → `query_entity_timeline` + `query_employees`
- "Aquest empleat té clàusula especial al contracte" → comentari amb `is_ai_context_note = true`; futures converses sobre ell ho tenen en compte
- Workflow d'automatització → `insert_entity_comment` amb `actor_type = 'automation'` documenta l'acció sense intervenció humana

---

## 6) Funcionalitats addicionals — estat d'implementació

| Funcionalitat | Fase | Estat (2026-06-24) |
|---------------|------|-------------------|
| Filtre per origen (audit vs manual) | V1 | ✅ `TimelineFilters` |
| Filtre per rang de dates | V1 | ✅ RPC + UI |
| Deep links | V1 | ✅ `?tab=activity&comment=<uuid>` |
| Watermark de lectura per entitat | V1 | ✅ Badge tab + `mark_entity_timeline_seen` |
| Realtime nous comentaris | 2 | ✅ `useEntityTimelineRealtime` |
| Historial d'edicions | V1 | ✅ `CommentRevisionsDialog` |
| Pinning de comentaris | 2 | ✅ `pin_entity_comment` |
| Plantilles de comentari | 2 | ✅ `CommentTemplatePicker` |
| Read receipts en tasques | 2 | ✅ `MentionReadReceipts` |
| Cerca dins timeline | 2 | ✅ GIN + `p_search` |
| `due_date` + recordatori cron | 2 | ✅ `entity_task_due_reminders` |
| Subscripció a entitat | 2 | ✅ `EntitySubscriptionToggle` |
| Finestra d'edició sense revisió | 2 | ⬜ No implementat |
| Tool IA `query_entity_timeline` | 2 | ✅ Edge tool + RPC `get_entity_timeline_for_ai` |
| Toggle «Nota per a la IA» | 2 | ✅ `is_ai_context_note` al composer |
| Entity Memory Score | 2 | ✅ `compute_entity_memory_score` |
| Resums vius (`TimelineSummaryBanner`) | 2 | ✅ Resum estructurat (sense LLM) |
| Agrupació audit consecutius | 2 | ✅ `TimelineAuditGroup` |
| Events en segon pla (`is_background`) | 2 | ✅ Filtre UI (ocults per defecte) |
| Timeline agregada tenant | 3 | ✅ Fet (F3.4) |
| Export CSV/PDF + hash | 3 | ⬜ Pendent |
| Risk Detector / Playbooks | 3 | ✅ F3.6 + F3.7 |
| Reaccions emoji | posterior | ⬜ Pendent |
| Edge Function `summarize-entity-activity` (LLM) | 2 opc. | ⬜ Pendent |

---

## 7) Fases d'implementació

### Fase 1 — MVP timeline ✅ (tancada 2026-06)

**Migracions:** `20260705000001` … `20260705000008` (+ `20260705000002` audit employee changes)

**Entregables (tots fets):**
- Schema `entity_comments`, watermarks, revisions, RLS, `can_view/edit_entity`
- RPCs core de timeline, mencions asíncrones (`MENTION_CREATED`)
- UI tab Activitat a **empleats** i **contactes**; badge «N nous»; deep links
- Adjunts, tasques, respostes, edicions amb historial

**Criteris d'acceptació:** verificats manualment en dev local (veure §7.1).

---

### Fase 2 — Tasques, filtres, IA i més entitats ✅ (tancada 2026-06-24)

**Migracions:** `20260705000009` … `20260705000023`

| Entregable | Estat | Migració / codi principal |
|------------|-------|---------------------------|
| Integració projectes i documents | ✅ | `ProjectDetailPage`, `DocumentDetailPage` |
| Filtres UI (tasques, dates, cerca, background) | ✅ | `20260705000010`, `20260705000020`, `TimelineFilters` |
| `get_my_open_tasks` + widget dashboard | ✅ | `20260705000014`, `OpenTasksWidget` |
| `due_date` + cron recordatori | ✅ | `20260705000016` |
| `entity_subscriptions` | ✅ | `20260705000017` |
| Pinning | ✅ | `20260705000012`, `20260705000013` |
| Plantilles de comentari | ✅ | `20260705000015` |
| Read receipts (`mentions_read`) | ✅ | `20260705000019` |
| Realtime `postgres_changes` | ✅ | `20260705000009`, `useEntityTimelineRealtime` |
| Agrupació audit client-side | ✅ | `groupAuditEvents.ts`, `TimelineAuditGroup` |
| Tool IA `query_entity_timeline` + memory score | ✅ | `20260705000022`, `query-entity-timeline.ts` |
| Toggle «Nota per a la IA» | ✅ | `20260705000022`, `TimelineComposer` |
| `TimelineSummaryBanner` | ✅ | `20260705000023`, resum estructurat (no LLM) |
| Notificacions realtime (badge campana) | ✅ | `20260705000018` (motor notificacions) |

**Pendent / opcional dins Fase 2:**
- Edge Function `summarize-entity-activity` (resum narratiu LLM al banner)
- Finestra d'edició sense deixar revisió (Slack-style)

**Criteris d'acceptació:** veure checklist §7.1 i §12.

---

### 7.1 Catàleg de funcionalitats i com provar-les

**Prerequisits locals** (veure `DEV_RUNBOOK.md`):

```bash
supabase db reset          # aplica migracions 20260705000001–23 + seed
cd apps/tenant-portal && npm run dev
```

**Usuari de prova:** `alice@acme-corp.com` (owner Acme Corp) — empleat seed `40000000-0000-0000-0000-000000000001` (Alice).

**On trobar la timeline:**

| Entitat | Ruta UI |
|---------|---------|
| Empleat | `/employees/<id>` → tab **Activitat** |
| Contacte | `/contacts/<id>` → secció **Activitat** |
| Projecte | `/projects/<id>` → secció **Activitat** |
| Document | `/documents/<id>` → secció **Activitat** |
| Tasques agregades | `/` (dashboard) → widget **Tasques obertes** |

---

#### Nucli (Fase 1)

| Funcionalitat | Què fa | Com provar-ho |
|---------------|--------|---------------|
| **Timeline unificada** | Mostra comentaris + events audit ordenats cronològicament | Obre empleat Alice → tab Activitat; edita el seu nom a la pestanya Info i torna a Activitat → apareix event «ha actualitzat nom» |
| **Composer** | Publicar comentaris de text | Escriu un comentari i **Publicar** |
| **Mencions `@`** | Notifica membres del tenant | Escriu `@Charlie` al composer → publica; inicia sessió com Charlie → campana amb notificació |
| **Tasques** | Comentari marcat com a tasca pendent/resolta | Marca «És una tasca» → publica → **Marcar com a resolta** → event audit a la timeline |
| **Adjunts** | Fitxers vinculats al comentari | Icona adjunt al composer → puja fitxer petit → es veu a la timeline |
| **Respostes** | Fil de conversa sota un comentari | **Respondre** → escriu resposta |
| **Edició + historial** | `entity_comment_revisions` | **Editar** un comentari propi → **Historial** mostra versió anterior |
| **Soft delete** | Placeholder «Comentari eliminat» | Elimina comentari (autor o manager) |
| **Paginació** | Cursor `get_entity_timeline` | **Carregar més** si hi ha >30 items |
| **Badge «N nous»** | Items des de `last_seen_at` | Obre Activitat sense entrar abans → badge al tab; entra i desplaça't o tanca el banner → badge desapareix |
| **Deep link** | Navegació des de notificació | Clica notificació de menció → URL `?tab=activity&comment=<uuid>` i ressalt del comentari |
| **Filtre dates** | `p_date_from` / `p_date_to` | Filtres → «Darrers 7 dies» o rang personalitzat |
| **Filtre audit** | Amagar/mostrar events sistema | Desmarca «Events del sistema» |

---

#### Fase 2 — operacions i UX

| Funcionalitat | Què fa | Com provar-ho |
|---------------|--------|---------------|
| **Cerca full-text** | Cerca dins comentaris (i respostes) de l'entitat | Filtre cerca → text parcial d'un comentari existent |
| **Només tasques / obertes** | Filtra per `is_task` i `resolved_at` | Filtres «Només tasques» / «Només tasques obertes» |
| **Events en segon pla** | Audit `is_background=true` ocults per defecte | Marca «Events en segon pla» per veure'ls; events agrupats mostren badge «Automàtic» |
| **Agrupació audit** | Col·lapsa `EMPLOYEE_UPDATED` consecutius (mateix actor, mateix minut) | Desa l'empleat canviant 2+ camps ràpid → un sol grup expandible |
| **Pinning** | Comentaris fixats sempre a dalt | **Fixar a dalt** en un comentari → roman primer independentment de la data |
| **Plantilles** | Text predefinit des de `entity_comment_templates` | Selector plantilles al composer → aplica text |
| **Subscripció** | Seguir entitat per rebre notificacions d'activitat | Toggle «Seguir» a la capçalera de la timeline |
| **Venciment tasca** | `due_date` + recordatori diari (cron) | Crea tasca amb data de venciment → dia següent (o crida manual `SELECT data.process_entity_task_due_reminders()`) |
| **Read receipts** | Qui ha llegit una menció en tasca | Crea tasca amb `@menció` → l'usuari mencionat obre el comentari → autor veu «Vist per…» |
| **Realtime** | Nous comentaris sense refrescar | Dos navegadors al mateix empleat Activitat → publica des d'un → apareix a l'altre |
| **Tasques obertes (dashboard)** | `get_my_open_tasks` agregat | Dashboard → llista tasques pendents amb enllaç a l'entitat |
| **Tasques manager** | Vista global si rol owner/manager | Login Alice → dashboard mostra tasques de tot el tenant |

---

#### Fase 2 — IA i context

| Funcionalitat | Què fa | Com provar-ho |
|---------------|--------|---------------|
| **Nota per a la IA** | `is_ai_context_note=true` prioritza context del xat | Composer → marca «Nota per a la IA» → publica → badge **Nota IA** al comentari |
| **`query_entity_timeline`** | Tool IA llegeix historial amb RBAC + memory score | Xat IA (permís `ai.use`): *«Resumeix l'activitat recent de l'empleat Alice»* → crida `query_employees` + `query_entity_timeline` |
| **Memory score** | Ordena items per rellevància (notes IA, tasques, recència…) | A la resposta de la tool, camps `memory_score` i `narrative` ordenats |
| **TimelineSummaryBanner** | Resum estructurat des de l'última visita (≥6 items nous) | Obre Activitat sense visitar-la després de 6+ events nous → banner violet; tanca amb X |

**SQL ràpid (resum de visita):**

```sql
SELECT api.get_entity_timeline_visit_summary(
  'employee', '40000000-0000-0000-0000-000000000001'
);
```

**SQL ràpid (timeline IA):**

```sql
-- Només service_role / edge function en producció
SELECT api.get_entity_timeline_for_ai(
  '10000000-0000-0000-0000-000000000001',  -- tenant Acme
  '20000000-0000-0000-0000-000000000002',  -- user Alice
  'employee',
  '40000000-0000-0000-0000-000000000001',
  20, true, NULL, NULL
);
```

---

#### Mapa de migracions timeline

| Rang | Contingut |
|------|-----------|
| `20260705000001` | Core F1: schema, RPCs, RLS, watermarks |
| `20260705000002`–`08` | Audit employee changes, adjunts, delete, mencions |
| `20260705000009` | Realtime publication |
| `20260705000010` | Cerca full-text |
| `20260705000012`–`13` | Pinning |
| `20260705000014` | `get_my_open_tasks` |
| `20260705000015` | Plantilles comentari |
| `20260705000016` | `due_date` + cron recordatoris |
| `20260705000017` | Subscripcions entitat |
| `20260705000018` | Realtime notificacions (badge campana) |
| `20260705000019` | Read receipts |
| `20260705000020`–`21` | `is_background` audit + fix overload `log_audit_event` |
| `20260705000022` | Bloc IA: memory score, `get_entity_timeline_for_ai`, `is_ai_context_note` |
| `20260705000023` | `get_entity_timeline_visit_summary` (banner) |
| `20260707000001` | F3 webhooks: taules, PGMQ, triggers, RPCs, worker |
| `20260707000002` | F3 export CSV auditable + hash integritat |
| `20260707000003` | F3 timeline agregada tenant (`get_tenant_timeline_activity`) |
| `20260708000001` | F3 Risk Detector: regles, incidents, PGMQ, cron |
| `20260708000002` | F3 Playbooks: audit → tasques sistema + worker |
| `20260708000003` | Fix PGRST203: una sola signatura `get_entity_timeline` |

**Mòdul UI:** `apps/tenant-portal/src/features/entity-timeline/`

---

### Fase 3 — Webhooks, export i dashboard — **gairebé tancada**

| # | Entregable | Estat |
|---|------------|--------|
| F3.1 | Taules `tenant_webhooks` + `webhook_delivery_log` + PGMQ + worker | **Fet** (`20260707000001`) |
| F3.2 | UI `/settings/webhooks` (CRUD + log + test) | **Fet** |
| F3.3 | Export CSV/PDF + hash `pgcrypto` (§10.5) | **Fet** — `get_entity_timeline_export` + `export-entity-timeline` |
| F3.4 | Timeline agregada «activitat avui» (managers) | **Fet** — `get_tenant_timeline_activity` + `TenantActivityWidget` |
| F3.5 | `actor_type` automation/ai des de workflows | **Fet** — `20260708000004` + `insert_entity_comment_service` + tool `post_entity_timeline_comment` |
| F3.6 | Risk Detector (`entity_risk_rules` + cron) | **Fet** — `20260708000001` + `process-risk-detector-queue` |
| F3.7 | Playbook Awareness (`audit_event_playbooks`) | **Fet** — `20260708000002` + `process-playbook-queue` |
| F3.8 | SLOs actius (`get_entity_timeline` p95) | **Fet** — `20260708000005` + mostreig + `get_entity_timeline_slo_stats` + cron 15 min |

**Bugfix 2026-06:** la migració de playbooks havia creat una **segona sobrecàrrega** de `api.get_entity_timeline`, provocant error PostgREST `PGRST203` («function is not unique») i el missatge UI «Error en carregar l'activitat». Corregit a `20260708000003`.

**Entregables originals:**
- Taules `tenant_webhooks`, `webhook_delivery_log`
- Edge Functions `dispatch-webhook` + worker PGMQ
- UI `/settings/integrations` (CRUD webhooks + log + test)
- Export CSV de timeline + PDF opcional + hash d'integritat `pgcrypto` (§10.5)
- Timeline agregada "activitat avui" per managers
- Comentaris `actor_type = 'automation'|'ai'` des de workflows (integració automatització V2)
- Risk Detector: `entity_risk_rules` + worker cron (§10.3)
- Playbook Awareness: `audit_event_playbooks` (§10.4)
- SLOs actius: alerta si `get_entity_timeline` p95 > 500ms

**Criteris d'acceptació:**
- Webhook Slack rep payload signat en crear comentari
- Export CSV inclou events + comentaris + hash verificable
- Workflows poden inserir comentaris amb `actor_type = 'automation'`
- Risk Detector genera notificació per tasca vencuda >7 dies

---

## 8) Riscos i mitigacions

| Risc | Impacte | Mitigació |
|------|---------|-----------|
| Explosió de volum audit per entitats molt actives | Timeline lenta | Cursor pagination + límit default 30; índex compost; `p_date_from`/`p_date_to`; opció "només comentaris" |
| `can_view_entity` cridat per fila en RLS | RPC lenta a escala | `LANGUAGE sql STABLE`; inlining per `entity_type`; alternativa: validació una vegada a la RPC (D17) |
| RBAC inconsistent entre entitats | Fuites o bloquejos | Helpers centralitzats `can_view/edit_entity`; tests d'integració per entity_type |
| Mencions a usuaris externs o inactius | Notificacions fallides | Validar UUIDs contra `tenant_members.is_active` en INSERT |
| Spam de comentaris | Soroll operatiu | Rate limit per usuari (p.ex. 30/min) a RPC insert |
| Adjunts orfes | Cost storage | Vincular `file_id` a comentari en confirm; cleanup cron futur (patró ai-chat) |
| Humanització incompleta d'accions noves | Events genèrics | Fallback `GENERIC` + alerta dev quan apareix action sense template |
| Notificacions duplicades | UX dolenta | `correlationId` determinista al motor (`mention:{id}:{user}`) |
| Trigger bloqueja INSERT de comentari | Latència / errors en mencions | Encuat asíncron via PGMQ (D6); trigger només crida SQL lleuger |
| Webhooks SSRF | Seguretat crítica | Validació URL + allowlist protocols https + block private IP ranges |
| Soroll de events sistèmics similars | UX dolenta | Agrupació visual client-side: events `EMPLOYEE_UPDATED` consecutius del mateix minut mostrats col·lapsats |
| Privacitat notes IA (`is_ai_context_note`) | Compliance GDPR | Export individual `GET /api/my-ai-context-notes`; supressió selectiva; política retenció = vida del tenant |
| Deriva del contracte de payload (webhooks/tools) | Trencaments d'integració | `schema_version` al retorn RPC i header webhook (D16); CHANGELOG d'integradors |
| Sobrecàrregues RPC duplicades | Timeline no carrega (PGRST203) | Una sola signatura per RPC; migració `DROP FUNCTION` abans de `CREATE OR REPLACE` amb nous paràmetres (`20260708000003`) |

---

## 8.1) Impacte en rendiment i feature flags (Risk Detector + Playbooks)

### Poden enlentir tota l'app?

**No el flux principal de navegació**, si el disseny actual es respecta:

| Component | Impacte en UX síncrona | Notes |
|-----------|------------------------|-------|
| `get_entity_timeline` | **Directe** — és el feed que l'usuari obre | Ha de mantenir una sola signatura RPC; p95 objectiu < 300ms |
| `get_entity_risk_alerts` | **Lleu** — 1 query extra en obrir timeline | Només lectura; sense worker |
| Risk Detector cron | **Cap** — async (pg_cron + PGMQ) | Escaneig batch fora del request HTTP |
| Playbook trigger | **Mínim** — trigger només encua PGMQ | Worker crea comentaris en background |
| Workers (`process-*-queue`) | **Cap** en UI | Comparteixen infra de notificacions/webhooks |

**Riscos reals a escala:** scans diaris cross-tenant sense límit, molts incidents/notificacions, o tenants amb milers d'audits/dia. Mitigacions ja aplicades: dedup (`entity_risk_incidents`, `audit_event_playbook_runs`), paginació timeline, índexs compostos, workers amb batch size 50.

### Convé limitar a plans superiors?

**Recomanació: sí, com a funcionalitat «Pro / Enterprise»** (o equivalent):

| Funcionalitat | Per què limitar |
|---------------|-----------------|
| **Timeline base** (comentaris + audit) | Core — tots els plans |
| **Webhooks + export CSV** | Integració / compliance — Pro+ |
| **Risk Detector** | Automatització proactiva + cost notificacions — Pro+ |
| **Playbooks** | SOPs automatitzats — Pro+ o Enterprise |
| **Activitat avui** (dashboard agregat) | Manager tooling — Pro+ |

Els tenants petits no necessiten 5 regles de risc ni checklists de baixa; redueix soroll i cost operatiu.

### Model de configuració recomanat (admin-portal)

Ja existeix infraestructura de **feature flags** (`data.feature_flags`, `data.tenant_feature_overrides`, `data.is_feature_enabled`) — mateix patró que signing.

**Claus proposades:**

| `feature_key` | Descripció |
|---------------|------------|
| `entity_timeline_risk_detector` | Activa cron scan + workers + UI settings |
| `entity_timeline_playbooks` | Activa trigger audit + worker + UI settings |
| `entity_timeline_webhooks` | Webhooks externs |
| `entity_timeline_export` | Export CSV auditable |
| `entity_timeline_manager_feed` | Widget «Activitat avui» |

**Nivells de control (cascada):**

1. **Global** (`feature_flags.is_enabled` + `rollout_percentage`) — admin-portal: activar/desactivar per tota la plataforma o rollout gradual.
2. **Per pla de subscripció** — taula `plan_features` (futur) o metadata del pla: «Pro inclou risk_detector».
3. **Per tenant** (`tenant_feature_overrides`) — admin-portal: forçar ON/OFF per client concret (pilot, beta, downgrade).

**On aplicar el gate (quan s'implementi):**

```sql
-- Gate al scan (implementat F3.9)
IF NOT data.is_feature_enabled(v_tenant_id, 'entity_timeline_risk_detector') THEN
  RETURN 0;
END IF;
```

- **Cron workers:** `scan_entity_risk_rules()` filtra regles per tenant amb feature activa.
- **Triggers playbooks / webhooks / churn:** surten aviat si feature desactivada.
- **RPCs:** `require_entity_timeline_feature` o retorn buit (`get_tenant_timeline_activity`, `get_entity_risk_alerts`).
- **UI tenant-portal:** `api.get_tenant_features()` → amaga tabs, export CSV, banner de risc i widget «Activitat avui».

**Estat actual (F3.9 fet):** migracions `20260708000006` + `20260708000007`; seed local desactiva features Pro per **Beta Startup** (`10000000-…0002`); **Acme Corp** les manté actives.

---

## 9) Escalabilitat i observabilitat

### Camí d'escala previsible

| Fase de creixement | Característica | Senyal de saturació | Acció |
|-------------------|----------------|---------------------|-------|
| **Inicial** (<5k entities actives) | Model actual: UNION ALL sota demanda | p95 < 200ms | — |
| **Creixement** (5k–50k entities) | Índexs compostos saturats; joins pesats | p95 > 500ms | Activar `p_date_from` per defecte últims 90 dies; revisar plans EXPLAIN |
| **Enterprise** (>50k o audits massius) | UNION ALL massa costós | p95 > 1s | Snapshot/denorm: `timeline_feed` taula materialitzada actualitzada per trigger asíncron (PGMQ); RPC llegeix de snapshot + appends recents |

**Snapshot architecture (si cal):**
```
INSERT audit_log / entity_comment
  → trigger → PGMQ "timeline_snapshot_queue"
  → worker → UPDATE timeline_feed (per entitat, paginat)
```
El client sempre llegeix `timeline_feed`; el worker manté fresca la taula (~5s lag acceptable). Alternativa lleugera: `pg_cron` cada minut que materialitza les entitats modificades.

### SLOs proposats (V1)

| Operació | Target p95 | Alerta |
|----------|-----------|--------|
| `get_entity_timeline` (primer fetch) | < 300ms | > 500ms |
| `insert_entity_comment` | < 150ms | > 300ms |
| Lliurament notificació in-app post-INSERT | < 5s (worker async) | > 30s |
| Watermark update (`mark_entity_timeline_seen`) | < 50ms | > 200ms |

### Mètriques de producte (Observabilitat)

Afegir a la Edge Function / Sentry / Datadog (o `pg_stat_statements`):

- **Volum:** `comments_inserted_per_tenant_per_day`, `timeline_fetches_per_entity`
- **Rendiment:** `p50/p95/p99` de `get_entity_timeline` per `entity_type`
- **Mencions:** % mencions amb `delivery_status = succeeded` (motor)
- **Realtime:** connexions Supabase Realtime per canal actiu (quota Pro)
- **Error rate:** `insert_entity_comment` fallides per rate limit / validació

### Anti-soroll de la timeline

Events sistèmics massius (p.ex. importació de 100 empleats o cron de presència) poden col·lapsar la timeline. Estratègies:

1. **Agrupació client-side**: events amb el mateix `action` + `actor.id` dins finestra de 5 minuts → mostrar "N events similars" col·lapsable
2. **Camp `is_background` a `audit_logs`** (opcional, Fase 2): events de cron/batch marcats; filtrats per defecte a la UI
3. **Límit per tipus** a la RPC: `p_max_per_action integer DEFAULT NULL` per debug/compliance

---

## 10) Decisions obertes (requereixen input humà)

1. **Permisos de comentaris per rol `member`/`viewer`:** poden comentar tots els membres actius o només manager+? (Recomanació: tots poden comentar; només manager+ pot esborrar alienes.)
2. **Entitats V1:** confirmar prioritat després d'employee/contact — ¿project + document a Fase 1 o 2?
3. **Rich text:** V1 només text pla + mencions, o cal bold/links des del dia 1?
4. **Email en mencions:** resolt — Motor de Notificacions F2 ja envia email/push segons preferències quan s'activa `MENTION_CREATED`.
5. **Timeline agregada tenant:** és requisit per a MVP managers o es pot ajornar a Fase 3?
6. **Retenció legal:** cal política de retenció/immutabilitat de comentaris per compliance (HR/firmes)?

---

## 11) Innovació diferencial — Entity Intelligence

Aquesta secció recull conceptes que van **més enllà de les funcionalitats estàndard** i que poden convertir la timeline en un avantatge competitiu real respecte ERPs tradicionals.

### 10.1 Entity Memory Score (prioritització de context per la IA)

**Problema:** quan la IA rep la timeline d'un empleat amb 500 events, no tots els items aporten el mateix valor com a context. Passar-los tots al model és car i pot degradar la qualitat de resposta.

**Proposta:** funció `data.compute_entity_memory_score(p_comment_id)` que assigna un pes a cada item de la timeline:

| Factor | Pes |
|--------|-----|
| `is_ai_context_note = true` | +100 |
| `is_task = true AND resolved_at IS NOT NULL` | +30 |
| `is_task = true AND resolved_at IS NULL` | +50 |
| Menció explícita de l'usuari del xat | +40 |
| `actor_type = 'automation'` (acció de workflow) | +20 |
| Recència (> 7 dies) | +10 |
| Recència (> 90 dies) | 0 |
| Event audit d'alt impacte (`EMPLOYEE_TERMINATED`, `SIGNING_SUBMISSION_*`) | +25 |

La tool `query_entity_timeline` retorna items **ordenats per score DESC** quan el paràmetre `mode = 'ai_context'` s'activa. El model rep un context comprimit, dens i rellevant.

**Estat 2026-06-24:** implementat a `api.get_entity_timeline_for_ai` via `data.compute_entity_memory_score` (inline, sense persistir). La tool Edge `query_entity_timeline` retorna `memory_score` per item i un camp `narrative` agregat.

---

### 10.2 Resums vius d'entitat ("Novetats des de la teva última visita")

**Proposta:** quan l'usuari obre el tab Activitat d'una entitat que no ha visitat en >N hores, un component `TimelineSummaryBanner` crida a una Edge Function lleugera que:

1. Llegeix el watermark `entity_timeline_watermarks.last_seen_at` (D14)
2. Busca items nous des d'aleshores
3. Retorna un resum en text natural via LLM (model petit, baix cost): *"Des del 18 de juny: Estat canviat a Baixa, 2 tasques noves (1 pendent), 3 comentaris d'RRHH"*

**Estat 2026-06-24:** implementat amb **resum estructurat** (sense LLM):
- RPC `api.get_entity_timeline_visit_summary`
- Component `TimelineSummaryBanner` — es mostra si `unread_since_last_visit ≥ 6` i sense filtres actius
- Edge Function `summarize-entity-activity` queda com a millora opcional

---

### 10.3 Risk Detector — **implementat** (F3.6)

**Què fa:** vigilant proactiu que detecta patrons de risc (tasques vençudes, mencions no llegides, signatures pendents, rotació d'estat, threads sense resposta) i actua via notificacions i banners.

**Flux:** `pg_cron` → `scan_entity_risk_rules()` → `entity_risk_incidents` → PGMQ → `process-risk-detector-queue` → motor de notificacions.

**Configuració:** `/settings/risk-detector` (owner/manager). Migració `20260708000001`.

---

### 10.4 Playbook Awareness — **implementat** (F3.7)

**Què fa:** en un event d'auditoria (p.ex. `EMPLOYEE_TERMINATED`), crea automàticament tasques de protocol a la timeline (`actor_type = system`).

**Flux:** trigger `audit_logs` → PGMQ → `process-playbook-queue` → `insert_system_entity_comment`.

**Seed:** checklist de baixa (4 tasques) per tenant. Configuració: `/settings/playbooks`. Migració `20260708000002`.

---

### 10.5 Export auditable amb integritat criptogràfica

**Proposta:** per a ús legal/HR, l'export de la timeline d'una entitat inclou un hash SHA-256 de la seqüència d'events:

```
hash(event_1.id + event_1.created_at + event_1.action || event_2.id + ...)
```

Firmat amb la clau privada del tenant (o la plataforma). Permet demostrar que el registre no ha estat manipulat a posteriori en casos de litigis laborals.

**Implementació:** RPC `api.get_entity_timeline_export` (hash cadena SHA-256 via `pgcrypto`) + Edge Function `export-entity-timeline` (CSV amb metadades i hash al peu). PDF opcional — pendent.

---

## 12) Smoke tests operatius (post-desplegament)

Veure **§7.1** per la guia completa amb prerequisits i usuaris seed.

```sql
-- Timeline d'un empleat (amb filtre de dates opcional)
SELECT api.get_entity_timeline(
  'employee', '40000000-0000-0000-0000-000000000001', 20,
  NULL, NULL, true, false, false,
  now() - interval '30 days', NULL, NULL, false
);

-- Resum des de l'última visita (banner)
SELECT api.get_entity_timeline_visit_summary(
  'employee', '40000000-0000-0000-0000-000000000001'
);

-- Tasques obertes de l'usuari
SELECT api.get_my_open_tasks(10, NULL, NULL);

-- Notificacions in-app pendents
SELECT * FROM api.notifications
WHERE read_at IS NULL
ORDER BY created_at DESC
LIMIT 20;
```

**Checklist UI (regressió ràpida):**

| # | Prova | Resultat esperat |
|---|-------|------------------|
| 1 | Comentari amb `@mention` | Notificació in-app al destinatari |
| 2 | Respondre comentari | Notificació a l'autor del pare |
| 3 | Crear i resoldre tasca | Event audit `COMMENT_TASK_RESOLVED` |
| 4 | Soft delete comentari arrel amb respostes | Placeholder visible |
| 5 | Carregar més (cursor) | Paginació en històric llarg |
| 6 | Editar comentari | `revision_count` + historial |
| 7 | Obrir tab Activitat sense visitar abans | Badge «N nous»; banner si ≥6 items |
| 8 | Dos navegadors, mateixa entitat | Realtime: nou comentari sense F5 |
| 9 | Cerca + filtres tasques/dates | Resultats coherents |
| 10 | Pin + plantilla + subscripció | UX Fase 2 operativa |
| 11 | Nota per a la IA + pregunta al xat | Badge + tool amb memory score |
| 12 | Filtre «Events en segon pla» | Events `is_background` ocults per defecte |

---

## 13) Referències de codi

| Àrea | Fitxer |
|------|--------|
| **Mòdul UI timeline** | `apps/tenant-portal/src/features/entity-timeline/` |
| Migracions timeline | `supabase/migrations/20260705000001_entity_timeline_f1_core.sql` … `20260705000023_entity_timeline_visit_summary.sql` |
| Tool IA timeline | `supabase/functions/_shared/ai/tools/query-entity-timeline.ts` |
| Audit helper | `supabase/migrations/20260423000001_audit_triggers.sql` |
| Audit employees | `supabase/migrations/20260504000001_employees_module.sql` |
| Storage upload | `apps/tenant-portal/src/features/storage/api/storageService.ts` |
| Employee tabs | `apps/tenant-portal/src/features/employees/components/EmployeeDetailPage.tsx` |
| Contact / project / document | `ContactDetailPage`, `ProjectDetailPage`, `DocumentDetailPage` |
| Notificacions (motor) | `docs/plans/notificacions/plan.md` |
| Traduccions UI | `apps/tenant-portal/src/locales/ca/activity.json` |

---

## 14) Historial de revisions

### Peer review #1 (2026-06-23) — disposició

| # | Tema | Acord | On al pla |
|---|------|-------|-----------|
| 1 | Notificacions asíncrones (no trigger bloquejant) | **Acceptat** | D6, §2.4, trigger `enqueue_notifications`, funció SQL |
| 2 | Hard delete arrel amb respostes | **Acceptat** | D3 `ON DELETE RESTRICT`, soft delete normal |
| 3 | RPC retorna `jsonb` vs `SETOF` | **Acceptat amb documentació** | D5 — heterogeni + paginació integrada |
| 4 | TTL/particionament notificacions | **Acceptat** — delegat al motor F3 | §2.4, no `user_notifications` |
| 5 | `EMPLOYEE_UPDATED` 1 event per operació | **Acceptat** | D9, registre humanització, Fase 1 |
| 6 | Filtre rang de dates a RPC | **Acceptat** | D5, signatura RPC, Fase 1 |
| 7 | Índex per arrels esborrades (placeholders) | **Acceptat** | `idx_entity_comments_roots_all` |
| 8 | Pinning de comentaris | **Fase 2** | Schema `pinned_*`, §6, Fase 2 |
| 9 | Plantilles de comentari | **Fase 2** | §6, Fase 2 |
| 10 | Read receipts en tasques | **Fase 2** | §6, Fase 2 |
| 11 | `visibility` internal/tenant/contact | **Acceptat V1 schema** | D10, schema, UI default `internal` |
| 12 | Actor `ai`/`automation` | **Acceptat** | D11, schema, Fase 3 workflows |
| 13 | Timeline com a memòria IA | **Acceptat — diferenciador** | D12, §5 ampliat, Fase 2 |

### Revisió final #2 (2026-06-23) — disposició

| # | Tema | Acord | On al pla |
|---|------|-------|-----------|
| R1 | Rendiment `can_view_entity` per fila en RLS | **Acceptat** | D17 — `LANGUAGE sql STABLE`, inlining; §8 risc |
| R2 | Estratègia Realtime clara | **Acceptat** | D13 — V1 refetch; Fase 2 `postgres_changes` |
| R3 | Watermark de lectura per entitat | **Acceptat — V1** | D14, `entity_timeline_watermarks`, badge tab, RPC |
| R4 | Historial d'edicions de comentaris | **Acceptat — V1** | D15, `entity_comment_revisions`, triggers |
| R5 | `reply_count` desnormalitzat | **Acceptat** | Schema `entity_comments.reply_count`, trigger |
| R6 | Versionat contracte payload (`schema_version`) | **Acceptat** | D16, retorn RPC, webhook header |
| R7 | Anti-soroll: agrupació events sistèmics | **Fase 2** | §6, §9 (anti-soroll), `is_background` opcional |
| R8 | Privacitat/compliance notes IA | **Acceptat** | §8 risc, política retenció vida del tenant |
| R9 | SLOs i mètriques de producte | **Acceptat** | §9 — taula SLOs, mètriques proposades |
| R10 | Camí d'escala previsible (snapshot) | **Acceptat** | §9 — taula fases creixement, arquitectura snapshot |
| R11 | Entity Memory Score | **Fase 2** | §10.1 |
| R12 | Resums vius ("novetats des de l'última visita") | **Fase 2** | §10.2 |
| R13 | Risk Detector (patrons de risc) | **Fase 3** | §10.3 |
| R14 | Playbook Awareness (SOP automàtic) | **Fase 3** | §10.4 |
| R15 | Export auditable (hash integritat) | **Fase 3** | §10.5 |

### Estat implementació (2026-06-24)

- **Fase 1 i Fase 2 tancades** al codi i migracions `20260705000001`–`23`.
- **Fase 3** (webhooks ✅, export ✅, timeline agregada ✅, workflow comments ✅, SLOs ✅, Risk Detector ✅, Playbooks ✅, fix RPC overload ✅, feature gating ✅) **tancada**.
- Documentació operativa: §7.1 (catàleg + proves), §12 (smoke tests).
- Opcional pendent: `summarize-entity-activity` (LLM al banner), finestra edició sense revisió.
