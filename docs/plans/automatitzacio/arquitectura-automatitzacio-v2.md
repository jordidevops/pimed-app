# Arquitectura d'Automatització — Proposta V2

**Rol:** Arquitecte de Sistemes  
**Data:** Juny 2026  
**Versió:** 2.0 — Proposta arquitectònica definitiva  
**Estat:** V1.5 implementat (motor operable end-to-end) — veure [§17 Annex d'implementació](#17-annex-dimplementació--estat-v15)

---

## Índex

1. [Síntesi dels inputs previs](#1-síntesi-dels-inputs-previs)
2. [Principis arquitectònics definitius](#2-principis-arquitectònics-definitius)
3. [Arquitectura conceptual](#3-arquitectura-conceptual)
4. [Components principals](#4-components-principals)
5. [Model de dades conceptual](#5-model-de-dades-conceptual)
6. [Fluxos principals](#6-fluxos-principals)
7. [Decisions arquitectòniques justificades](#7-decisions-arquitectòniques-justificades)
8. [Automation Center — Disseny UX](#8-automation-center--disseny-ux)
9. [Business Automation Manager (BAM)](#9-business-automation-manager-bam)
10. [Blueprints i adopció](#10-blueprints-i-adopció)
11. [AI-in-the-Loop](#11-ai-in-the-loop)
12. [Multi-tenant i multi-site](#12-multi-tenant-i-multi-site)
13. [Comparativa amb el sector](#13-comparativa-amb-el-sector)
14. [Roadmap recomanat](#14-roadmap-recomanat)
15. [Recomanació final](#15-recomanació-final)
16. [Annex — Decisions sobre Aprovacions, Trigger Principal i Adjunts](#16-annex--decisions-sobre-aprovacions-trigger-principal-i-adjunts)
17. [Annex d'implementació — Estat V1](#17-annex-dimplementació--estat-v1)

---

## 1. Síntesi dels inputs previs

### Tres documents, tres perspectives

| Document | Punt de vista | Conclusions vàlides | Conclusions descartables |
|----------|--------------|---------------------|-------------------------|
| `automation-integrations-roadmap.md` | Pragmàtic, orientat a MVP | Reutilització infra existent, API Keys, Webhooks HMAC, n8n primer | `automation_rules` és insuficient per multi-step; acoblament calendari-plantilla |
| `revisió_pla.md` (primera IA) | Enterprise, BPM clàssic | Necessitat de Process Instances, estats d'execució | Saga Pattern, compensacions, motor BPMN complet |
| `re_revisio_pla.md` (revisió crítica) | Pragmàtic + modern | Workflow as Data, CloudEvents, AI Actions, Human Approval natiu, Automation Center com visor d'execucions | — |
| `consideracions_critiques.md` | Equilibri crític | No Sagas, PGMQ ja és l'Outbox, DAGs simples, IA com actor de primera classe, Blueprints | — |

### Conclusió sintètica

El sistema resultant ha de ser:
- **Més que regles** (`automation_rules` → `automation_workflows` amb steps)
- **Menys que BPMN** (no Camunda, no gateways complexos, no compensacions)
- **Executat sobre la infra existent** (PGMQ, Edge Functions, QueueRunner)
- **Observable** (workflow runs + step runs)
- **Adoptable** (Blueprints instal·lables amb un clic)
- **AI-ready** (arquitectura preparada, implementació opcional i per fases)

La metàfora correcta no és Camunda. La metàfora correcta és **GitHub Actions** o **n8n** però integrats dins l'ERP.

---

## 2. Principis arquitectònics definitius

### P1 — Event-Driven, sempre

Tota automatització neix d'un event. Sense event, sense automatització.  
Cap automatització es dispara de forma "màgica" fora del cicle de vida dels events del sistema.

### P2 — Reutilització total de la infraestructura existent

No es crea res paral·lel. Tot passa per:
- `PGMQ` com a transport de missatges
- `QueueRunner` com a framework de workers
- `audit_logs` com a font de veritat dels events
- `edge functions` existents com a handlers d'accions

### P3 — Workflow as Data, no codi

Els workflows s'emmagatzemen com a JSONB a la base de dades, no com a codi TypeScript. Això permet:
- Crear/modificar workflows sense desplegaments
- Versionar workflows
- Clonar Blueprints
- Inspecció i edició des de la UI

### P4 — DAGs, no BPMN

El model d'execució és un **Directed Acyclic Graph** simple: seqüència de passos amb suport per a branching condicional bàsic (`CONDITION`). No hi ha bucles infinits, no hi ha sub-processos, no hi ha pools, no hi ha compensacions.

Si un client necessita lògica BPMN avançada → integra n8n/Make via V2.

### P5 — Observabilitat total

Cada execució genera un registre persistent de:
- Quan ha començat i acabat
- Quin pas estava executant
- Quin error ha produït
- Quin usuari ha intervingut (si hi havia aprovació humana)

Sense `workflow_runs` + `workflow_step_runs`, el sistema és una caixa negra inacceptable.

### P6 — Human-in-the-Loop natiu

L'aprovació humana **no és una funcionalitat addicional**. És un tipus de pas natiu del motor. Sense ell, no es pot construir cap procés real d'onboarding, aprovació de contractes ni validació de dades.

### P7 — AI-ready, AI-optional

L'arquitectura prepara el "slot" per a accions d'IA des del principi. La implementació és posterior i mai obligatòria. Cada tenant configura les seves pròpies claus d'API d'IA. El sistema funciona al 100% sense IA.

### P8 — UX primer, tecnologia després

La majoria de clients no configuraran workflows des de zero. La via d'entrada és via **Blueprints**. La complexitat tècnica queda amagada darrere d'una UI que parla el llenguatge del client ("Onboarding d'empleats") no el del sistema ("trigger: EMPLOYEE_CREATED").

### P9 — Multi-tenant i multi-site per disseny

Tot workflow, execució i configuració porta `tenant_id`. El `site_id` és opcional i permet restringir automatitzacions a un local específic. Cap automatització creua fronteres de tenant.

---

## 3. Arquitectura conceptual

### Visió de capes

```
┌───────────────────────────────────────────────────────────────────┐
│  CAPA 0: EVENTS                                                    │
│  audit_logs → PGMQ event bus → triggers de dates (pg_cron)        │
│  Format intern: lightweight envelope  |  Format extern: CloudEvents│
└─────────────────────────────┬─────────────────────────────────────┘
                              │
┌─────────────────────────────▼─────────────────────────────────────┐
│  CAPA 1: WORKFLOW ENGINE                                           │
│  Busca workflows actius pel tenant que escolten aquest event       │
│  Crea workflow_run  →  afegeix steps a workflow_step_runs          │
│  Encua el primer step a automation_queue (PGMQ)                    │
└─────────────────────────────┬─────────────────────────────────────┘
                              │
┌─────────────────────────────▼─────────────────────────────────────┐
│  CAPA 2: STEP EXECUTOR (QueueRunner)                               │
│  process-automation-queue (Edge Function)                          │
│  Llegeix step_run → executa handler → marca completed/failed       │
│  → encua el step següent  |  o canvia estat a WAITING_HUMAN        │
└─────────────────────────────┬─────────────────────────────────────┘
                              │
┌─────────────────────────────▼─────────────────────────────────────┐
│  CAPA 3: ACTION HANDLERS                                           │
│  Reutilitzen infraestructura existent:                             │
│  email_queue  │  notifications  │  calendar_events                 │
│  sign-document-router  │  process-document-pdf-queue               │
└─────────────────────────────┬─────────────────────────────────────┘
                              │
┌─────────────────────────────▼─────────────────────────────────────┐
│  CAPA 4: OBSERVABILITAT (Automation Center)                        │
│  workflow_runs + workflow_step_runs  →  UI temps real              │
│  Pending approvals (BAM Inbox)  │  Retry manual  │  Historial      │
└───────────────────────────────────────────────────────────────────┘
```

### Diagrama de flux general

```
Event del sistema
(audit_log INSERT)
        │
        ▼
Trigger PostgreSQL
(AFTER INSERT on audit_logs)
        │
        ▼
pgmq.send('workflow_trigger_queue', {
  event_type: 'EMPLOYEE_CREATED',
  tenant_id, entity_id, payload
})
        │
        ▼
process-workflow-triggers (Edge Function)
  Busca automation_workflows actius
  Evalua trigger_filters i conditions
  Per cada workflow que coincideix:
    ├─ INSERT workflow_runs (status: RUNNING)
    ├─ INSERT workflow_step_runs (per cada step)
    └─ pgmq.send('automation_queue', { step_run_id: ... })
        │
        ▼
process-automation-queue (Edge Function / QueueRunner)
  Llegeix step_run
  Executa action handler
  ├─ Èxit → marca step COMPLETED → encua step següent
  ├─ Error → marca step FAILED → retry automàtic
  │           si esgota retries → workflow FAILED → notificació
  └─ HUMAN_APPROVAL → workflow WAITING_HUMAN → BAM Inbox
        │
        ▼
Automation Center (UI)
  Mostra estat en temps real
  Permet retry manual, aprovació, cancel·lació
```

---

## 4. Components principals

### 4.1 Event Bus (Capa 0)

**Responsabilitat:** Capturar tots els events rellevants del sistema i posar-los a la cua `workflow_trigger_queue`.

**Fonts d'events:**
- `audit_logs` (principal): cada INSERT és un event potencial
- `pg_cron` + funció `process-date-triggers`: per a events basats en dates (venciments, recordatoris)
- Edge Functions existents: poden emetre events directament via `pgmq.send`

**Decisió sobre CloudEvents:** S'adopta el format CloudEvents **únicament per a la interfície externa** (webhooks sortints V2). Internament s'usa un envelope simplificat per evitar overhead. Veure [Decisió D3](#d3--cloudevents-sí-però-en-el-lloc-correcte).

### 4.2 Workflow Definitions Store (Capa 1)

**Responsabilitat:** Emmagatzemar les definicions de workflows com a dades JSONB a la BD.

**Concepte clau:** Un workflow és una seqüència ordenada de passos amb metadades de trigger. No és codi. És dada.

```
automation_workflows
  id, tenant_id, site_id, name, description
  trigger_event          (quin event l'activa)
  trigger_filters        (filtre opcional: plantilla concreta, departament, etc.)
  steps                  (JSONB: array de step definitions)
  is_active
  version, is_blueprint
```

**Estructura d'un step (concepte, sense SQL):**
```
{
  "id": "step_1",
  "name": "Generar contracte",
  "type": "GENERATE_DOCUMENT",
  "config": { ... },
  "on_success": "step_2",
  "on_failure": "END_FAIL",
  "retry_max": 3,
  "timeout_minutes": 30
}
```

### 4.3 Workflow Engine (Capa 1)

**Responsabilitat:** Instanciar un `workflow_run` i els seus `step_runs` quan arriba un event que coincideix amb un workflow actiu.

**Processament:**
1. Llegeix el missatge de `workflow_trigger_queue`
2. Busca `automation_workflows` actius del tenant per a `trigger_event`
3. Evalua `trigger_filters` (per exemple: template_id, department_id)
4. Per cada workflow que coincideix: crea `workflow_run` + `workflow_step_runs`
5. Encua el primer step a `automation_queue`

**Important:** El engine és un worker QueueRunner estàndard. No és cap cosa especial. Reutilitza el patró existent.

### 4.4 Step Executor (Capa 2)

**Responsabilitat:** Executar cada pas del workflow de forma asíncrona i fiable.

**Funcionament:**
- Llegeix un `workflow_step_run` de la cua `automation_queue`
- Invoca el handler corresponent al `type` del pas
- Actualitza l'estat del step i del workflow
- Encua el pas següent (o finalitza el workflow)

**Errors i retry:** Gestionats pel `QueueRunner` existent (exponential backoff, DLQ). Si un step falla N cops → `workflow_run.status = FAILED` → notificació a l'owner.

### 4.5 Action Handlers (Capa 3)

**Responsabilitat:** Executar l'acció concreta de cada tipus de pas.

**Principi:** Cada handler **reutilitza la infraestructura existent**. No reinventa res.

| Tipus de pas | Infraestructura reutilitzada |
|-------------|------------------------------|
| `SEND_EMAIL` | `email_send_queue` (PGMQ existent) |
| `SEND_NOTIFICATION` | `data.notifications` (existent) |
| `CREATE_TASK` | INSERT directe `data.tasks` |
| `GENERATE_DOCUMENT` | `sign-document-router` (Edge Function existent) |
| `SEND_FOR_SIGNING` | `sign-document-router` (mode sign) |
| `CREATE_CALENDAR_EVENT` | INSERT `data.calendar_events` |
| `HUMAN_APPROVAL` | Crea `pending_approvals` → Automation Center |
| `WAIT` | pg_cron job temporal |
| `CONDITION` | Lògica interna del step executor |
| `WEBHOOK_OUTBOUND` | `webhook_dispatch_queue` (V2) |
| `UPDATE_FIELD` | RPC SQL o INSERT directe |
| `AI_EXTRACT` *(futur)* | OpenAI / Anthropic API via tenant config |
| `AI_DECIDE` *(futur)* | Id. |

### 4.6 Execution Store (Capa 4)

**Responsabilitat:** Guardar l'estat persistent de totes les execucions.

**Dues taules conceptuals:**

```
workflow_runs
  id, workflow_id, tenant_id, site_id
  status: RUNNING | WAITING_HUMAN | WAITING_TIMER | COMPLETED | FAILED | CANCELLED
  trigger_event, trigger_entity_type, trigger_entity_id
  context (JSONB — snapshot de les dades en el moment del trigger)
  started_at, completed_at

workflow_step_runs
  id, workflow_run_id, step_id, step_name, step_type
  status: PENDING | RUNNING | COMPLETED | FAILED | SKIPPED | WAITING_HUMAN | WAITING_TIMER
  input (JSONB), output (JSONB), error
  attempt_number, started_at, completed_at
  approved_by, approved_at (per HUMAN_APPROVAL)
```

**Per què és imprescindible:**  
Sense execution store, l'Automation Center no pot mostrar res. Un workflow és una caixa negra. No pots saber si l'onboarding de Maria s'ha completat, on s'ha aturat, ni per quin motiu ha fallat. Amb execution store, veus exactament cada pas, el seu resultat i el seu temps.

---

## 5. Model de dades conceptual

> Nota: Aquí es presenta el model conceptual (entitats i relacions), no l'SQL. Les migracions es definiran en una fase d'implementació posterior.

### Diagrama d'entitats principals

```
data.automation_workflows
  ├── trigger_event (string)
  ├── trigger_filters (JSONB)
  ├── steps (JSONB array de step definitions)
  ├── is_blueprint (bool — workflows de la plataforma)
  └── source_blueprint_id (FK → automation_workflows per blueprints clonats)
        │
        │  1:N (cada workflow pot tenir moltes execucions)
        ▼
data.automation_runs
  ├── workflow_id (FK)
  ├── status (enum)
  ├── trigger_entity_id (UUID — l'entitat que ha disparat el trigger)
  ├── context (JSONB — snapshot de l'entitat al moment del trigger)
  └── ...
        │
        │  1:N (cada run té N step runs)
        ▼
data.automation_step_runs
  ├── workflow_run_id (FK)
  ├── step_id (string — referència al step dins del JSONB definition)
  ├── step_type (string)
  ├── status (enum)
  ├── input/output (JSONB)
  └── approved_by / approved_at (per HUMAN_APPROVAL)


data.automation_pending_approvals
  ├── step_run_id (FK → automation_step_runs)
  ├── workflow_run_id (FK)
  ├── assigned_to_user_id / assigned_to_role
  ├── context_preview (JSONB — per mostrar al BAM)
  ├── status: PENDING | APPROVED | REJECTED | EXPIRED
  ├── due_at (per escalations)
  └── resolved_by / resolved_at
```

### Workflows i Blueprints

```
Plataforma
  └── Blueprint: "Onboarding d'empleats"  (is_blueprint=true, tenant_id=NULL)
        │
        │  Tenant instal·la (clona)
        ▼
Tenant Empresa ABC
  └── Workflow: "Onboarding d'empleats"   (source_blueprint_id=blueprint_id)
        ├── Pot modificar steps
        ├── Pot afegir/treure passos
        └── Pot desactivar
```

### Context del workflow

Un `context` és el snapshot de l'entitat que ha disparat el trigger, construït via `context-builder.ts` existent. Conté tot el necessari per als Liquid templates de les accions:

```json
{
  "employee": { "id": "...", "full_name": "Maria García", "email": "..." },
  "tenant":   { "name": "Empresa ABC", "slug": "empresa-abc" },
  "site":     { "name": "Oficina Barcelona" },
  "trigger":  { "event": "EMPLOYEE_CREATED", "timestamp": "..." }
}
```

---

## 6. Fluxos principals

### Flux 1: Onboarding d'empleat (procés multi-step)

```
EVENT: EMPLOYEE_CREATED (tenant: Empresa ABC)
  │
  ▼
Workflow Engine
  → Troba workflow: "Onboarding d'empleats" (actiu per Empresa ABC)
  → Crea workflow_run (id: run_001, status: RUNNING)
  → Crea 5 step_runs (PENDING)
  → Encua step_run_1 a automation_queue
  │
  ▼ Step 1: GENERATE_DOCUMENT
  → Genera "Contracte de treball" via sign-document-router
  → Output: { document_id: "doc_123" }
  → Encua step_run_2
  │
  ▼ Step 2: HUMAN_APPROVAL  ← BAM
  → Crea pending_approval: "Revisa el contracte de Maria García"
  → context_preview: { document_preview_url, employee_data }
  → workflow_run.status = WAITING_HUMAN
  → (espera...)
  │
  ▼  [Manager aprova al BAM Inbox]
  → step_run_2.status = COMPLETED (approved_by: manager_id)
  → workflow_run.status = RUNNING
  → Encua step_run_3
  │
  ▼ Step 3: SEND_FOR_SIGNING
  → Envia "Contracte" a DocuSeal amb rol "Empleat"
  → Output: { submission_id: "sub_456" }
  → workflow_run.status = WAITING_TIMER (espera callback DocuSeal)
  │
  ▼  [Callback DocuSeal: DOCUMENT_SIGNED]
  → Nou event → workflow_run reprèn (step_run_4 encuada)
  │
  ▼ Step 4: SEND_EMAIL
  → Envia email "Benvinguda, Maria!" via email_send_queue
  │
  ▼ Step 5: CREATE_CALENDAR_EVENT
  → Crea event "Primer dia - Maria García" al calendari del manager
  │
  ▼ workflow_run.status = COMPLETED
```

### Flux 2: Venciment de data d'un document

```
pg_cron: cada matí 08:00 UTC
  │
  ▼
process-date-triggers (Edge Function)
  → Busca documents amb camps date i automation.trigger=true
  → Per cada document amb data = TODAY + N dies:
       pgmq.send('workflow_trigger_queue', {
         event_type: 'DATE_FIELD_REACHED',
         entity_type: 'document',
         entity_id: doc.id,
         payload: { field_key: 'data_fi_contracte', days_ahead: 30 }
       })
  │
  ▼
Workflow Engine
  → Troba workflow: "Avís renovació de contracte" (actiu per tenant)
  → Crea workflow_run → encua Step 1
  │
  ▼ Step 1: SEND_EMAIL
  → Envia "El contracte de Maria venç en 30 dies"
  │
  ▼ Step 2: CREATE_TASK
  → Crea tasca "Gestionar renovació contracte" al gestor RRHH
  │
  ▼ COMPLETED
```

### Flux 3: Branching condicional (CONDITION step)

```
EVENT: LEAD_CREATED
  │
  ▼
Step 1: CONDITION
  → condition: "{{ lead.source }} == 'web_contact_form'"
  → if true  → on_success: "step_2a"
  → if false → on_success: "step_2b"
  │
  ├─▼ [true]  Step 2a: SEND_EMAIL (template: "resposta_formulari_web")
  └─▼ [false] Step 2b: SEND_EMAIL (template: "resposta_generica_lead")
  │
  ▼ Step 3: CREATE_TASK
  → "Seguiment lead: {{ lead.company_name }}"
  │
  ▼ COMPLETED
```

**Nota sobre branching:** El CONDITION step és l'únic mecanisme de branching suportat a V1. No hi ha branches paral·leles, merge points ni gateways inclusius. Si es necessita lògica de flux avançada → integrar n8n via V2.

### Flux 4: Workflow aturat per error

```
Step 3: SEND_FOR_SIGNING
  → Crida a DocuSeal → error 500
  → QueueRunner: retry 1 (30s) → falla
  → QueueRunner: retry 2 (2min) → falla
  → QueueRunner: retry 3 (5min) → falla
  → step_run.status = FAILED
  → workflow_run.status = FAILED
  → pgmq: notificació DLQ
  │
  ▼
Action Handler: failure notification
  → data.notifications → owner/manager del tenant
  → "El workflow 'Onboarding Maria García' ha fallat al pas 'Enviar per signar'"
  │
  ▼
Automation Center (UI)
  → Mostra workflow en estat FAILED
  → Detall: "Step 3 SEND_FOR_SIGNING: DocuSeal timeout"
  → Botó: [Reintentar des d'aquí] [Cancel·lar workflow]
```

---

## 7. Decisions arquitectòniques justificades

### D1 — Workflow Definitions vs. Automation Rules

**Decisió:** Usar `automation_workflows` (amb steps array JSONB) en lloc de `automation_rules` (una regla = una acció).

**Justificació:**  
El model de regles (`EMPLOYEE_CREATED → SEND_EMAIL`) escala malament. Quan un tenant configura 5, 10, 20 regles per al mateix event, apareix el problema que `re_revisio_pla.md` descriu exactament:

> "En 2 anys tindreu 37 regles, 15 excepcions, 8 dependències ocultes i ningú sabrà què passa quan es crea un empleat."

Un Workflow agrupa totes les accions relacionades en un únic objecte coherent i observable. L'usuari veu "Onboarding d'empleats" com una unitat, no com una llista de regles disperses.

**Impacte en implementació:** La taula `automation_workflows` requereix una mica més de lògica al worker (llegir el JSONB dels steps, gestionar el graf), però el guany en observabilitat i mantenibilitat és molt superior al cost.

---

### D2 — DAGs simples, no BPMN

**Decisió:** El model de steps és un DAG simple: cada step té `on_success` i `on_failure` que apunten a l'`id` del next step o a `END_FAIL`/`END_OK`. No hi ha join points, parallel gateways ni loops.

**Justificació:**  
El 95% dels workflows d'un ERP SaaS son lineals o amb un sol if/else. Parallel gateways (executa A i B en paral·lel, espera tots dos) és una complexitat que:
1. Triplica la complexitat del worker
2. És gairebé mai necessária per als fluxos reals del sistema
3. Si es necessita → el client connecta n8n via la API externa (V2)

**Comparació:** GitHub Actions suporta jobs paral·lels, però els workflows bàsics d'onboarding d'un SaaS no ho necesiten. n8n/Zapier/Make és el destí natural per a fluxos complexos.

---

### D3 — CloudEvents: sí, però en el lloc correcte

**Decisió:** Adoptar el format CloudEvents **únicament per a la interfície externa** (webhooks sortints V2). Internament usar un envelope simplificat.

**Justificació:**  
CloudEvents és un estàndard CNCF que dóna interoperabilitat immediata amb n8n, Make i Zapier (que el suporten nativament). Adoptar-lo externament ens dóna:
- Compatibilitat automàtica amb eines iPaaS
- Format familiar per a desarrolladors integrant l'ERP
- Preparació per a EventBridge/Pub-Sub en el futur

Però internament, CloudEvents afegeix un envelope de 5-8 camps addicionals per cada missatge PGMQ. Per a milers de missatges per dia, l'overhead és innecessari. L'envelope intern es transforma a CloudEvents just abans de fer el POST extern.

**Format intern (simplificat):**
```json
{
  "event_type": "employee.created",
  "tenant_id": "...",
  "entity_id": "...",
  "payload": { ... },
  "ts": "2026-06-11T10:00:00Z"
}
```

**Format extern (CloudEvents):**
```json
{
  "specversion": "1.0",
  "type": "com.app.employee.created",
  "source": "/tenants/empresa-abc/hr",
  "id": "wh_evt_01abc123",
  "time": "2026-06-11T10:00:00Z",
  "datacontenttype": "application/json",
  "data": { ... }
}
```

---

### D4 — PGMQ com a Outbox (no es crea cap nova taula)

**Decisió:** No crear cap taula `event_outbox`. PGMQ ja actua com a Outbox transaccional.

**Justificació (de `consideracions_critiques.md`):**  
Cridar `pgmq.send()` dins de la mateixa transacció SQL que modifica la dada (o en un trigger `AFTER INSERT`) és transaccional. Si la transacció fa rollback, el missatge NO s'envia. Ja tenim el patró Transactional Outbox sense codi extra.

Crear una taula `event_outbox` separada seria duplicar el que PGMQ ja fa.

---

### D5 — No Saga Pattern, no compensacions

**Decisió:** Quan un workflow falla, l'estratègia és: retry automàtic → intervenció manual. No es reverteixen accions prèvies.

**Justificació:**  
Les compensacions (revertir l'empleat creat si falla l'email) son tècnicament complexes i conceptualment incorrectes per a la majoria de casos d'ERP:

- Un empleat s'ha creat perquè l'empresa l'ha contractat. Que falli un email no invalida la contractació.
- Un document s'ha generat i arxivat. Que falli la signatura no esborra el document.
- Les "compensacions" correctes en negoci son processos de negoci (ex: cancel·lar contracte), no rollbacks tècnics automàtics.

**Model de fallada:** El workflow s'atura en el pas fallat. L'Automation Center mostra l'error. Un operador humà pot: (a) reintentar el pas, (b) saltar el pas marcant-lo com a completat manualment, (c) cancel·lar el workflow.

---

### D6 — Acoblament calendari-plantilla: desacoblar via events

**Decisió:** La creació d'events de calendari a partir de dates de documents NO s'ha de fer dins de la lògica de generació del document.

**Justificació (de `consideracions_critiques.md`):**  
El pla original proposava que `sign-document-router` escaneés el `variable_schema` i creés events de calendari. Això acobla dues coses que no haurien d'estar acoblades:

- La generació d'un document és una acció de la capa de presentació/storage
- La creació d'un event de calendari és una regla de negoci

**Solució correcta:** El trigger `DOCUMENT_GENERATED` dispara el Workflow Engine. Un step de tipus `CREATE_CALENDAR_EVENT` dins el workflow extreu la data del `context` (que inclou les variables del document) i crea l'event. La lògica viu al workflow, no al router de documents.

---

### D7 — Human Approval com a step natiu

**Decisió:** `HUMAN_APPROVAL` és un tipus de pas de primera classe, no una funcionalitat addicional.

**Justificació:**  
Sense aprovació humana, no es poden construir processos reals d'onboarding, aprovació de contractes ni validació de documents. El 80% dels workflows útils en un ERP necessiten almenys un punt de validació humana.

Implementar-ho com un step natiu simplifica molt la lògica: el workflow s'atura (`WAITING_HUMAN`), l'aprovació es crea a `automation_pending_approvals`, i quan l'usuari aprova/rebutja, el workflow reprèn o falla.

---

### D8 — AI com a tipus de step opcional

**Decisió:** Les AI Actions (`AI_EXTRACT`, `AI_CLASSIFY`, `AI_GENERATE`, `AI_DECIDE`) es dissenyen com a tipus de step normalitzats però NO s'implementen a V1.

**Justificació:**  
El mercat de 2026 fa que la IA sigui un avantatge diferenciador real, però:
1. Afegir IA a V1 incrementa la complexitat del motor sense que la majoria de clients l'usin
2. Les API d'IA s'han de configurar per tenant (claus pròpies) → requereix un sistema de gestió de claus externes
3. La confiança de l'IA necessita un mecanisme Human-in-the-Loop, que és la mateixa infraestructura de HUMAN_APPROVAL → ja estarà feta a V1

**Preparació del motor:** El sistema de steps és extensible per disseny. Afegir un nou `step_type` és afegir un nou handler al worker. Quan V2 implementa `AI_EXTRACT`, no cal tocar el workflow engine.

---

## 8. Automation Center — Disseny UX

### Filosofia de disseny

L'Automation Center no és una pàgina de configuració. És una pàgina d'operació. El seu usuari principal és l'operador/gestor que vol saber "Que està passant ara?" i "Qué ha fallat?".

La configuració (crear/editar workflows) és una funció secundària accessible però no el cor de la pantalla.

### Estructura de pantalles

#### 8.1 Dashboard principal

```
Automation Center
─────────────────────────────────────────────────────

  [ Resum ]

  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌────────────┐
  │  En curs   │  │  Aprovació │  │  Fallits   │  │ Completats │
  │     12     │  │  pendent 3 │  │     2      │  │   1.847    │
  └────────────┘  └────────────┘  └────────────┘  └────────────┘
  
  [ Aprovacions Pendents ]  ← prioritat visual alta
  
  ┌───────────────────────────────────────────────────────────────┐
  │ 🔴  Contracte Jordi López   — Onboarding empleats   Avui 10:30│
  │     Revisa i aprova el document abans de continuar            │
  │     [Veure detall]                                            │
  ├───────────────────────────────────────────────────────────────┤
  │ 🟡  Proposta Empresa XYZ    — Alta de client         Ahir    │
  │     [Veure detall]                                            │
  └───────────────────────────────────────────────────────────────┘

  [ Errors Recents ]
  
  ┌───────────────────────────────────────────────────────────────┐
  │ ❌  Onboarding Maria García  — Pas 3: Enviar per signar        │
  │     DocuSeal timeout. Última execució: fa 2 hores             │
  │     [Reintentar] [Detall]                                     │
  └───────────────────────────────────────────────────────────────┘

  [ Activitat Recent ]   (últimes 24h)
  ...llista de workflow_runs completats/en curs...
```

#### 8.2 Vista de Workflow Run (detall)

```
Workflow: Onboarding d'empleats
Trigger: EMPLOYEE_CREATED — Maria García
Iniciat: 11/06/2026 10:30
Estat: WAITING_HUMAN (Pas 2)

  Timeline:
  
  ✓ Pas 1: Generar contracte        [COMPLETED]  10:30:05 → 10:30:08  (3.2s)
     ↓ Output: document_id=doc_123
  
  ⏳ Pas 2: Revisió humana           [WAITING_HUMAN]  10:30:08
     ↓ Assignat a: RRHH Manager
     ↓ Venciment: demà 10:30
     [Aprovar] [Rebutjar] [Reassignar]
  
  □ Pas 3: Enviar per signar         [PENDING]
  □ Pas 4: Email de benvinguda       [PENDING]
  □ Pas 5: Crear event calendari     [PENDING]

  [Cancel·lar workflow]
```

#### 8.3 Catàleg de Workflows

```
Els meus workflows

  Blueprints disponibles:
  ┌────────────────────────────────────────┐
  │ 📦 Onboarding d'empleats       [+Afegir]│
  │ 📦 Alta de client              [+Afegir]│
  │ 📦 Renovació de contractes     [+Afegir]│
  └────────────────────────────────────────┘

  Workflows actius:
  ┌────────────────────────────────────────────────────┐
  │ ✅ Onboarding d'empleats    ACTIU   [Editar][Stop] │
  │    87 execucions · 3 fallides · últim: fa 2 hores  │
  ├────────────────────────────────────────────────────┤
  │ ✅ Venciments de contractes ACTIU   [Editar][Stop] │
  │    12 execucions · 0 fallides · últim: fa 3 dies   │
  └────────────────────────────────────────────────────┘

  [+ Crear workflow buit]
```

#### 8.4 Editor de Workflow

L'editor és deliberadament senzill. No és un canvas visual de nodes (massa complex d'implementar a V1). És un editor de llista de passos:

```
Workflow: Onboarding d'empleats
Trigger: Quan es crea un empleat ▼

Steps:
  1. [📄 Generar document]  Contracte laboral         [✏️][🗑️]
  2. [👤 Aprovació humana]  Revisar contracte         [✏️][🗑️]
  3. [✍️ Enviar a signar ]  Empleat + Empresa         [✏️][🗑️]
  4. [📧 Enviar email    ]  Benvinguda                [✏️][🗑️]
  5. [📅 Crear event     ]  Primer dia laboral        [✏️][🗑️]

  [+ Afegir pas]

[Guardar] [Activar/Desactivar] [Provar en mode sandbox]
```

**Nota sobre l'editor visual de nodes (canvas):** És una funcionalitat desitjable a llarg termini (V3) però innecessària per a V1. La llista de passos és suficient per a la majoria de workflows lineals. Un canvas visual s'afegeix com a millora de UX quan el producte madura.

---

## 9. Business Automation Manager (BAM)

### Concepte

El BAM és la vista del gestor dins de l'Automation Center. No és una pàgina separada: és la pestanya/secció "Aprovacions Pendents" amb una experiència enriquida.

### Funció principal: Inbox d'aprovació

Quan un workflow arriba a un pas de tipus `HUMAN_APPROVAL`:
1. Es crea un registre a `automation_pending_approvals`
2. S'envia una notificació in-app + email al responsable
3. L'aprovació apareix a l'Inbox del BAM amb tot el context necessari per decidir

### Context d'una aprovació BAM

El sistema mostra al gestor tot el necessari per prendre la decisió sense sortir de la pantalla:

```
Aprovació pendent: Contracte de treball
Workflow: Onboarding d'empleats
Empleat: Maria García — Departament: RRHH — Data inici: 01/07/2026

  [ Preview del document ]           [ Dades de l'empleat ]
  ┌──────────────────────┐           ┌──────────────────────┐
  │  CONTRACTE           │           │ Nom: Maria García    │
  │  Maria García        │           │ Email: maria@...     │
  │  Empresa ABC S.L.    │           │ Dept: RRHH           │
  │  ...                 │           │ Manager: Joan Puig   │
  └──────────────────────┘           └──────────────────────┘

  Comentari (opcional): [________________________]

  [✅ Aprovar i continuar]  [❌ Rebutjar]  [↩️ Reassignar]
```

### Accions del gestor al BAM

| Acció | Comportament del workflow |
|-------|--------------------------|
| **Aprovar** | `step_run.status = COMPLETED`, workflow reprèn al pas següent |
| **Rebutjar** | `step_run.status = FAILED`, workflow va a `on_failure` (pot acabar o anar a un pas alternativus) |
| **Reassignar** | Canvia `assigned_to_user_id`, es reenvía la notificació |
| **Comentar** | Afegeix nota a `step_run.output.comment`, visible a l'historial |
| **Escalar** | (V2) Avisa el supervisor si no hi ha resposta en X hores |

### Tipos de passos que passen pel BAM

A V1:
- `HUMAN_APPROVAL`: Revisió i aprovació genèrica (document, dades, decisió)

A V2 (AI-in-the-Loop):
- `AI_DECIDE` amb confiança baixa → automàticament cau al BAM com a `HUMAN_APPROVAL`
- `AI_EXTRACT` amb camps amb confiança < threshold → BAM mostra els camps per correcció

---

## 10. Blueprints i adopció

### El problema real d'adopció

La tecnologia de workflows és inútil si els clients no la usen. El problema de fons:

> La majoria de clients d'un ERP SaaS **no saben que volen automatització** fins que la veuen funcionant.

Zapier va créixer no perquè tingués la millor tecnologia, sinó perquè va abastar el problema d'adopció: **plantilles predefinides**. HubSpot, Notion, Power Automate, Shopify: tots han après la mateixa lliçó.

### Arquitectura de Blueprints

Un **Blueprint** és un workflow definit per l'equip de la plataforma, marcat com a `is_blueprint=true` i amb `tenant_id=NULL` (és a dir, visible per tots els tenants).

Quan un tenant "instal·la" un blueprint:
1. Es clona el workflow (INSERT amb `source_blueprint_id` apuntant al blueprint)
2. L'usuari configura les variables obligatòries (quina plantilla de document, quina carpeta DMS, quin email template)
3. El workflow queda actiu i lligat al tenant

### Catàleg de Blueprints de Plataforma (V1)

| Blueprint | Trigger | Steps inclosos |
|-----------|---------|----------------|
| **Onboarding d'empleats** | `EMPLOYEE_CREATED` | Generar contracte → Aprovació manager → Enviar a signar → Email benvinguda → Event calendari |
| **Renovació de contractes** | `DATE_FIELD_REACHED` (data_fi_contracte, 30d) | Email avís renovació → Crear tasca RRHH |
| **Alta de client / lead** | `CONTACT_CREATED` o `LEAD_CREATED` | Email de benvinguda → Crear tasca comercial → Notificació manager |
| **Ordre de treball (EAM)** | `WORK_ORDER_CREATED` | Notificació tècnic → Crear event calendari → Generar fitxa OT (opcional) |
| **Signatura completada** | `DOCUMENT_SIGNED` | Email confirmació a tots els signataris → Arxivar a carpeta DMS |
| **Gestió de vacances** | `ABSENCE_REQUESTED` | Notificació manager → Aprovació manager → Notificació empleat |

### Variables de configuració d'un Blueprint

Quan un tenant instal·la un blueprint, configura les variables que el blueprint exposa:

```
Configurar Blueprint: "Onboarding d'empleats"

  Pas 1 — Generar contracte:
    Plantilla: [ Contracte laboral estàndard ▼ ]
    Carpeta destí: [ RRHH/Contractes ▼ ]
  
  Pas 2 — Aprovació:
    Responsable: [ RRHH Manager ▼ ] o [ Rol: owner ▼ ]
  
  Pas 4 — Email benvinguda:
    Plantilla email: [ welcome_employee ▼ ]
  
  [✅ Instal·lar blueprint]
```

### Evolució dels Blueprints

**V1:** Catàleg de 5-6 blueprints de la plataforma, instal·lables amb configuració guiada  
**V2:** Blueprints compartibles entre tenants del mateix sector (marketplace intern)  
**V3:** Marketplace públic de blueprints (contribuïdors externs), similar a Zapier Templates  

---

## 11. AI-in-the-Loop

### Filosofia: optional i per tenant

La IA no és obligatòria. El sistema funciona al 100% sense IA. La IA és una capa addicional que cada tenant pot activar configurant les seves pròpies claus d'API.

### Preparació del motor per a V1 (sense implementar)

El worker d'automatització (`process-automation-queue`) és extensible per step_type. Afegir `AI_EXTRACT` a V2 requereix:
1. Un nou handler en el worker
2. Un nou tipus de configuració al JSONB del step
3. Lògica de confiança + fallback al BAM

No requereix modificar el workflow engine, l'Automation Center ni les taules principals.

### Accions AI previstes per V2

| Acció | Descripció | Cas d'ús |
|-------|------------|----------|
| `AI_EXTRACT` | Extreu dades estructurades d'un document | Factura PDF → { proveïdor, import, data } |
| `AI_CLASSIFY` | Classifica un element en categories | Email entrant → categoria: reclamació/consulta/comanda |
| `AI_GENERATE` | Genera text en base a context | Draft d'email de resposta a un lead |
| `AI_DECIDE` | Pren una decisió en base a context | "Cal escalament urgent?" → sí/no + confiança |

### Human-in-the-Loop per a IA

Quan un step d'IA retorna `confidence < threshold`:

```
Step: AI_EXTRACT (factura PDF)
Resultat: { import: 1.234,56, proveïdor: "Empresa XYZ" }
Confiança: 72%  ← per sota del threshold configurat (85%)

→ workflow_run.status = WAITING_HUMAN
→ BAM Inbox: "Revisa l'extracció automàtica de la factura"
   Mostra: [Document original] vs [Dades extretes]
   Gestor corregeix les dades → [Confirmar]
→ workflow reprèn amb les dades corregides
```

### Configuració d'IA per tenant

El sistema necessita una nova secció a `settings/IntegrationsPage` (V2):

```
Configuració d'Intel·ligència Artificial

  Proveïdor: [ OpenAI ▼ ]  [ Anthropic ]  [ Gemini ]  [ Azure OpenAI ]  [ Ollama ]
  API Key: [••••••••••••••••]  [Verificar]
  Model: [ gpt-4o ▼ ]
  Threshold de confiança: [ 85% ]
  
  Nota: La clau es guarda de forma segura a Vault. Mai es mostra en clar.
```

### Agents (V3)

Els agents autònoms (un "actor" al sistema que pren decisions i executa tasques) és una evolució natural però no es planifica fins a V3. L'arquitectura de step types és compatible: un step `AGENT_TASK` és simplement un nou handler que invoca un agent via API.

---

## 12. Multi-tenant i multi-site

### Workflows i scope

| Scope | Descripció | Cas d'ús |
|-------|------------|----------|
| **Plataforma** | `tenant_id=NULL`, `is_blueprint=true` | Blueprints APP, visibles a tots els tenants |
| **Tenant global** | `tenant_id=X`, `site_id=NULL` | Workflow actiu per a tot el tenant |
| **Site específic** | `tenant_id=X`, `site_id=Y` | Workflow actiu només per a un local concret |

### Exemple: workflow diferent per site

Una empresa amb 3 locals pot tenir:
- Workflow "Onboarding estàndard" → `site_id=NULL` (s'aplica a tots els locals)
- Workflow "Onboarding Fàbrica" → `site_id=fabrica` (s'aplica solo a la Fàbrica, sobreescriu l'anterior)

**Regla de resolució:** El Workflow Engine aplica el workflow de site si existeix; si no, el del tenant; si no, cap workflow.

### Aprovacions i multi-site

Un pas `HUMAN_APPROVAL` pot assignar-se a:
- Un usuari concret (per `user_id`)
- Un rol global del tenant (ex: `owner`, `manager`)
- Un rol limitat a un site (ex: `manager` del `site_id` de l'entitat que ha disparat el trigger)

Això garanteix que l'aprovació d'un contracte d'un empleat de la Fàbrica arribi al manager de la Fàbrica, no al manager global.

### Blueprints i multi-tenant

Els Blueprints de plataforma son accessibles per tots els tenants però **cadascun en guarda la seva còpia** quan l'instal·la. Modificar un Blueprint de plataforma **no afecta** als workflows ja instal·lats pels tenants (evita breaking changes).

Un sistema de **Blueprint versions** (V2) podria permetre notificar als tenants que hi ha una versió nova del Blueprint instal·lat amb l'opció de migrar.

### RLS i seguretat

Tots les taules de workflows, runs i approvals han de tenir RLS activat:
- Un tenant no pot veure els workflows ni execucions d'un altre
- Dins d'un tenant, les approvals son visibles per als usuaris amb el rol adequat
- L'admin-portal pot accedir a totes les dades via `BYPASSRLS` (Prisma) per a monitoring global

---

## 13. Comparativa amb el sector

| Plataforma | Model | Aprendre | No copiar |
|------------|-------|----------|-----------|
| **n8n** | Nodes interconnectats, canvas visual | Canvas visual (V3); extensible per nous nodes | Complexitat de configuració per a usuaris no tècnics |
| **Make** | Mòduls i escenaris, UI polida | UX accessible, Blueprints (Templates), mòduls clars | Pricing per operació (no rellevant per a SaaS intern) |
| **Zapier** | Zaps (trigger + actions), mercat enorme | Templates pre-built, focus en no-tècnics | Complexitat de certificació |
| **Power Automate** | Flows i connectors, integrat MS365 | Human Approval natiu, integració profunda amb eines | Complexitat excessiva, UI saturada |
| **HubSpot** | Workflows de CRM, condicions visuals | Enrolment criteria clars, branching simple, templates per rol | Centrat en CRM, no generalista |
| **Odoo** | Automated Actions, marketing automation | Proximity al model de dades, no necessita coneixements d'automatització | Acoblament excessiu al model de Odoo |
| **Temporal** | Durable execution, codi Python/Go | Idea de durable workflows (reprendre des del pas on es va quedar) | Complexitat operacional, requereix Temporal cluster |
| **Camunda** | BPMN complet, motor industrial | Observabilitat de process instances | BPMN XML, massa complex per a SaaS ERP |

### El model que millor s'assembla al nostre objectiu

**HubSpot Workflows + Power Automate (la part d'aprovacions)** és la combinació que més s'acosta al que volem construir:

- HubSpot: Workflows senzills, templates per cas d'ús, enrollment criteria clars
- Power Automate: Human Approval natiu, context ric a les aprovacions

El que el nostre sistema aporta que cap dels anteriors té de forma integrada: **generació de documents, signatura electrònica i DMS** com a steps de primera classe. Aquí és on l'APP té un avantatge diferencial.

---

## 14. Roadmap recomanat

### V1 — Motor d'Automatització (2-3 mesos)

**Objectiu:** Workflows funcionals, observables i adoptables pel 80% dels clients via Blueprints.

#### Sprint 1 — Infraestructura (3 setmanes)
- Taules: `automation_workflows`, `automation_runs`, `automation_step_runs`
- Cues PGMQ: `workflow_trigger_queue`, `automation_queue`
- Trigger PostgreSQL: `AFTER INSERT on audit_logs` → `workflow_trigger_queue`
- Edge Function: `process-workflow-triggers` (Workflow Engine)
- Edge Function: `process-automation-queue` (Step Executor, QueueRunner)

#### Sprint 2 — Action Handlers bàsics (2 setmanes)
- Handlers: `SEND_EMAIL`, `SEND_NOTIFICATION`, `CREATE_TASK`, `CREATE_CALENDAR_EVENT`
- Handlers: `GENERATE_DOCUMENT`, `SEND_FOR_SIGNING` (reutilitzen Edge Functions existents)
- Handler: `CONDITION` (branching bàsic)
- Handler: `UPDATE_FIELD`

#### Sprint 3 — Human Approval + BAM (2 setmanes)
- Taula: `automation_pending_approvals`
- Handler: `HUMAN_APPROVAL` → crea pending_approval → notificació
- Edge Function: `resolve-automation-approval` (aprovar/rebutjar/reassignar)
- Handler dates: `process-date-triggers` (pg_cron diàri)

#### Sprint 4 — Automation Center UI (2 setmanes)
- Dashboard: comptadors, aprovacions pendents, errors recents
- Vista de Workflow Run: timeline de passos, estat, accions (retry, cancel)
- Editor de Workflow: llista de passos, configuració per step
- Catàleg de Blueprints: instal·lar amb configuració guiada

#### Sprint 5 — Blueprints de plataforma (1 setmana)
- 5 Blueprints inicials: Onboarding empleat, Alta de client, Renovació contractes, OT EAM, Signatura completada, Gestió vacances
- Tests end-to-end per cada blueprint

**Al final de V1:**
- Workflows de múltiples passos funcionals
- Aprovació humana nativa
- Automation Center amb observabilitat completa
- 6 Blueprints instal·lables amb un clic
- Events de calendari automàtics a partir de dates de documents

---

### V2 — API Externa + Webhooks (1-2 mesos)

**Objectiu:** Connectar l'ERP amb n8n, Make, Zapier i REST API.

- Taules: `data.api_keys`, `data.webhook_subscriptions`, `data.webhook_delivery_logs`
- Edge Functions: `manage-api-keys`, `process-webhook-dispatch`
- Handler `WEBHOOK_OUTBOUND` al Step Executor
- REST API pública: `api-v1-employees`, `api-v1-documents`, `api-v1-contacts`
- Format extern: CloudEvents per als webhooks sortints
- UI: `settings/IntegrationsPage` (API Keys + Webhook Subscriptions)
- Docs: Quick Start Guides per n8n, Make, Zapier

---

### V2.1 — AI Actions (1-2 mesos, si volum ho justifica)

**Objectiu:** Primera integració d'IA com a step opcional.

- Taula de configuració d'IA per tenant (clau a Vault)
- Handler `AI_EXTRACT` (primer: extracció de dades d'un document PDF)
- Lògica de confiança + fallback BAM
- UI: `settings/IntegrationsPage` — secció IA

---

### V3 — Canvas visual + Marketplace Blueprints (+ 3 mesos)

**Objectiu:** Millorar UX avançada i mercat de Blueprints.

- Canvas visual de nodes per a l'editor de workflows
- n8n Community Node + Make Custom App
- Sistema de versions de Blueprints (notificació d'actualitzacions)
- AI Agents com a tipus d'actor (V3+)

---

### Diagrama temporal

```
Mes 1-2       Mes 2-3       Mes 3-4       Mes 4-6       Mes 6+
│─────────────│─────────────│─────────────│─────────────│──────...
│             │             │             │             │
│  V1-Sprint1 │  V1-Sprint3 │  V1-Sprint5 │  V2         │  V2.1
│  Infra      │  HUMAN_APPR │  Blueprints │  API Keys   │  AI Steps
│  Engine     │  BAM        │  6 packs    │  Webhooks   │
│  Sprint2    │  Sprint4    │             │  REST API   │
│  Handlers   │  UI         │             │             │
```

---

## 15. Recomanació final

### Resum en 5 decisions

**1. Workflows, no regles:**  
Implementar `automation_workflows` amb steps JSONB des del principi. El model de regles (`automation_rules`) no escala per a processos multi-step i genera deute tècnic inevitable.

**2. Execution store és no negociable:**  
`automation_runs` + `automation_step_runs` son imprescindibles. Sense ells, l'Automation Center no té res a mostrar i el debugging és impossible. El cost d'implementació és modest i el valor és enorme.

**3. HUMAN_APPROVAL des de V1:**  
No posposar l'aprovació humana. És el que transforma un sistema de notificacions automàtiques en un sistema de gestió de processos real. Sense el BAM Inbox, els clients no confien en les automatitzacions perquè no poden intervenir.

**4. Blueprints des de V1:**  
El camí cap a l'adopció és via Blueprints, no via configuració manual de workflows. 6 Blueprints ben dissenyats tindran més impacte en l'adopció que 20 hores d'engine tècnic.

**5. AI-ready des del principi, però implementada a V2:**  
El motor de steps és extensible per disseny. No cal codi d'IA a V1. Preparar l'arquitectura de tenant API keys i el mecanisme de confiança/fallback al BAM. Implementar el primer step d'IA (AI_EXTRACT) quan hi hagi claredat sobre quin cas d'ús té més demanda real.

---

### Posicionar  al mercat

Els competidors d'ERP (Odoo, Holded, Factorial) no ofereixen automatització de documents, signatura i calendari en un sol motor de workflows. Aquí és on l'app té un avantatge diferencial clar:

```
La proposta de valor única:
  Genera contracte  →  Firma digitalment  →  Arxiva al DMS  →  Crea event calendari
  tot en un sol workflow, visible i controlable des d'una sola pantalla
```

Això no ho ofereix cap iPaaS extern (n8n/Zapier) de forma integrada perquè requereix accés profund als models de dades de l'ERP.


---

## 16. Annex — Decisions sobre Aprovacions, Trigger Principal i Adjunts

**Estat:** Decidit — afegir al disseny V1 (excepte 16.4, que queda preparat però no implementat)

Aquest annex precisa com funcionen, en la pràctica, els fluxos d'aprovació, el trigger d'origen més habitual i l'enviament de documents per correu. Substitueix/aclareix la lectura inicial de `HUMAN_APPROVAL` com a mecanisme de decisió de negoci.

### 16.1 — Aprovacions de negoci via signatura, no via `HUMAN_APPROVAL`

**Decisió:** Quan el flux requereix que una persona **decideixi** sobre el contingut d'un document (aprovar/rebutjar un augment salarial, un pressupost, una sol·licitud, etc.), aquesta decisió es modela com un **flux de signatura/acceptació del propi document**, no com un pas `HUMAN_APPROVAL` dins del workflow.

**Per què:**
- Reaprofita la infraestructura de signatura ja existent (preferentment el motor de **firma pròpia**, sense costos externs per signatura, davant de DocuSeal quan sigui aplicable).
- Manté `HUMAN_APPROVAL` amb una semàntica simple i única: **supervisió/checkpoint** sobre l'execució de l'automatització (revisar que els destinataris, textos, adjunts, etc. d'un pas siguin correctes abans de continuar), resolt amb `approved`/`rejected` i sense necessitat de branques de negoci addicionals al motor (`on_success`/`on_failure` n'hi ha prou).
- La "decisió de negoci" (accepto l'augment / no l'accepto) queda enregistrada de forma natural com a part del cicle de vida del document (signat / rebutjat), amb el seu propi `audit_log`.

**Com funciona el flux:**
```
1. Workflow A (trigger: DOCUMENT_GENERATED, template: "Augment salarial")
     → SEND_FOR_SIGNING (signatura pròpia) al responsable
     → workflow_run.status = COMPLETED (la feina del workflow A acaba aquí)

2. [El responsable signa o rebutja el document]
     → audit_log: DOCUMENT_SIGNATURE_ACCEPTED | DOCUMENT_SIGNATURE_REJECTED
        (amb tenant_id, document_id, template_id, signer_role, ...)

3. Workflow B (trigger: DOCUMENT_SIGNATURE_ACCEPTED | DOCUMENT_SIGNATURE_REJECTED,
                trigger_filters: { template_id: "augment_salarial" })
     → CONDITION segons quin dels dos events ha arribat (o dos workflows separats,
       un per ACCEPTED i un per REJECTED, si es prefereix evitar el CONDITION)
     ├─ ACCEPTED → SEND_EMAIL (notificar empleat/RRHH) + UPDATE_FIELD (nou salari)
     └─ REJECTED → SEND_EMAIL (notificar sol·licitant, sense canvis)
```

**Requisit d'implementació:** assegurar que el motor de signatura pròpia escriu a `audit_logs` un event diferenciat per a **acceptació** i per a **rebuig**, amb prou contexte (`document_id`, `template_id`, rol del signant) perquè `trigger_filters` pugui distingir quin workflow B correspon segons la plantilla d'origen.

**Què queda de `HUMAN_APPROVAL`:** es manté tal com estava definit (taula `automation_pending_approvals`, BAM Inbox, `due_at`/escalations), però **només per a casos de supervisió de l'automatització en si** (ex: "abans d'enviar aquest lot de 50 emails, que un admin ho revisi"), no per a decisions sobre el contingut del document.

---

### 16.2 — Adjunts a `SEND_EMAIL` des de Storage

**Decisió:** El handler `SEND_EMAIL` ha de permetre adjuntar fitxers referenciats per **`storage_object_id`** (o equivalent), típicament l'output d'un pas previ `GENERATE_DOCUMENT` (`{ document_id, storage_object_id }`).

**A confirmar/implementar abans de V1-Sprint2:**
- Si `email_send_queue` ja accepta un array d'adjunts per referència a Storage (id/path), documentar-ho i reutilitzar-ho directament.
- Si no, ampliar el payload de `email_send_queue` per acceptar `attachments: [{ storage_object_id, filename }]`, resolent-se a una URL signada / descàrrega del fitxer en el moment d'enviar (no abans, per evitar URLs caducades).
- El `config` del step `SEND_EMAIL` ha de poder referenciar l'output d'un step anterior (ex: `attachments: ["{{ steps.step_1.output.storage_object_id }}"]`), seguint el mateix mecanisme de referència a outputs previs que ja s'usa per a altres camps del `context`.

Aquest punt és un prerequisit transversal: el flux 16.1 (enviar el document a signar) i qualsevol notificació amb el PDF adjunt en depenen.

---

### 16.3 — Trigger principal: `DOCUMENT_GENERATED`

**Decisió:** El trigger més habitual per a workflows no és un event genèric d'entitat (`EMPLOYEE_CREATED`, etc.) sinó **`DOCUMENT_GENERATED`**, emès cada cop que es genera un document a partir d'una plantilla.

**Filtratge:** `trigger_filters.template_id` (o equivalent) determina quin workflow s'activa per a quina plantilla. Això significa que, a la pràctica, **la majoria de workflows es defineixen "per plantilla"**: generar un document concret és el que dispara tota la cadena (enviar-lo a signar, notificar algú, adjuntar-lo a un email, etc.).

**Context disponible per al workflow:** el `context` (snapshot al moment del trigger) ha d'incloure, a més de l'entitat relacionada (`employee`, `contact`, etc.):
- **`document`**: `{ id, template_id, storage_object_id, locale, ... }`
- **`roles`**: el mapeig de rols de la plantilla resolts a dades concretes (ex: `roles.manager.email`, `roles.worker.full_name`), tal com es defineixen al sistema de plantilles (rols + variables per locale).
- **`variables`**: els valors concrets amb què s'ha generat el document.

**Configuració dels steps amb aquest context:** els camps de configuració dels steps (especialment `SEND_EMAIL.recipients` i `HUMAN_APPROVAL.assigned_to`) han de permetre dues fonts de valor:
- **Des dels rols del document**: `recipient_source: "document_role"`, amb un `role_key` (ex: `manager`) que es resol via `roles.<role_key>.email` del context.
- **Manual/fix**: `recipient_source: "fixed"`, amb una adreça o llista introduïda directament a la configuració del workflow.

Aquesta distinció (`document_role` vs `fixed`) s'ha d'afegir explícitament a l'esquema JSON dels steps `SEND_EMAIL` i, si s'escau, `HUMAN_APPROVAL`.

---

### 16.4 — Estat d'aprovació al DMS/document *(preparat, no implementat a V1)*

**Decisió:** Per a casos on l'aprovació **no** passa per signatura (ex: sol·licitud de vacances, despeses, esborranys interns que un manager ha de validar abans que tinguin efecte), interessa que el **document/DMS guardi el seu propi estat d'aprovació**, consultable per qualsevol usuari que obri la fitxa del document sense passar per l'Automation Center.

**Abast d'aquesta decisió per a V1:**
- **No s'implementa la lògica** d'actualització d'aquest estat a V1.
- **Es deixa preparat l'espai**: en la migració que crea `automation_pending_approvals` (V1-Sprint3), afegir a la taula de documents/DMS les columnes opcionals:
  ```
  approval_status   enum ('none', 'pending', 'approved', 'rejected')  DEFAULT 'none'
  approved_by       uuid (FK users), NULLABLE
  approved_at       timestamptz, NULLABLE
  ```
- Aquestes columnes no tenen cap trigger ni lògica associada a V1; són només l'estructura de dades reservada.

**Implementació futura (quan hi hagi el primer Blueprint que ho requereixi, ex: vacances/despeses):**
1. Un step `HUMAN_APPROVAL` (o un nou tipus de step específic, a valorar) sobre un document que **no** passa per signatura, en crear-se `automation_pending_approvals`, posa `document.approval_status = 'pending'`.
2. En resoldre's l'aprovació (BAM Inbox), s'actualitza `document.approval_status = 'approved' | 'rejected'`, juntament amb `approved_by`/`approved_at`.
3. La UI del DMS mostra aquest estat com a badge/etiqueta a la fitxa del document, independentment de si l'usuari té accés a l'Automation Center.
4. Si en el futur aquest cas es resol també via signatura pròpia (16.1), aquestes columnes podrien quedar en desús per a aquell cas concret — es manté com a mecanisme complementari per a aprovacions sense signatura, no com a substitut.

---

### 16.5 — Resum de canvis respecte al cos del document

| Secció original | Canvi |
|---|---|
| §4.5 (Action Handlers) | `HUMAN_APPROVAL` es manté per a supervisió de l'automatització, no per a decisions de negoci sobre el document |
| §4.5 / step `SEND_EMAIL` | Afegir suport d'adjunts per `storage_object_id`, referenciant outputs de steps previs (16.2) |
| §4.2 (Step definition) | Afegir `recipient_source: "document_role" | "fixed"` a `SEND_EMAIL` (i `assigned_to` a `HUMAN_APPROVAL` si aplica) (16.3) |
| §5 (Model de dades) | `context` del workflow inclou `document`, `roles`, `variables` quan el trigger és `DOCUMENT_GENERATED` (16.3) |
| Trigger catalog | `DOCUMENT_GENERATED` i `DOCUMENT_SIGNATURE_ACCEPTED`/`DOCUMENT_SIGNATURE_REJECTED` com a events de primera classe, emesos pel motor de plantilles i de signatura pròpia respectivament (16.1, 16.3) |
| Migració V1-Sprint3 | Afegir columnes `approval_status`/`approved_by`/`approved_at` (NULLABLE, sense lògica) a la taula de documents (16.4) |

---

## 17. Annex d'implementació — Estat V1.5

**Data d'actualització:** 26 de juny de 2026  
**Abast:** Motor d'Automatització V1 + tancament V1.5 (handlers de document, dates, RPCs de suport). **V2 API/webhooks exclòs** per decisió de producte.

Aquest annex documenta què s'ha construït, què funciona de veritat avui, i què queda pendent — amb el **propòsit** de cada peça pendent i el **valor** que aportarà quan estigui tancada.

### 17.1 Resum executiu

| Àrea | Estat | Notes |
|------|-------|-------|
| Model de dades + PGMQ + trigger `audit_logs` | ✅ Fet | 4 taules, 2 cues, RLS, vistes `api.*` |
| Workflow Engine (`process-workflow-triggers`) | ✅ Fet | Instancia runs i encua el primer step |
| Step Executor (`process-automation-queue`) | ✅ Fet | Handlers, `WAITING_HUMAN`, `WAITING_TIMER`, retry/DLQ |
| Handlers síncrons (email, notificació, tasca, calendari, condició, aprovació, update-field) | ✅ Operatius | RPCs `service_role` a `20260726000001_automation_v1_5_completion.sql` |
| Handlers async (generar document, signar, wait) | ✅ Operatius | PDF job + triggers BD; firma nativa (1 signant MVP) |
| Triggers per data (`process-date-triggers`) | ✅ Operatiu | `SCHEDULED_DAILY` + `DATE_FIELD_REACHED` (`employees.ends_on`) |
| Automation Center (UI tenant-portal) | ✅ Fet | Dashboard, llista, editor, detall de run, blueprints, aprovacions |
| Blueprints de plataforma | ✅ Definits | 5 blueprints; fluxos document end-to-end **pendents de prova E2E** |
| Events `DOCUMENT_GENERATED` / signatura (§16) | ✅ Fet | Trigger `document_pdf_jobs`; trigger `signing_submissions` |
| Context ric (`document`, `roles`, `variables`) | ✅ Fet | `context-builder.ts` + `get_entity_snapshot_for_automation` |
| Columnes `approval_status` a `documents` (§16.4) | ✅ Fet | Sincronitzades amb `HUMAN_APPROVAL` |
| Tests automatitzats E2E | ❌ Pendent | Cap suite SQL/integració dedicada |
| V2 API externa + webhooks | ❌ No iniciat | Roadmap original §14 — fora d'abast actual |

**Conclusió:** El motor és **operable end-to-end** per a workflows lineals i multi-step amb document (generació PDF, signatura, email amb adjunt, aprovació humana, timers). Cal **validació E2E** abans de producció. V2 (API keys, webhooks sortints) roman pendent.

**Migració local:** `20260726000001_automation_v1_5_completion.sql` aplicada correctament (`supabase db reset`). L'error final de *Vector service* al reset és un avís conegut de l'entorn local i no afecta les migracions SQL.

---

### 17.2 Implementat — detall per capa

#### Base de dades (4 migracions)

| Fitxer | Contingut |
|--------|-----------|
| `20260712000001_automation_v1_core.sql` | Enums, taules (`automation_workflows`, `automation_runs`, `automation_step_runs`, `automation_pending_approvals`), cues PGMQ, trigger `audit_logs → workflow_trigger_queue`, RLS, vistes `api.*`, RPCs UI (`upsert`/`delete`/`install_blueprint`/`get_automation_dashboard`/`resolve_automation_approval`/`retry`/`cancel`), pg_cron diari, `api.pgmq_send` |
| `20260712000002_automation_v1_worker_rpcs.sql` | RPCs de worker: `get_active_automation_workflows`, `create_automation_step_runs_service`, `enqueue_automation_step`, `get_automation_execution_context`, `start`/`complete` step/run, overload `create_automation_run_service` |
| `20260712000003_automation_v1_helper_rpcs.sql` | `get_tenant_basic`, `get_site_basic`, `create_automation_pending_approval_service`, `resolve_automation_approval` (encua next step en aprovar) |
| `20260712000004_automation_v1_blueprints.sql` | 5 blueprints: Onboarding empleats, Alta client/lead, Renovació contractes, Signatura completada, Gestió d'absències |

**Flux implementat:**

```
audit_logs INSERT
  → workflow_trigger_queue (PGMQ)
  → process-workflow-triggers
  → automation_runs + automation_step_runs
  → automation_queue
  → process-automation-queue
  → handler del step → next step o estat terminal
```

#### Edge Functions

| Funció | Rol |
|--------|-----|
| `process-workflow-triggers` | Workflow Engine — busca workflows actius, avalua `trigger_filters`, crea run + step_runs, encua step 1 |
| `process-automation-queue` | Step Executor — executa handler, gestiona `WAITING_HUMAN`, encua següent o tanca run |
| `resolve-automation-approval` | Endpoint HTTP autenticat per resoldre aprovacions des de la UI |
| `process-date-triggers` | Cron diari — `SCHEDULED_DAILY`, `DATE_FIELD_REACHED`, represa de timers `WAIT` |

#### Infraestructura compartida (`supabase/functions/_shared/automation/`)

- `types.ts` — tipus del motor (runs, steps, payloads, `WorkflowContext` amb `runtime`)
- `template-engine.ts` — resolució `{{ path.to.value }}` al config dels steps
- `context-builder.ts` — context inicial + snapshot d'entitat (`get_entity_snapshot_for_automation`), `document`/`roles`/`variables`
- `step-executor.ts` — dispatcher per `StepType`
- **10 handlers** a `handlers/`

#### Handlers — estat real (post V1.5)

| Handler | Integració | Estat |
|---------|------------|-------|
| `SEND_EMAIL` | `api.enqueue_email` | ✅ Plantilla/raw; `document_role`; adjunts `storage_path` |
| `SEND_NOTIFICATION` | `api.enqueue_notification` | ✅ `service_role` al worker |
| `CREATE_TASK` | `api.create_automation_task_service` | ✅ Projecte intern "Automatitzacions" auto-creat |
| `CREATE_CALENDAR_EVENT` | `api.create_calendar_event_service` | ✅ Wrapper `service_role` |
| `HUMAN_APPROVAL` | `create_automation_pending_approval_service` + notificació | ✅ `WAITING_HUMAN`; sync `documents.approval_status` |
| `CONDITION` | Lògica interna | ✅ Branching via `nextStepId` |
| `GENERATE_DOCUMENT` | `api.automation_start_generate_document` → PDF queue | ✅ `WAITING_TIMER`; represa via trigger `document_pdf_jobs` |
| `SEND_FOR_SIGNING` | `api.automation_send_for_signing_service` | ✅ Firma nativa (1 signant MVP); represa via `signing_submissions` |
| `UPDATE_FIELD` | `api.update_entity_field_service` | ✅ Whitelist contact/employee/document |
| `WAIT` | `api.schedule_automation_wait` + pg_cron | ✅ Timer real (`wait_until`) |

#### Frontend — Automation Center (`/automation`)

| Component | Funcionalitat |
|-----------|---------------|
| `AutomationDashboard` | Comptadors (en curs, aprovació, fallits, completats avui), aprovacions pendents, errors recents, activitat |
| `WorkflowList` | Llista workflows del tenant, activar/desactivar, editar, eliminar |
| `WorkflowEditor` | Editor de passos (llista + JSON config per step), selector de trigger |
| `WorkflowRunDetail` | Timeline de step_runs, retry, cancel·lar, aprovar inline |
| `BlueprintCatalog` | Catàleg de blueprints de plataforma amb instal·lació |
| `ApprovalDialog` | Modal aprovar/rebutjar/reassignar amb `context_preview` |

Navegació: ruta `/automation` a `App.tsx`, enllaç al sidebar (`AppLayout`) per owners/managers.

---

### 17.3 Implementat V1.5 — detall tècnic

Migració: `supabase/migrations/20260726000001_automation_v1_5_completion.sql`

| Component | Què fa |
|-----------|--------|
| `api.create_automation_task_service` | Crea tasca al projecte intern "Automatitzacions" |
| `api.update_entity_field_service` | Actualització controlada per `entity_type` + whitelist |
| `api.create_calendar_event_service` | Calendari des del worker sense `auth.uid()` |
| `api.automation_start_generate_document` | Encua `create_pdf_job` amb metadata `automation` |
| `api.automation_resume_step_service` | Represa async (PDF/signatura/timer) i encua següent step |
| `api.automation_send_for_signing_service` | Submission + sessió nativa + `signing_submitters` |
| `api.schedule_automation_wait` / `process_automation_wait_timers` | Timers `WAIT` (pg_cron cada 5 min) |
| `api.emit_scheduled_automation_trigger` | Event `SCHEDULED_DAILY` per tenant |
| `api.emit_date_field_triggers_for_tenant` | `employees.ends_on` → `DATE_FIELD_REACHED` |
| `api.get_entity_snapshot_for_automation` | Snapshot contact/employee/document al context |
| Trigger `trg_pdf_job_automation_complete` | `DOCUMENT_GENERATED` + represa step |
| Trigger `trg_signing_submission_automation_audit` | `DOCUMENT_SIGNATURE_*` + represa step |
| Columnes `documents.approval_status` | Badge DMS + sync amb `HUMAN_APPROVAL` |

**Limitacions conegudes V1.5:**

- `SEND_FOR_SIGNING`: només el **primer signant** (multi-signant seqüencial pendent)
- `DATE_FIELD_REACHED`: només camp `employees.ends_on` (altres entitats/camps per afegir)
- URLs de firma: requereix `app.tenant_portal_url` (fallback `app.supabase_url`)
- `CREATE_TASK`: no persisteix `description` (taula `tasks` sense columna)

---

### 17.4 Pendent — validació i polish

| Item | Prioritat | Notes |
|------|-----------|-------|
| **Tests E2E** per blueprint | Alta | Smoke: "Alta de client" → "Onboarding empleats" |
| Multi-signant seqüencial | Mitjana | Paritat amb `sign-document-router` |
| Més camps `DATE_FIELD_REACHED` | Mitjana | Documents, contractes, metadata plantilla |
| `app.tenant_portal_url` a config local | Baixa | URLs de firma correctes en dev |

---

### 17.5 Pendent — V2 (API externa i integracions)

Roadmap original §14, mesos 4–6. **No iniciat.**

| Component | Què fa | Què obtindrem |
|-----------|--------|---------------|
| `data.api_keys` | Claus API per tenant per accedir a l'ERP des de fora | Integració amb n8n, Make, Zapier, scripts propis |
| `data.webhook_subscriptions` + `process-webhook-dispatch` | Webhooks sortints en format CloudEvents | Notificar sistemes externs quan passa un event (empleat creat, document signat, etc.) |
| Handler `WEBHOOK_OUTBOUND` | Step de workflow que fa POST a una URL externa | Fluxos híbrids ERP + iPaaS |
| REST API pública (`api-v1-*`) | CRUD d'empleats, documents, contactes via API Key | Partners i integradors sense accedir al portal |
| `settings/IntegrationsPage` | UI per gestionar API Keys i subscripcions | Autoservei per tenants tècnics |

---

### 17.6 Pendent — V2.1 (AI-in-the-Loop)

| Component | Què fa | Què obtindrem |
|-----------|--------|---------------|
| Config IA per tenant (clau a Vault) | Cada tenant connecta OpenAI/Anthropic | Steps d'IA opcionals sense cost de plataforma |
| Handler `AI_EXTRACT` | Extreu dades estructurades d'un PDF (factura, contracte) | Automatització de comptabilitat i alta de dades |
| Threshold de confiança + fallback BAM | Si confiança < 85%, cau a `HUMAN_APPROVAL` | IA assistida amb supervisió humana nativa |
| Handlers `AI_CLASSIFY`, `AI_GENERATE`, `AI_DECIDE` | Classificació, redacció, decisions | Respostes a leads, triatge de tickets, drafts d'email |

---

### 17.7 Pendent — V3 (UX avançada i marketplace)

| Component | Què fa | Què obtindrem |
|-----------|--------|---------------|
| Editor visual de nodes (canvas) | Drag-and-drop de steps com n8n | Adopció per usuaris no tècnics sense JSON |
| Marketplace de blueprints | Blueprints compartibles entre tenants / sectors | Adopció per vertical (retail, industria, serveis) |
| Versions de blueprints | Notificar tenants quan hi ha versió nova | Evolució de plantilles sense trencar instal·lacions |
| Agent `AGENT_TASK` | Step que invoca un agent autònom | Fluxos adaptatius (V3+, fora d'abast immediat) |

---

### 17.8 Mapa d'estat per Sprint original (§14)

| Sprint | Pla original | Estat juny 2026 |
|--------|--------------|-----------------|
| **Sprint 1** — Infra + Engine | Taules, PGMQ, trigger, 2 Edge Functions | ✅ Complet |
| **Sprint 2** — Handlers bàsics | EMAIL, NOTIFICATION, TASK, CALENDAR, CONDITION, UPDATE_FIELD, GENERATE, SIGNING | ✅ Complet (V1.5) |
| **Sprint 3** — Human Approval + dates | Pending approvals, resolve EF, date-triggers | ✅ Complet |
| **Sprint 4** — Automation Center UI | Dashboard, run detail, editor, blueprints UI | ✅ Complet |
| **Sprint 5** — Blueprints plataforma | 5–6 blueprints instal·lables | ✅ Definits; ⏳ E2E pendent |

---

### 17.9 Fitxers clau (referència ràpida)

```
supabase/migrations/2026071200000{1..4}_automation_v1_*.sql
supabase/migrations/20260726000001_automation_v1_5_completion.sql
supabase/functions/process-workflow-triggers/index.ts
supabase/functions/process-automation-queue/index.ts
supabase/functions/resolve-automation-approval/index.ts
supabase/functions/process-date-triggers/index.ts
supabase/functions/_shared/automation/
apps/tenant-portal/src/features/automation/
apps/tenant-portal/src/pages/AutomationPage.tsx
```

---

### 17.10 Proper pas recomanat

1. **Provar E2E** blueprint "Alta de client" (handlers síncrons) i després "Onboarding d'empleats" (PDF + signatura).
2. **Configurar** `app.tenant_portal_url` a l'entorn local per URLs de firma.
3. **Desplegar** migració V1.5 a staging/producció (`supabase db push`).
4. **V2** (API keys, webhooks) quan el producte ho prioritzi — fora d'abast actual.

---

*Document preparat per: GitHub Copilot (Arquitecte de Sistemes)*  
*Basat en: automation-integrations-roadmap.md v1.0, consideracions_critiques.md, revisió_pla.md, re_revisio_pla.md*  
*Annex §17 actualitzat: implementació V1.5 — juny 2026*
