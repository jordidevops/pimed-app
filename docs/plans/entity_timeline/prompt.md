# Prompt per a la IA implementadora — Timeline per Entitat

Tens accés complet al repositori. Necessito que creïs un **pla d'implementació complet** per a un sistema de "Timeline per Entitat" a l'aplicació multi-tenant existent (Supabase + Edge Functions + tenant-portal React).

---

## Contexte del projecte

Abans de planificar, revisa i tingues en compte:

- **`data.audit_log`**: ja existeix i registra events per entitat (`entity_type`, `entity_id`, `tenant_id`, `user_id`, `action`, `payload`). És la base dels events automàtics de la timeline. Revisa l'estructura exacta, els `action` types existents i el format del `payload`.
- **Sistema de notificacions**: revisa si ja existeix (`data.notifications` o similar) i com funciona, perquè les mencions (@usuari) s'hi hauran d'integrar (veure /docs/plans/notificacions/README.md).
- **Sistema de permisos (RBAC)**: `data.jwt_has_permission`, `jwt_user_tenants()`. Els comentaris i la visibilitat de la timeline han de respectar els permisos existents per entitat.
- **Storage**: ja existeix per a adjunts. Revisa el patró `request-upload`/`confirm-upload` per reutilitzar-lo als adjunts de comentaris.
- **`entity_type` existents**: inventaria quins `entity_type` ja usa l'`audit_log` (empleats, pressupostos, documents, contactes, projectes, etc.) per saber quines entitats tindran timeline des del primer dia.
- **Sistema de webhooks**: revisa si ja existeix alguna infraestructura per a notificacions externes o si cal construir-la des de zero.
- **Xat IA** (`ai_conversations`, `ai_conversation_messages`, tools `query_*`): el pla ha d'incloure la integració de la timeline com a context disponible per a la IA.

---

## Funcionalitats a planificar

### 1. Model de dades — `entity_comments`

