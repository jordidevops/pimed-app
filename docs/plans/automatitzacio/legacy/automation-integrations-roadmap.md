# Document Tècnic: Automatització i Integracions iPaaS

**Rol:** Arquitecte de Sistemes / Expert en Automatitzaió i Integracions  
**Data:** Juny 2026  
**Versió:** 1.0 — Roadmap V1 (intern) → V2 (extern)

---

## Índex

1. [Visió General i Filosofia](#1-visió-general-i-filosofia)
2. [Automatització Interna (V1)](#2-automatització-interna-v1)
   - 2.1 [DMS i Generació de Documents](#21-dms-i-generació-de-documents)
   - 2.2 [Calendari i Events Automàtics](#22-calendari-i-events-automàtics)
   - 2.3 [Fluxos per Mòdul](#23-fluxos-per-mòdul)
3. [Automatització Externa (V2)](#3-automatització-externa-v2)
   - 3.1 [Estratègia d'Autenticació](#31-estratègia-dautenticació)
   - 3.2 [Webhooks Sortints vs Polling](#32-webhooks-sortints-vs-polling)
   - 3.3 [Comparativa n8n / Make / Zapier](#33-comparativa-n8n--make--zapier)
   - 3.4 [Roadmap pas a pas](#34-roadmap-pas-a-pas)
4. [Apèndix: Disseny de Taules i Contracts](#4-apèndix-disseny-de-taules-i-contracts)

---

## 1. Visió General i Filosofia

### Principi fonamental: "Event-First Architecture"

La clau per habilitar automatització (tant interna com externa) de forma neta i escalable és que **cada acció rellevant de l'ERP emeti un event**. Tenim ja un sistema d'audit logs robust (`data.audit_logs`), PGMQ per a cues i `data.notifications`. Hem de construir l'automatització *sobre* aquesta infraestructura existent, no a banda.

### Dues capes d'automatització

```
┌─────────────────────────────────────────────────────────────────┐
│  CAPA V1: AUTOMATITZACIÓ INTERNA                                  │
│  (Fluxos dins l'ERP — sense sortir del sistema)                   │
│                                                                   │
│  Trigger (audit_logs / PGMQ)                                      │
│    → Rule Engine (data.automation_rules)                          │
│    → Action Handlers (Edge Functions ja existents)                │
└─────────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│  CAPA V2: AUTOMATITZACIÓ EXTERNA                                  │
│  (Webhooks sortints + REST API + connectors n8n/Make/Zapier)      │
│                                                                   │
│  Trigger (mateixa infraestructura V1)                             │
│    → Webhook Dispatcher (nova Edge Function)                      │
│    → n8n / Make / Zapier / URL personalitzada                     │
└─────────────────────────────────────────────────────────────────┘
```

### El que ja tenim (reutilitzable)

| Peça | Ús per automatització |
|------|----------------------|
| `data.audit_logs` | Font de veritat de tots els events |
| `pgmq` | Transport de missatges fiable, retry, DLQ |
| `QueueRunner` | Framework de workers genèric, idempotent |
| `context-builder.ts` | Construeix el payload complet d'una entitat |
| `liquid-renderer.ts` | Motor de plantilles per missatges/emails automàtics |
| `sign-document-router` | Orquestrador DMS ja existent |
| `data.calendar_events` | Polimòrfic, per a events automàtics |

---

## 2. Automatització Interna (V1)

### 2.1 DMS i Generació de Documents

#### Accions actuals que ja suporten automatització

El flux `sign-document-router` ja accepta `source_type` × `action`. Cada combinació és una "acció" automatitzable:

| Acció | Descripció | Disparador natural |
|-------|------------|-------------------|
| `generate_pdf_from_template` | Genera PDF des d'una plantilla + context d'entitat | Creació d'empleat, contracte, comanda |
| `send_for_signing` | Envia document per signar via DocuSeal | Aprovació d'un projecte, onboarding |
| `generate_and_sign` | Genera + envia a signar en un sol pas | Alta d'empleat amb contracte |
| `archive_document` | Arxiva el document final en una carpeta del DMS | Signatura completada |
| `notify_signatories` | Notifica pendents de signatura | Recordatori periòdic |

#### Tags de plantilles que creen events de calendari automàtics

Les plantilles HTML/DOCX ja permeten variables tipades. Afegint una convenció de nomenclatura, podem detectar automàticament quins camps s'han de convertir en events de calendari:

**Convenció proposada de variables:** `date:NomDelEvent`

```
// En una plantilla DOCX de contracte d'empleat:
[[ date:data_inici_contracte ]]       → calendari: "Inici contracte - {{ employee.full_name }}"
[[ date:data_revisio_salarial ]]      → recordatori: "Revisió salarial" (3 mesos abans)
[[ date:data_fi_periode_prova ]]      → recordatori: "Fi període de prova" (1 setmana abans)

// En una plantilla HTML de projecte:
{{ date:deadline_entrega }}           → calendari: "Deadline {{ project.name }}"
{{ date:data_reunio_client }}         → event: "Reunió - {{ contact.full_name }}"
```

#### Com implementar: `document_template_locales.variable_schema`

El camp `variable_schema` (JSONB) ja existeix a la taula `data.document_template_locales`. Ampliem l'schema per suportar metadades d'automatització:

```jsonc
// variable_schema ampliat (retrocompatible)
{
  "variables": [
    {
      "key": "data_inici_contracte",
      "type": "date",                    // ← tipus existent
      "label": "Data d'inici del contracte",
      "automation": {                    // ← NOU: opcions d'automatització
        "calendar_event": true,
        "event_title_template": "Inici contracte - {{ employee.full_name }}",
        "event_kind": "contract_start",
        "reminder_days_before": [7, 1]
      }
    },
    {
      "key": "import_factura",
      "type": "number",
      "label": "Import de la factura",
      "automation": null                 // sense automatització
    }
  ]
}
```

#### Flux automàtic complet: "Generar document → Crear events de calendari"

```
1. Usuari genera document des de plantilla
       ↓
2. sign-document-router (Edge Function existent)
       ↓
3. context-builder construeix payload
       ↓
4. Renderitzat (Liquid/Docxtemplater)
       ↓ NOU
5. post-generation-hook: escaneig de variable_schema
       ├─ Per cada variable type=date amb automation.calendar_event=true:
       │     → INSERT data.calendar_events (entity_type='document', entity_id=document.id)
       │     → INSERT data.calendar_event_reminders (per cada reminder_days_before)
       └─ Per cada variable type=date amb automation.trigger=true:
             → pgmq.send('automation_queue', { trigger: 'DATE_REACHED', ... })
       ↓
6. INSERT data.documents + data.document_versions al DMS
```

#### Configuració de regles d'automatització al template (UI)

A `settings/TemplatesPage`, afegir una pestanya "Automatitzacions" per template on l'usuari pugui:
- Veure les variables de tipus `date` detectades
- Marcar quines volen crear event de calendari
- Definir el títol de l'event (amb Liquid preview)
- Configurar recordatoris (X dies/hores abans)
- Configurar si l'event ha de fer trigger d'una acció addicional (enviar email, notificació)

---

### 2.2 Calendari i Events Automàtics

#### Sistema de Regles d'Automatització (`data.automation_rules`)

Proposem una taula de regles declaratives que el tenant pot configurar:

```sql
-- NOVA TAULA
CREATE TABLE data.automation_rules (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id      uuid REFERENCES data.sites(id),           -- NULL = global
  name         text NOT NULL,
  description  text,
  is_active    boolean NOT NULL DEFAULT true,
  
  -- Trigger: quan s'activa
  trigger_event   text NOT NULL,  -- 'DOCUMENT_GENERATED', 'EMPLOYEE_CREATED', etc.
  trigger_filters jsonb,           -- { "template_id": "xxx" } per filtrar triggers específics
  
  -- Condition: expressió opcional
  condition_expr  text,            -- SQL/Liquid: "{{ employee.department }} == 'RRHH'"
  
  -- Action: què fa
  action_type  text NOT NULL,     -- veure taula d'accions
  action_config jsonb NOT NULL,
  
  -- Control
  created_by   uuid REFERENCES auth.users(id),
  created_at   timestamptz DEFAULT now(),
  updated_at   timestamptz DEFAULT now()
);
```

#### Catàleg d'Accions Internes

| `action_type` | Descripció | `action_config` |
|---------------|------------|-----------------|
| `CREATE_CALENDAR_EVENT` | Crea event de calendari | `{ title_template, kind, reminder_days, attendees_from }` |
| `SEND_EMAIL` | Envia email via sistema existent | `{ template_id, to_field, cc_fields }` |
| `CREATE_TASK` | Crea tasca al mòdul de projectes | `{ project_id, title_template, assignee_field, due_date_field }` |
| `GENERATE_DOCUMENT` | Genera document des de plantilla | `{ template_id, context_entity, output_folder_id }` |
| `SEND_FOR_SIGNING` | Envia document per signar | `{ signatories_from, message_template }` |
| `SEND_NOTIFICATION` | Notificació in-app | `{ user_ids_from, title_i18n, kind }` |
| `CREATE_ABSENCE` | Crea absència/vacances | `{ employee_field, type, start_date_field, end_date_field }` |
| `WEBHOOK_OUTBOUND` | Envia webhook extern (V2) | `{ webhook_endpoint_id }` |
| `UPDATE_FIELD` | Actualitza un camp d'una entitat | `{ entity_type, entity_id_field, field, value_template }` |

#### Catàleg de Triggers Interns

| `trigger_event` | Entitat | Mòdul |
|-----------------|---------|-------|
| `DOCUMENT_GENERATED` | `document` | DMS |
| `DOCUMENT_SIGNED` | `document` | Signatura |
| `DOCUMENT_SIGNING_REJECTED` | `document` | Signatura |
| `EMPLOYEE_CREATED` | `employee` | RRHH |
| `EMPLOYEE_UPDATED` | `employee` | RRHH |
| `CONTRACT_DATE_REACHED` | `document` | DMS |
| `CONTACT_CREATED` | `contact` | CRM |
| `PROJECT_CREATED` | `project` | Projectes |
| `PROJECT_STATUS_CHANGED` | `project` | Projectes |
| `TASK_COMPLETED` | `task` | Projectes |
| `WORK_ORDER_CREATED` | `asset_work_order` | EAM |
| `WORK_ORDER_COMPLETED` | `asset_work_order` | EAM |
| `ABSENCE_REQUESTED` | `employee_absence` | RRHH |
| `ABSENCE_APPROVED` | `employee_absence` | RRHH |
| `LEAD_CREATED` | `lead` | Portal Públic |
| `SHIFT_SWAP_REQUESTED` | `shift_swap_request` | Torns |
| `DATE_FIELD_REACHED` | `document` | DMS (data de template) |

---

### 2.3 Fluxos per Mòdul

#### RRHH: Alta d'Empleat

```
EVENT: EMPLOYEE_CREATED
  ├─ [Règla 1] GENERATE_DOCUMENT
  │     template: "Benvinguda Empresa"
  │     context: employee
  │     output: carpeta "RRHH/Contractes/{employee.full_name}"
  │
  ├─ [Règla 2] SEND_EMAIL
  │     to: employee.email
  │     template: "welcome_employee"
  │
  ├─ [Règla 3] CREATE_TASK
  │     project: "Onboarding"
  │     title: "Preparar accés per a {{ employee.full_name }}"
  │     assignee: manager_user_id
  │     due_date: employee.start_date
  │
  └─ [Règla 4] CREATE_CALENDAR_EVENT
        title: "Primer dia - {{ employee.full_name }}"
        date: employee.start_date
        attendees: [employee.user_id, employee.manager_id]
```

#### DMS: Contracte Signat

```
EVENT: DOCUMENT_SIGNED (signing_submission.status = 'completed')
  ├─ [Règla 1] SEND_EMAIL
  │     to: [signatory_1, signatory_2]
  │     template: "document_signed_confirmation"
  │     attachments: [signed_document_url]
  │
  ├─ [Règla 2] UPDATE_FIELD
  │     entity: project (si el document té project_id)
  │     field: status → 'contract_signed'
  │
  └─ [Règla 3] WEBHOOK_OUTBOUND (V2)
        → notifica sistema extern
```

#### EAM: Ordre de Treball Creada

```
EVENT: WORK_ORDER_CREATED
  ├─ [Règla 1] SEND_NOTIFICATION
  │     users: [assigned_technician]
  │     title: "Nova OT: {{ work_order.title }}"
  │
  ├─ [Règla 2] CREATE_CALENDAR_EVENT
  │     title: "OT: {{ work_order.title }}"
  │     date: work_order.scheduled_date
  │     kind: 'maintenance'
  │
  └─ [Règla 3] GENERATE_DOCUMENT (opcional)
        template: "Fitxa d'Ordre de Treball"
        context: asset_work_order
```

#### Calendari: Venciment de Dates de Documents

```
pg_cron: cada dia a les 08:00 UTC
  → INVOKE process-date-triggers
        → SELECT documents WHERE variable_date = TODAY + N dies
        → pgmq.send('automation_queue', { trigger: 'DATE_FIELD_REACHED', ... })

  Exemples de rules:
    - 30 dies abans fi_contracte → SEND_EMAIL (renovació)
    - 7 dies abans revisio_ITV   → CREATE_TASK + SEND_NOTIFICATION
    - 1 dia  abans deadline      → SEND_NOTIFICATION
```

---

## 3. Automatització Externa (V2)

### 3.1 Estratègia d'Autenticació

#### Comparativa per al nostre stack

| Mètode | Seguretat | Complexitat impl. | Multi-tenant | Recomanació |
|--------|-----------|-------------------|--------------|-------------|
| **API Keys per tenant** | Alta (si ben gestionades) | Baixa | ✅ Natural | **✅ MVP — Fer primer** |
| **OAuth2 (Authorization Code)** | Molt alta | Molt alta | ✅ Natural | V2.1 (si escala comercial) |
| **JWT de llarga durada** | Baixa (no recomanat) | Baixa | Complexa | ❌ Evitar |
| **Service Role Supabase** | Crítica (bypass RLS) | Zero | ❌ No | ❌ Mai exposar |

#### Decisió: API Keys per Tenant (MVP)

**Per què API Keys és la millor opció per al nostre stack:**

1. **Supabase ja gestiona la rotació de tokens Supabase Auth**: les API Keys de l'ERP serien credencials *addicionals* específiques per a integracions, no relacionades amb auth de Supabase.
2. **Multi-tenant natural**: cada API Key porta el `tenant_id` codificat.
3. **n8n, Make i Zapier suporten API Keys nativament** en qualsevol connector HTTP genèric.
4. **RBAC granular**: podem associar una API Key a un conjunt de permisos limitats (scope: `read:employees`, `write:documents`).
5. **Audit logs automàtics**: cada request amb API Key queda registrat amb l'acció feta.

#### Disseny de la taula `data.api_keys`

```sql
CREATE TABLE data.api_keys (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id      uuid REFERENCES data.sites(id),           -- NULL = accés global al tenant
  name         text NOT NULL,                             -- "n8n Producció", "Zapier RRHH"
  description  text,
  
  -- La clau pròpiament (mai es mostra un cop creada)
  key_hash     text NOT NULL UNIQUE,                      -- bcrypt o SHA-256 del secret
  key_prefix   text NOT NULL,                             -- "ek_live_abc123" (últims 6 chars)
  
  -- Permisos granulars
  scopes       text[] NOT NULL DEFAULT '{}',              -- ['read:employees', 'write:documents']
  
  -- Control
  is_active    boolean NOT NULL DEFAULT true,
  last_used_at timestamptz,
  expires_at   timestamptz,                               -- NULL = no expira
  created_by   uuid NOT NULL REFERENCES auth.users(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  revoked_at   timestamptz,
  revoked_by   uuid REFERENCES auth.users(id)
);

-- Index per lookup ràpid
CREATE INDEX ON data.api_keys (key_hash) WHERE is_active AND revoked_at IS NULL;
```

**Format de la clau:** `ek_live_{32 chars random hex}` (similar a Stripe)
- `ek_` = ERP Key prefix
- `live`/`test` = environment
- La clau completa es mostra **una sola vegada** en el moment de creació

#### Edge Function: `api-key-middleware`

```typescript
// _shared/api-key-auth.ts
export async function validateApiKey(
  req: Request,
  db: SupabaseClient,
  requiredScope?: string
): Promise<{ tenant_id: string; site_id: string | null; scopes: string[] } | null> {
  
  const authHeader = req.headers.get('Authorization');
  const key = authHeader?.replace('Bearer ', '') ?? req.headers.get('X-API-Key');
  
  if (!key || !key.startsWith('ek_')) return null;
  
  const keyHash = await sha256(key);
  
  const { data } = await db
    .from('api_keys')
    .select('tenant_id, site_id, scopes')
    .eq('key_hash', keyHash)
    .eq('is_active', true)
    .is('revoked_at', null)
    .single();
    
  if (!data) return null;
  if (requiredScope && !data.scopes.includes(requiredScope)) return null;
  
  // Actualitzar last_used_at (fire-and-forget)
  db.from('api_keys').update({ last_used_at: new Date().toISOString() })
    .eq('key_hash', keyHash).then();
  
  return data;
}
```

#### Headers de request per a integradors

```http
POST /functions/v1/api/v1/employees
Authorization: Bearer ek_live_a1b2c3d4e5f6...
Content-Type: application/json
X-Tenant-ID: optional-override  ← ja ve codificat a la key, però útil per debug
```

#### Catàleg de Scopes

| Scope | Accés |
|-------|-------|
| `read:employees` | Llistar/llegir empleats |
| `write:employees` | Crear/modificar empleats |
| `read:documents` | Accedir a documents del DMS |
| `write:documents` | Pujar/generar documents |
| `read:contacts` | Llistar contactes |
| `write:contacts` | Crear/modificar contactes |
| `read:projects` | Llistar projectes i tasques |
| `write:projects` | Crear/modificar projectes |
| `read:assets` | Llistar actius (EAM) |
| `write:work_orders` | Crear ordres de treball |
| `read:attendance` | Llegir registres de presència |
| `webhooks:manage` | Gestionar webhook subscriptions |
| `admin` | Accés complet (no recomanat per integracions) |

---

### 3.2 Webhooks Sortints vs Polling

#### Decisió: Webhooks Sortints (Push)

**Per qué NO Polling:**
- Polling constant (cada 30 seg) genera **N × M requests per segon** (N tenants × M integradors)
- Latència alta: si l'interval és 5 min, l'automatizació triga fins a 5 min
- Costós en crèdits de Supabase Edge Function invocations
- No escala bé

**Per qué Webhooks Push:**
- Latència quasi zero (< 2 seg des de l'event fins al receptor)
- Només s'invoca la Edge Function quan hi ha activitat real
- n8n/Make/Zapier suporten nativament webhooks entradors (és el pattern estàndard)
- Millor experiència d'usuari per a automatitzadors

#### Arquitectura de Webhooks Sortints

```
data.audit_logs / PGMQ event
        │
        ▼
pg_cron o trigger (AFTER INSERT on audit_logs)
        │
        ▼
pgmq.send('webhook_dispatch_queue', {
  event_type: 'EMPLOYEE_CREATED',
  tenant_id: ...,
  entity_type: 'employee',
  entity_id: ...,
  payload: { ...full context via context-builder... }
})
        │
        ▼
process-webhook-dispatch (nova Edge Function / QueueRunner)
        │
        ├─ Busca webhook_subscriptions actives del tenant per aquest event_type
        ├─ Per cada subscripció:
        │     POST endpoint_url
        │     headers: { 'X-APP-Signature': hmac_sha256(secret, body), 'X-APP-Event': event_type }
        │     retry: 3 cops (exponential backoff)
        │     timeout: 10 seg
        └─ Log a data.webhook_delivery_logs (per debug i retry manual)
```

#### Taules necessàries

```sql
-- Subscripcions de webhooks per tenant
CREATE TABLE data.webhook_subscriptions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id      uuid REFERENCES data.sites(id),
  name         text NOT NULL,                            -- "n8n - RRHH"
  endpoint_url text NOT NULL,                            -- URL de destí
  secret       text NOT NULL,                            -- guardat a Vault, per HMAC
  event_types  text[] NOT NULL,                          -- ['EMPLOYEE_CREATED', 'DOCUMENT_SIGNED']
  is_active    boolean NOT NULL DEFAULT true,
  created_by   uuid REFERENCES auth.users(id),
  created_at   timestamptz DEFAULT now()
);

-- Log de lliuraments (per debugging)
CREATE TABLE data.webhook_delivery_logs (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subscription_id   uuid NOT NULL REFERENCES data.webhook_subscriptions(id),
  event_type        text NOT NULL,
  entity_id         uuid,
  attempt_number    int NOT NULL DEFAULT 1,
  http_status       int,
  request_body      jsonb,
  response_body     text,
  duration_ms       int,
  delivered_at      timestamptz,
  error             text,
  created_at        timestamptz DEFAULT now()
);
```

#### Signatura HMAC dels webhooks (seguretat)

Igual que ja fem amb DocuSeal i Resend, cada webhook sortint porta una signatura:

```
X-APP-Signature: sha256=a1b2c3...
X-APP-Event: EMPLOYEE_CREATED
X-APP-Delivery: {delivery_id}
X-APP-Timestamp: 1717000000
```

El receptor (n8n/Make/Zapier) pot verificar:
```javascript
const expectedSig = hmac_sha256(webhookSecret, `${timestamp}.${body}`);
// Si coincideix amb X-APP-Signature → autèntic
```

#### Format del Payload de Webhook

```jsonc
{
  "id": "wh_evt_01abc123",           // ID únic de l'event (idempotency)
  "event": "EMPLOYEE_CREATED",
  "created_at": "2026-06-11T10:30:00Z",
  "tenant_id": "t_xxx",
  "site_id": "s_yyy",                // null si és global
  "data": {
    "object": "employee",
    "id": "emp_zzz",
    "first_name": "Maria",
    "last_name": "García",
    "email": "maria@empresa.com",
    "department_id": "dep_aaa",
    "start_date": "2026-07-01",
    // ... tots els camps rellevants via context-builder
  },
  "previous_data": null              // present en events UPDATE (camps canviats)
}
```

---

### 3.3 Comparativa n8n / Make / Zapier

#### Anàlisi detallada per a MVP

##### n8n

**Model:** Open-source + Cloud. Node personalitzat o HTTP Request genèric.

| Aspecte | Detall | Esforç |
|---------|--------|--------|
| **Integració sense codi** | HTTP Request node + Webhook Trigger — **FUNCIONA JA avui** amb l'API i webhooks | Zero |
| **Node personalitzat (NPM)** | Publicar a npm com `n8n-nodes-my_app`. TypeScript, sense certificació | Mig-Baix (1-2 setmanes) |
| **Distribució** | Community nodes: publicar a npm + documentació | Lliure, sense aprovació |
| **Avantatge clau** | 99% dels usuaris n8n ja saben fer HTTP Request. Un "Quick Start" als docs ja cobreix el cas | ✅ |
| **Hosting** | Self-hosted (molts clients tècnics) o n8n Cloud | ✅ |

**Pla d'acció n8n:**
1. V1: Documentar `HTTP Request + Webhook` en un "Quick Start Guide" → **Cost: 0 dev**
2. V2: Crear `n8n-nodes-my_app` NPM package amb nodes pre-configurats → **Cost: 1 setmana**

---

##### Make (ex-Integromat)

**Model:** SaaS, connector personalitzat via "Developer Platform" → no requereix aprovació per usar-lo privadament.

| Aspecte | Detall | Esforç |
|---------|--------|--------|
| **Integració sense codi** | HTTP module + Webhooks — funciona ja | Zero |
| **App privada Make** | Make Developer Platform: JSON OpenAPI-like. Sense cert. per ús privat | Mig (2-3 dies de definició JSON) |
| **Certificació pública** | Cal aprovació Make + +10 usuaris actius | 2-4 mesos (si es vol) |
| **Avantatge clau** | La "Custom App" privada dóna UX molt polida sense passar per certificació | ✅ |
| **UI Builder** | Make té un interface de configuració de modules molt visual | ✅ |

**Pla d'acció Make:**
1. V1: Documentar HTTP module → **Cost: 0 dev**
2. V2: Crear Make Custom App (privada) amb OpenAPI JSON → **Cost: 2-3 dies**
3. V3 (opcional): Certificació pública Make → **Cost: 2-4 mesos**

---

##### Zapier

**Model:** SaaS, requereix "Zapier Developer Platform" i aprovació per publicació pública.

| Aspecte | Detall | Esforç |
|---------|--------|--------|
| **Integració sense codi** | Webhooks by Zapier (natiu) + REST HTTP — funciona ja | Zero |
| **Private App Zapier** | Zapier CLI + TypeScript SDK. Funcional sense publicació | Alt (3-5 dies setup + test) |
| **Publicació pública** | Revisió manual Zapier, requeriments d'UX estrictes, SLA compromís | 1-3 mesos |
| **Avantatge clau** | Mercat enorme (90M+ zaps), però l'esforç de certificació és el màxim | ⚠️ |
| **CLI** | `@zapier/cli` TypeScript, bones eines de test local | ✅ |

**Pla d'acció Zapier:**
1. V1: "Webhooks by Zapier" (trigger natiu de Zapier) + REST HTTP → **Cost: 0 dev**
2. V2: Zapier Private App via CLI → **Cost: 3-5 dies**
3. V3 (si volum ho justifica): Publicació pública → **Cost: 1-3 mesos**

---

#### Taula Resum Comparativa

| Criteri | n8n | Make | Zapier |
|---------|-----|------|--------|
| **Esforç MVP (0 dev)** | ✅ HTTP Request | ✅ HTTP module | ✅ Webhooks by Zapier |
| **Esforç App nativa MVP** | Baix (npm node) | Mig (JSON config) | Alt (CLI + SDK) |
| **Certificació oficial** | No cal | Opcional | Quasi obligatòria per créixer |
| **Target usuari** | Tècnic/Dev | Mixt | No tècnic |
| **Mercat ERP SaaS B2B** | ✅ Molt popular | ✅ Popular | ⚠️ Menys adopció B2B |
| **Self-hosted** | ✅ | ❌ | ❌ |
| **Recomanació ordre** | **1r** | **2n** | **3r** |

**Recomanació:** Comença per n8n. El 80% dels clients tècnics d'un ERP SaaS usen n8n o Make. n8n és l'ideal perquè l'app nativa no requereix cap certificació i els clients self-hosted aprecien molt tenir un connector oficial.

---

### 3.4 Roadmap pas a pas

#### Visió del Roadmap

```
FASE 0 (Ara)     FASE 1 (V1)           FASE 2 (V2)           FASE 3 (V3)
─────────────    ─────────────────────  ──────────────────    ────────────────
Infraestructura  Motor d'Automatzació   Webhooks + API Keys   Apps Natives
existent         Intern                 Externes              n8n/Make/Zapier
                 
audit_logs  →   automation_rules  →   webhook_subscriptions  →  n8n node
PGMQ        →   automation_queue  →   api_keys               →  Make app
context-    →   date triggers     →   REST API pública        →  Zapier app
 builder        template dates         (openapi.json)
```

---

#### FASE 1 — Motor d'Automatització Intern (V1) — 3-4 setmanes

> **Objectiu:** Que les accions internes de l'ERP es puguin encadenar sense codi.

**Sprint 1.1 — Infraestructura base (1 setmana)**

- [ ] Migració SQL: `data.automation_rules` + `data.automation_executions` (log d'execucions)
- [ ] Nou cua PGMQ: `automation_queue`
- [ ] Edge Function: `process-automation-queue` (QueueRunner amb dispatchers per `action_type`)
- [ ] Ampliar `variable_schema` de `document_template_locales` amb camp `automation`
- [ ] Trigger PostgreSQL: `AFTER INSERT ON data.audit_logs` → `pgmq.send('automation_queue', ...)`
  - Filtrar per `action IN ('EMPLOYEE_CREATED', 'DOCUMENT_GENERATED', ...)` per no satturar la cua

**Sprint 1.2 — Accions bàsiques (1 setmana)**

- [ ] Handler `CREATE_CALENDAR_EVENT` al worker d'automatització
- [ ] Handler `SEND_EMAIL` (reutilitza `email_send_queue` existent)
- [ ] Handler `SEND_NOTIFICATION` (reutilitza `data.notifications` existent)
- [ ] Handler `CREATE_TASK` (INSERT `data.tasks`)

**Sprint 1.3 — Detecció de dates en documents (1 setmana)**

- [ ] `post-generation-hook` a `sign-document-router`: llegir `variable_schema`, extreure valors `type=date`
- [ ] Crear events de calendari automàticament basats en `automation.calendar_event=true`
- [ ] pg_cron job: `process-date-triggers` per a venciments futurs
- [ ] Handler `DATE_FIELD_REACHED` al worker

**Sprint 1.4 — UI de Regles (1 setmana)**

- [ ] Secció "Automatitzacions" a `settings/TemplatesPage`
- [ ] Pàgina `settings/AutomationsPage` per crear/editar/activar regles
- [ ] Visualitzador de `data.automation_executions` per debugging (historial d'execucions)

---

#### FASE 2 — API Externa + Webhooks Sortints (V2) — 3-4 setmanes

> **Objectiu:** Que n8n/Make/Zapier puguin connectar-se via webhooks i API.

**Sprint 2.1 — API Keys (1 setmana)**

- [ ] Migració SQL: `data.api_keys`
- [ ] Edge Function: `manage-api-keys` (CRUD: crear, llistar, revocar)
- [ ] `_shared/api-key-auth.ts` (helper de validació)
- [ ] UI: `settings/IntegrationsPage` amb gestió d'API Keys

**Sprint 2.2 — Webhook Subscriptions (1 setmana)**

- [ ] Migració SQL: `data.webhook_subscriptions` + `data.webhook_delivery_logs`
- [ ] Cua PGMQ: `webhook_dispatch_queue`
- [ ] Edge Function: `process-webhook-dispatch` (QueueRunner, HMAC signatura, retry)
- [ ] Edge Function: `manage-webhook-subscriptions` (CRUD)
- [ ] UI: secció "Webhooks" a `settings/IntegrationsPage`

**Sprint 2.3 — REST API Pública (1-2 setmanes)**

- [ ] Edge Function: `api-v1-employees` (GET list, GET by id, POST create, PATCH update)
- [ ] Edge Function: `api-v1-documents` (GET list, POST generate, GET download url)
- [ ] Edge Function: `api-v1-contacts` (CRUD bàsic)
- [ ] Generació `openapi.json` (manual o via schema introspection)
- [ ] Documentació pública (Swagger UI o Scalar — un fitxer HTML estàtic)

**Sprint 2.4 — Quick Start Guides (0.5 setmana)**

- [ ] Doc: "Connect n8n to your ERP" (HTTP Request + Webhook Trigger examples)
- [ ] Doc: "Connect Make to your ERP" (HTTP module + Webhook examples)
- [ ] Doc: "Connect Zapier to your ERP" (Webhooks by Zapier + HTTP action)

---

#### FASE 3 — Apps Natives iPaaS (V2.1+) — Variable

> **Objectiu:** Presència als directoris oficials de n8n/Make per a clients no tècnics.

**n8n Community Node** (recomanat primer, 1-2 setmanes)

- [ ] Crear repositori `n8n-nodes-my_app` (TypeScript, `n8n-community-nodes-template`)
- [ ] Implementar nodes: `APP Trigger` (webhook receiver) + `APP Action` (REST calls)
- [ ] Publicar a npm: `npm publish n8n-nodes-my_app`
- [ ] PR al repositori `n8n-io/n8n-nodes` per listing al directori community

**Make Custom App** (2n, 3-5 dies)

- [ ] Crear app privada al Make Developer Platform (JSON + OAuth o API Key)
- [ ] Definir Modules: `Watch Employees`, `Create Employee`, `Generate Document`...
- [ ] Testing intern amb Make team
- [ ] (Opcional) Aplicar a Verified App status

**Zapier App** (3r, 3-5 dies per private + 1-3 mesos per pública)

- [ ] `npx zapier init my_app --template node`
- [ ] Implementar Triggers + Actions via Zapier CLI
- [ ] Testing intern
- [ ] (Quan hi hagi volum) Publicació pública

---

#### Diagrama Temporal

```
Mes 1         Mes 2         Mes 3         Mes 4+
│─────────────│─────────────│─────────────│──────────...
│             │             │             │
│ FASE 1      │ FASE 2      │ FASE 3      │
│ ────────    │ ────────    │ ────────    │
│ Automàt.    │ API Keys    │ n8n Node    │
│ Interna     │ Webhooks    │ Make App    │
│ Rules       │ REST API    │ Zapier App  │
│ Templates   │ Docs        │             │
│ UI          │             │             │
```

---

## 4. Apèndix: Disseny de Taules i Contracts

### 4.1 Esquema complet `data.automation_executions`

```sql
CREATE TABLE data.automation_executions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_id        uuid NOT NULL REFERENCES data.automation_rules(id),
  tenant_id      uuid NOT NULL REFERENCES data.tenants(id),
  trigger_event  text NOT NULL,
  trigger_entity_type text,
  trigger_entity_id   uuid,
  status         text NOT NULL DEFAULT 'pending', -- pending, running, success, failed, skipped
  result         jsonb,
  error_message  text,
  duration_ms    int,
  started_at     timestamptz DEFAULT now(),
  completed_at   timestamptz
);
```

### 4.2 Openapi.json mínima (per a Make/Zapier autodiscovery)

```jsonc
{
  "openapi": "3.1.0",
  "info": {
    "title": "ERP API",
    "version": "1.0.0",
    "description": "API externa per a integracions iPaaS"
  },
  "servers": [
    { "url": "https://{project}.supabase.co/functions/v1/api/v1" }
  ],
  "security": [{ "ApiKeyAuth": [] }],
  "components": {
    "securitySchemes": {
      "ApiKeyAuth": {
        "type": "http",
        "scheme": "bearer",
        "description": "API Key del tenant (format: ek_live_...)"
      }
    }
  },
  "paths": {
    "/employees": { "get": { ... }, "post": { ... } },
    "/documents": { "get": { ... }, "post": { ... } },
    "/contacts": { "get": { ... }, "post": { ... } },
    "/webhooks": { "get": { ... }, "post": { ... }, "delete": { ... } }
  }
}
```

### 4.3 Decisions d'arquitectura clau

| Decisió | Opció triada | Motiu |
|---------|-------------|-------|
| Auth externa | API Keys per tenant | Senzilla, multi-tenant natural, compatible iPaaS |
| Triggers externs | Webhooks sortints (push) | Latència zero, eficient, estàndard iPaaS |
| Transport intern | PGMQ existent | Reutilització, idempotent, retry automàtic |
| Format payload | Stripe-style (event + data + previous_data) | Familiar per a desenvolupadors, complet |
| Signatura webhooks | HMAC-SHA256 (igual que Resend/DocuSeal) | Consistència amb integracions existents |
| Primera plataforma iPaaS | n8n | Mercat tècnic B2B, sense certificació, self-hosted |
| Dates → calendari | Variable schema `automation` metadata | Retrocompatible, no-code per al tenant |

---

*Document generat per: GitHub Copilot (Arquitecte de Sistemes)*  
*Revisa i valida amb l'equip tècnic abans d'iniciar la implementació.*