Dissenyar la taula `data.entity_comments` amb:
- `id`, `tenant_id`, `entity_type`, `entity_id`, `user_id`
- `content` (text amb suport de mencions `@usuari` com a `[[@uuid|nom]]` o similar — decidir format i documentar-lo)
- `parent_id` (FK a `entity_comments.id`) — per a fils de resposta; `null` = comentari arrel
- `mentions uuid[]` — user_ids extrets del contingut
- `attachments jsonb` — refs Storage
- `is_task boolean DEFAULT false` — el comentari actua com a tasca pendent
- `resolved_at timestamptz`, `resolved_by uuid` — resolució de tasques
- `edited_at timestamptz`
- `deleted_at timestamptz` — soft delete (el comentari s'oculta però es manté per a auditoria i fils)
- `created_at timestamptz`

Índexs, RLS i polítiques d'accés seguint el patró existent del projecte.

Decidir i justificar: els comentaris esborrats (`deleted_at not null`) es mostren com a "Comentari eliminat" (preservant el fil) o s'oculten completament?

### 2. Vista Timeline unificada

Una vista o RPC `api.entity_timeline(entity_type, entity_id, limit, cursor)` que retorni una llista unificada i ordenada per `created_at` de:
- **Events d'`audit_log`** filtrats per `entity_type`/`entity_id`, transformats a format llegible (vegeu punt 3).
- **Comentaris** de `entity_comments` per la mateixa entitat, incloent-hi autor, mencions resoltes (nom + avatar), i si té respostes.

Paginació per cursor (no offset) per a timelines llargues.

Decidir si la vista és una PostgreSQL VIEW, una RPC, o una composició al Edge — justificar.

### 3. Humanització dels events d'`audit_log`

Aquest és un dels punts més importants. L'`audit_log` en brut conté accions tècniques (`UPDATE`, `status_change`, etc.). Cal una capa de traducció que produeixi missatges llegibles per a humans.

Planificar:
- **On viu la traducció**: al backend (RPC/Edge que retorna text ja humanitzat) o al frontend (funció de mapping `action → template string`). Valorar pros/cons de cada opció (i18n, mantenibilitat, extensibilitat).
- **Format dels missatges**: destacar valor anterior → valor nou. Exemple: "Maria García ha canviat l'estat de **Actiu** a **Baixa temporal**". Revisar els `action` types existents a l'`audit_log` i crear templates per a cadascun.
- **Extensibilitat**: quan s'afegeixi un nou `action` type a l'`audit_log`, com s'afegeix el seu template sense tocar múltiples fitxers?
- **Accions de la IA**: els events generats pel sistema d'IA (generació de documents, execució de tools) han de tenir templates específics que indiquin que l'acció l'ha feta la IA en nom de l'usuari.

### 4. Mencions amb notificació

- **Sintaxi al client**: decidir el format de menció al composer (p.ex. `@nom` que es converteix internament a `[[@uuid|nom]]` o similar). Revisar si hi ha algun component de rich text existent al projecte o cal construir-lo.
- **Extracció**: en inserir un comentari, extreure automàticament els `uuid` de les mencions i desar-los a `mentions[]`.
- **Trigger de notificació**: `AFTER INSERT ON data.entity_comments` → per a cada `uuid` a `mentions[]`, crear una notificació al sistema existent (o via Edge Function si el trigger directe és complex). La notificació ha d'incloure: qui ha mencionat, en quin comentari, en quina entitat.
- **Notificació per email** (opcional, configurable per usuari): si l'usuari té activades les notificacions per email, enviar via `email_send_queue` o equivalent.
- **Cas especial**: si el `parent_id` no és null (és una resposta a un comentari), notificar també l'autor del comentari pare, a més de les mencions explícites.

### 5. Comentaris com a tasques (`is_task`)

- Quan `is_task = true`, el comentari apareix visualment diferenciat a la timeline (checkbox, color, etc.).
- `resolved_at` + `resolved_by` quan es marca com a fet — generar un event a la timeline ("Joan Martí ha resolt la tasca: 'Pendent de rebre el certificat mèdic'").
- **Filtres a la UI**: "mostrar només tasques pendents", "mostrar totes les tasques (incloses les resoltes)".
- Planificar si les tasques pendents apareixen a algun lloc centralitzat de la app (dashboard, safata de l'usuari) a més de la timeline de l'entitat.
- **Notificació de venciment** (opcional): si les tasques incorporen `due_date`, planificar com es notifica quan s'apropa o es supera.

### 6. Fils de resposta (`parent_id`)

- Estructura d'arbre de dos nivells (comentari arrel + respostes directes), no recursiva infinita — igual que GitHub, Linear, Slack. Justificar si es vol recursivitat o no.
- La UI mostra les respostes agrupades sota el comentari arrel (col·lapsades per defecte si hi ha més de N).
- En esborrar un comentari arrel que té respostes: soft delete (mostra "Comentari eliminat" per preservar el fil) en lloc d'esborrar en cascada.
- La RPC de timeline ha de retornar comentaris arrel amb `replies_count` i opcionalment les primeres N respostes inline, per evitar N+1 queries al client.

### 7. Adjunts als comentaris

Reutilitzar el patró `request-upload`/`confirm-upload` existent. Planificar:
- Bucket o prefix específic per a adjunts de comentaris (`entity-comments/{tenantId}/{entityType}/{entityId}/`).
- Política de retenció: els adjunts s'esborren quan el comentari es fa hard delete? O tenen retenció independent?
- Mida màxima i tipus permesos (revisar si el projecte ja té constants globals per a això).

### 8. Integració via webhook amb serveis externs (Slack, etc.)

Planificar un sistema de webhooks per a events de la timeline:

**Model de dades:**
```sql
-- Webhooks configurats per tenant
data.tenant_webhooks (
  id, tenant_id, label, endpoint_url,
  secret (per verificació HMAC),
  events text[],  -- quins events disparen: 'comment.created', 'task.resolved', 'mention', etc.
  entity_types text[],  -- null = tots; o filtrar per 'employee', 'budget', etc.
  is_active boolean,
  created_by, created_at
)

-- Log d'enviaments (per debugging i reintents)
data.webhook_delivery_log (
  id, webhook_id, event_type, payload jsonb,
  status ('pending','delivered','failed'),
  attempts int, last_attempt_at, response_status, response_body,
  created_at
)
```

**Dispatch**: Edge Function `dispatch-webhook` cridada de forma asíncrona (no bloquejant) des del trigger d'inserció de comentaris o resolució de tasques. Planificar reintencs amb backoff exponencial.

**Payload estàndard** (compatible amb Slack incoming webhooks i genèric per a altres):
```json
{
  "event": "comment.created",
  "tenant_id": "...",
  "entity_type": "employee",
  "entity_id": "...",
  "entity_label": "Maria García",
  "actor": { "id": "...", "name": "Joan Martí" },
  "comment": { "id": "...", "content": "...", "is_task": false },
  "timestamp": "...",
  "app_url": "https://app.../employees/..."  -- deep link a l'entitat
}
```

**UI de configuració** (`/settings/integrations` o similar): crear, editar, activar/desactivar webhooks; veure log d'enviaments recents; botó "Test" que envia un payload d'exemple.

**Seguretat**: validació SSRF de `endpoint_url` (bloquejar IPs privades, igual que el pla MCP), HMAC-SHA256 a la capçalera `X-Webhook-Signature` per verificació al receptor.

### 9. Connexió amb la IA (xat)

Planificar la tool interna `query_entity_timeline` per al sistema de function calling:

```typescript
// packages/ai-schemas/tools/query-entity-timeline.tool.ts
QueryEntityTimelineInput = z.object({
  entityType: z.enum(['employee', 'contact', 'project', ...])
    .describe('Tipus d\'entitat'),
  entityId: z.string().uuid().describe('ID de l\'entitat'),
  limit: z.number().int().min(1).max(50).default(20)
    .describe('Nombre màxim d\'events a retornar'),
  includeSystemEvents: z.boolean().default(true)
    .describe('Incloure events automàtics del sistema o només comentaris manuals'),
})
```

- La tool retorna la timeline unificada (events + comentaris) en format llegible per la IA.
- Permisos: la IA només pot consultar timelines d'entitats a les quals l'usuari que fa el prompt té accés (verificat via `ToolExecutionContext` + permisos RBAC existents).
- Cas d'ús típic: "resumeix l'activitat recent de l'empleat Joan Martí" → la IA crida `query_entity_timeline` + `query_employees` i genera un resum narratiu.

### 10. UI — components i integració

Planificar els components necessaris al `tenant-portal`:

- **`EntityTimeline`**: component principal, mostra la llista unificada d'events + comentaris, amb paginació infinite scroll o "carregar més".
- **`TimelineEvent`**: renderitza un event d'`audit_log` humanitzat (icona per tipus d'acció, actor, timestamp relatiu).
- **`TimelineComment`**: renderitza un comentari amb autor, contingut (amb mencions destacades), adjunts, fil de respostes col·lapsable, accions (respondre, editar, esborrar, marcar com a tasca).
- **`TimelineComposer`**: input per escriure comentaris amb suport de mencions (@), adjunts, i toggle "és una tasca".
- **`TaskBadge`**: indicador visual per a comentaris-tasca (checkbox + estat resolt/pendent).

Decidir on s'integra la timeline a les pàgines existents: com a tab ("Activitat") a la pàgina de detall de cada entitat, o com a panel lateral. Revisar el layout existent de les pàgines de detall (empleats, contactes, etc.) per proposar la integració menys invasiva.

### 11. Funcionalitats addicionals que la IA consideri rellevants

A més de tot l'anterior, la IA planificadora ha d'avaluar i proposar si cal incorporar:

- **Reaccions (emoji)** als comentaris (👍 ✅ 👀): valor vs complexitat.
- **Cerca dins la timeline** d'una entitat (text lliure sobre comentaris i events).
- **Filtre dins la timeline** segons l'origen del comentari o event, p.e. d'audit_log.
- **Timeline agregada** ("Tot el que ha passat avui al tenant") com a dashboard o widget de l'inici de sessió — útil per a managers.
- **Exportació de la timeline** a PDF o CSV per a auditoria o compliance.
- **Subscripció a una entitat** ("seguir" un empleat o pressupost per rebre notificacions de qualsevol event, no només mencions).
- **Deep links**: cada comentari i event ha de tenir una URL directa que porti a la timeline de l'entitat amb aquell element destacat — imprescindible per a les notificacions per email i els webhooks de Slack.

Per a cada una, la IA ha de recomanar si s'inclou a V1, es deixa per a una fase posterior, o es descarta, amb justificació breu.

---

## Format del pla esperat

1. **Decisions de disseny prèvies** (on viu la humanització, format de mencions, estructura de fils, etc.) — una decisió per punt, justificada.
2. **Model de dades complet** (SQL): taules, índexs, RLS, triggers, seguint el patró existent del projecte (`data.*` schema, `service_role` per a Edge, `authenticated` per a vistes `api.*`).
3. **RPCs i Edge Functions** necessàries: signatura, responsabilitat, seguretat.
4. **Components UI**: llista i responsabilitat de cada component, sense implementar-los ara.
5. **Fases d'implementació** (sprints), cadascuna amb entregables, dependències i criteri d'acceptació.
6. **Riscos i mitigacions** específics d'aquest sistema.
7. **Decisions deixades obertes** on el pla necessita input humà abans d'implementar.