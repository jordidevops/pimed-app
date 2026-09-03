# 18. Employee Portal — Accés Personal per a Empleats Sense Compte d'App

> **Objectiu**: definir un subsistema d'accés personal per a empleats que no
> disposen (ni necessiten) d'un compte `auth.users` a la plataforma. Han de
> poder veure el seu calendari laboral, els seus torns i fitxar entrada/sortida
> des d'un enllaç personal generat pel manager.
>
> **Revisió 2026-07-02 (v2 seguretat):** decisions d'implementació a [`plan-employee-portal.md`](../plans/checkin/plan-employee-portal.md).

---

## 18.1 Context i Motivació

### El problema real

El mòdul d'assistència (doc 14-17) ja pot fitxar sense `auth.users` via
**mode estació** (`attendance_devices` + `punch-from-station`). Però l'estació
és un dispositiu compartit: l'empleat no pot consultar el seu propi historial
ni calendari de forma personal.

La solució no és crear un usuari per a cada empleat. Crear usuaris:
- Consumeix quota del pla Supabase (`auth.users`).
- Força l'empleat a gestionar credencials.
- Afegeix fricció per a empleats temporals, subcontractats o amb baixa
  competència digital.

El que realment cal és un **portal personal** accessible via un enllaç únic
(token UUID) que el manager genera i envia per WhatsApp, correu o QR imprès.

### Principi clau

> L'egress es consumeix igualment quan un empleat consulta dades.
> El que s'estalvia és la quota d'usuaris i la gestió de credencials.

---

## 18.2 Comparativa de Perfils d'Accés al Mòdul d'Assistència

| Aspecte | Tenant Portal (app user) | Estació fixa | Employee Portal |
|---------|---|---|---|
| **Compte `auth.users`** | Obligatori | No (device secret) | **No** (token UUID) |
| **Qui fa l'acció** | L'empleat autenticat | L'empleat seleccionat a l'estació | L'empleat via token personal |
| **Dades visibles** | Les pròpies + admin veu tot | Només fitxar | **Les pròpies exclusivament** |
| **Fitxar IN/OUT** | Sí | Sí | **Sí** |
| **Calendari propi** | Sí | No | **Sí** |
| **Historial** | Sí | No | **Sí** |
| **Sol·licitar absència** | Sí | No | V2 |
| **Mòbil-first** | Sí | Tablet/PC | **Sí (prioritat màxima)** |
| **Token revocable** | N/A (sessió) | Sí (device) | **Sí** |

---

## 18.3 Casos d'Ús

### Cas A — Fitxar des del mòbil personal (flux principal)
- Manager genera l'enllaç de l'empleat al tenant-portal.
- L'envia per WhatsApp. URL per defecte (plataforma):
  `https://{tenant-slug}.public.{platform-domain}/e/{uuid}`
- Si el tenant configura domini propi amb CNAME, també pot ser:
  `https://portal.empresa.com/e/{uuid}`
- Empleat obre l'enllaç, veu el botó gran d'entrada/sortida.
- Fitxa. El fitxatge arriba a `data.time_punches` amb `source='portal'`.
- Sense PIN: accés directe. Amb PIN: pantalla de 4 dígits primer.

### Cas B — Consultar el propi calendari laboral
- Empleat obre l'enllaç des del marcador del mòbil.
- Veu la setmana actual: torns assignats, festius i absències aprovades.
- Pot navegar entre setmanes/mesos.

### Cas C — Revisar l'historial de fitxatges del mes
- Empleat consulta el resum mensual: dates, hores treballades, anomalies.
- No pot editar res, només visualitzar.

### Cas D — QR imprès a l'empresa (estació lleugera)
- Manager imprimeix el QR personal de cada empleat.
- Enganxa'l al taulell o vestuari.
- Empleat escaneja amb el mòbil → fitxa IN/OUT instantàniament.
- Equivalent a l'estació fixa però sense hardware dedicat.

### Cas E — Empleat temporal o subcontractat
- Durada del token = durada del contracte (configurable).
- El token expira automàticament o es revoca en finalitzar.
- Sense baixa a `auth.users`, sense gestió de comptes.

---

## 18.4 Funcionalitats del Portal (V1 / V2)

| Funcionalitat | V1 | V2 |
|---|---|---|
| Fitxar IN/OUT (online) | ✅ | — |
| Fitxar offline (IndexedDB outbox) | ✅ | — |
| Calendari laboral mensual (torns, festius) | ✅ | — |
| Historial de fitxatges (últimes 4 setmanes) | ✅ | — |
| Estat del dia (dins/fora, hores acumulades) | ✅ | — |
| Resum mensual (hores totals, anomalies) | ✅ | — |
| Absències aprovades al calendari | ✅ | — |
| Notificació canvi de torn (push web) | — | ✅ |
| Sol·licitar absència des del portal | — | ✅ |
| Veure nòmina o rebuts (si DMS integrat) | — | ✅ |
| Missatgeria bàsica empleat-manager | — | ✅ |

---

## 18.5 Model de Token d'Accés

### Taula: `data.employee_portal_tokens`

```sql
CREATE TABLE data.employee_portal_tokens (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id     uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,

  -- Token d'accés únic (el que va a l'URL)
  access_token    uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),

  -- Seguretat opcional
  pin_hash        text,           -- bcrypt(PIN 4-6 dígits), NULL = sense PIN
  pin_attempts    smallint NOT NULL DEFAULT 0,
  pin_locked_until timestamptz,  -- bloqueig temporal si 3 intents fallits

  -- Validesa
  expires_at      timestamptz,   -- NULL = permanent
  is_active       boolean NOT NULL DEFAULT true,

  -- Distribució
  label           text,          -- ex: 'WhatsApp', 'QR vestuari', 'Email'
  last_accessed_at timestamptz,
  -- last_ip: usar access_logs (no duplicar)

  -- Auditoría
  created_by_user_id uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  revoked_at      timestamptz,
  revoke_reason   text,

  CONSTRAINT one_active_token_per_employee
    EXCLUDE USING btree (employee_id WITH =)
    WHERE (is_active = true AND revoked_at IS NULL AND expires_at IS NULL),

  INDEX idx_employee_portal_token (access_token),
  INDEX idx_employee_portal_employee (employee_id, is_active)
);
```

**Notes**:
- Un empleat pot tenir **múltiples tokens** (WhatsApp + QR imprès + email),
  però la restricció `EXCLUDE` impedeix tokens permanents duplicats actius.
- Si cal renovar un token (s'ha filtrat), es revoca l'antic i se'n genera un
  de nou. L'URL canvia; els QR impresos s'han de reimprimir.
- `pin_hash` és opcional. El manager decideix si vol afegir un PIN.

### Taula: `data.employee_portal_access_logs`

Per compliment legal i detecció d'anomalies:

```sql
CREATE TABLE data.employee_portal_access_logs (
  id              bigserial PRIMARY KEY,
  token_id        uuid NOT NULL REFERENCES data.employee_portal_tokens(id) ON DELETE CASCADE,
  employee_id     uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  tenant_id       uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,

  accessed_at     timestamptz NOT NULL DEFAULT now(),
  ip_address      inet,
  user_agent      text,

  action          text NOT NULL,
  -- 'view_schedule' | 'view_history' | 'punch_in' | 'punch_out'
  -- | 'pin_failed' | 'token_invalid' | 'token_expired'
  http_status     smallint,

  CONSTRAINT valid_action CHECK (action IN (
    'view_schedule','view_history','punch_in','punch_out',
    'pin_failed','token_invalid','token_expired'
  )),
  INDEX idx_epal_token (token_id, accessed_at),
  INDEX idx_epal_employee (employee_id, accessed_at)
);
```

---

## 18.6 Seguretat i Threat Model

### Amenaces i Mitigacions

| Risc | Probabilitat | Impacte | Mitigació |
|---|---|---|---|
| Compartir l'URL amb un company | Alta | Baixa (dades personals, no empresarials) | PIN opcional + auditoria IP |
| Token filtrat (ex: captura de pantalla) | Mitja | Mitja | Revocació ràpida, PIN actiu |
| Enumeració UUID (brute-force) | Baixa | Mitja | Rate limit 10 req/min per IP + UUID v4 |
| Fitxatge fraudulent en nom de l'empleat | Mitja | Alta | Geofencing configurable + auditoria IP |
| Accés post-revocació | Baixa | Alta | Validació `is_active + revoked_at` en cada request |
| PIN brute-force | Mitja | Alta | Bloqueig 15 min després de 3 intents fallits |

### Regles de seguretat (detall a pla executable)

1. **JWT 15 min** + `POST /session/refresh` consulta BD.
2. **Proxy Next.js obligatori** per cookies; mai fetch cross-origin a Supabase.
3. **Cookie sense `Domain` compartit** entre tenants.
4. **Rate limit:** `ep:ip:{tenant_id}:{ip}` + `ep:sess:{token_id}`.
5. **Secret a capa app**; `token_hash` a BD.
6. **Geofencing** a `POST /punch` (§18.10).
7. **Revocació offline:** `occurred_at < revoked_at` al servidor.
8. **`EmployeePortalRepository`** única capa `service_role`.


---

## 18.7 Edge Function: `employee-portal-api`

Una única Edge Function gestiona totes les operacions del portal. Autenticació
via `access_token` a la capçalera `X-Employee-Token` o com a paràmetre de ruta.
No usa `auth.uid()` — usa `service_role` amb filtre explícit per `employee_id`.

### Endpoints interns (routing per `action`)

```
POST /employee-portal-api
  Body: { action: string, token: string, payload?: object }
```

| `action` | Descripció | Retorna |
|---|---|---|
| `validate_token` | Comprova token + PIN. Retorna info bàsica de l'empleat. | `{ employee_id, full_name, site_id, pin_required }` |
| `get_schedule` | Torns, festius i absències del mes indicat. | Array d'events de calendari |
| `get_today_status` | Fitxatges d'avui + estat actual (dins/fora). | `{ status, punches[], hours_today }` |
| `get_history` | Entrades (`time_entries`) dels últims N dies. | Array de `time_entries` resumits |
| `punch` | Registra IN/OUT. Equivalent a `record_time_punch` amb `source='portal'`. | `{ status, punch_id, anomaly_codes? }` |

### Pseudocodi de `punch`

```typescript
async function handlePunch(token: string, payload: PunchPayload, ctx: EdgeCtx) {
  // 1. Lookup i validació del token
  const emp = await validateToken(token, ctx.db) // throws si invàlid
  
  // 2. Construir el payload per a record_time_punch
  const result = await ctx.db.rpc('record_time_punch', {
    p_employee_id:  emp.employee_id,
    p_client_op_id: payload.client_op_id,
    p_punch_type:   payload.direction,   // 'in' | 'out'
    p_occurred_at:  payload.occurred_at,
    p_source:       'portal',            // nou valor d'enum
    p_geo:          payload.geo ?? null,
  })
  
  // 3. Registrar a access_logs
  await logAccess(emp, payload.direction === 'in' ? 'punch_in' : 'punch_out', ctx)
  
  return result
}
```

**Important**: el `source='portal'` s'afegeix com a valor al tipus
`data.time_punch_source` en la migració d'aquest mòdul:

```sql
ALTER TYPE data.time_punch_source ADD VALUE IF NOT EXISTS 'portal';
```

---

## 18.8 Frontend — Integració al Public Portal

### Per què integrar-se al `public-portal` i no fer una app nova

| Criteri | App nova (`apps/employee-portal`) | Integrat a `public-portal` |
|---|---|---|
| Infraestructura | Nou deploy, nova URL, nou domini | Ja existent, ja desplegat |
| Manteniment | Dos repos/pipelines | Un sol lloc |
| Complexitat V1 | Alta (setup Next.js + CI/CD) | **Baixa** |
| Separació de concerns | Perfecta | Acceptable (ruta `/e/[token]`) |
| **Recomanació V1** | — | **✅ Integrat** |

L'app nova es pot extreure en el futur si creix, però per V1 la integració és
la decisió pragmàtica.

### Estructura de rutes dins de `apps/public-portal`

```
app/
└── e/
    └── [token]/
        ├── layout.tsx        # Layout mínim: logo tenant, res més
        ├── page.tsx          # Guard: valida token → redirect a /punch o /schedule
        ├── punch/
        │   └── page.tsx      # PunchPage: botó gran IN/OUT + timeline avui
        ├── schedule/
        │   └── page.tsx      # SchedulePage: calendari mensual (torns, festius)
        └── history/
            └── page.tsx      # HistoryPage: llista time_entries últimes setmanes
```

### Model de domini i host (correcció important)

Per V1, l'Employee Portal reutilitza exactament la capa de domini del
Public Portal (doc 11-12):

1. **Per defecte (recomanat)**: subdomini de plataforma amb wildcard DNS
  `*.public.{platform-domain}`.
  Ex: `https://acme.public.cavalle.app/e/{token}`

2. **Opcional per tenant**: domini/subdomini propi del tenant apuntant amb
  CNAME cap a la plataforma.
  Ex: `https://portal.acme.com/e/{token}`

3. **No requerit**: no cal que cada tenant tingui ni transfereixi un
  domini propi per usar l'Employee Portal.

4. **Conclusió**: la forma `portal.{tenant}.com` no s'ha d'entendre com a
  requisit. És només un exemple de domini propi opcional si el tenant el
  configura explícitament.

### Components nous (reutilitzant del tenant-portal on és possible)

| Component | Descripció | Origen |
|---|---|---|
| `PinGate.tsx` | Pantalla PIN (4-6 dígits) si token requereix PIN | Nou |
| `EmployeePunchButton.tsx` | Botó IN/OUT adaptat al portal (sense Supabase auth) | Adaptat de `PunchButton` |
| `EmployeeCalendar.tsx` | Vista mensual de torns + festius + absències | Adaptat de `MyCalendarPage` |
| `EmployeeTimeline.tsx` | Timeline del dia actual | Adaptat de `DailyTimeline` |
| `EmployeeHistory.tsx` | Taula de time_entries setmanals/mensuals | Adaptat de `MyRecordPage` |
| `TokenExpired.tsx` | Pantalla d'error si token invàlid/revocat | Nou |

### UX Key Points

1. **Mòbil-first obligatori**: layout d'una columna, botons grans (mín. 48px touch target).
2. **Botó de fitxatge**: centrat, prominent, mostra l'estat actual (dins/fora) amb color verd/vermell.
3. **Sense navbar de tenant**: layout net, barra superior mínima amb nom de l'empleat.
4. **Offline-first per al fitxatge**: IndexedDB outbox igual que al tenant-portal. Si es perd la connexió, el fitxatge es desa i es sincronitza quan torna.
5. **PIN screen**: teclat numèric gran, accessible, sense teclat virtual del sistema (custom keypad).
6. **QR share button**: botó per descarregar el QR personal des de la mateixa pàgina.
7. **Countdown si expirable**: "Accés expira en X dies".
8. **robots.txt**: `Disallow: /e/` — mai indexat.

### Distribució del Token (des del Tenant Portal)

El manager genera i distribueix el token des del tenant-portal:

```
Tenant Portal → Empleat > Detall > Tab "Accés Portal"
  ├── [Generar nou token]        → crea data.employee_portal_tokens
  ├── [Copiar enllaç]            → URL completa
  ├── [Descarregar QR]           → QR de l'URL per imprimir
  ├── [Enviar per WhatsApp]      → deep link wa.me amb el missatge
  ├── [Revocar]                  → revoked_at = now()
  └── Historial d'accessos       → taula employee_portal_access_logs
```

---

## 18.9 Offline-First al Portal

El portal ha de poder fitxar **sense connexió** (zones amb mala cobertura,
soterranis, etc.). La mateixa arquitectura de l'`attendanceDb` (Dexie +
IndexedDB) s'ha de reutilitzar en el context del portal:

```
Empleat prem IN/OUT
  │
  ├─ Desa localment a IndexedDB (outbox)
  │   { client_op_id, direction, occurred_at, token, ... }
  │
  └─ Intenta sincronitzar via edge function `employee-portal-api`
      ├─ Connexió ok → `punch` → marca `synced`
      └─ Sense connexió → retry en tornar online / interval 30s
```

**Diferència vs tenant-portal**: al portal no hi ha `auth.uid()` ni `userId`
a l'outbox; s'identifica exclusivament pel `access_token`.

---

## 18.10 Integració amb el Mòdul d'Assistència

El portal **no crea una infraestructura paral·lela**. Reutilitza tot el que
ja existeix:

| Dada | Font | RPC/Vista |
|---|---|---|
| Torns assignats | `data.shift_slots` | `api.get_my_shift_slots(employee_id, from, to)` |
| Festius | `data.holidays` via `holiday_calendars` | `api.get_site_holidays(site_id, from, to)` |
| Absències | `data.employee_absences` | Filtre per `employee_id` |
| Fitxatges d'avui | `data.time_punches` | `api.my_attendance_today(employee_id)` |
| Historial entrades | `data.time_entries` | Filtre per `employee_id + dates` |
| Registrar fitxatge | `api.record_time_punch(...)` | `source = 'portal'` |

L'Edge Function usa `createAdminClient()` (service_role) i filtra
**explícitament per `employee_id`** recuperat del token. Mai exposa dades
d'altres empleats.

---

## 18.11 Auditoria

Seguint el protocol del projecte, cada acció rellevant es registra:

| Acció | Registre |
|---|---|
| Token generat | `data.audit_logs` (`EMPLOYEE_PORTAL_TOKEN_CREATED`) |
| Token revocat | `data.audit_logs` (`EMPLOYEE_PORTAL_TOKEN_REVOKED`) |
| Fitxatge via portal | `data.time_punches` (amb `source='portal'`) + `employee_portal_access_logs` |
| PIN incorrecte (>3) | `employee_portal_access_logs` (`pin_failed`) + notificació in-app al manager |
| Token expirat intentant accedir | `employee_portal_access_logs` (`token_expired`) |

---

## 18.12 Fases de Rollout

### Fase A — Backend Base *(~2 dies)*
- Migració SQL: `employee_portal_tokens` + `employee_portal_access_logs`
- `ALTER TYPE data.time_punch_source ADD VALUE 'portal'`
- Edge Function `employee-portal-api` (accions: `validate_token`, `get_today_status`, `punch`)
- Auditoria trigger `EMPLOYEE_PORTAL_TOKEN_CREATED` / `_REVOKED`

Estimació: **2 dies**

### Fase B — Portal Frontend V1 *(~3 dies)*
- Rutes `/e/[token]` al `public-portal`
- `PinGate`, `EmployeePunchButton`, `EmployeeTimeline`
- Offline-first: IndexedDB outbox + drainer
- `robots.txt` actualitzat

Estimació: **3 dies**

### Fase C — Calendari i Historial *(~2 dies)*
- `EmployeeCalendar` (torns, festius, absències)
- `EmployeeHistory` (time_entries últimes 4 setmanes)
- Acció `get_schedule` + `get_history` a l'Edge Function

Estimació: **2 dies**

### Fase D — Gestió de Tokens al Tenant Portal *(~2 dies)*
- Tab "Accés Portal" a la pàgina de detall d'empleat
- Generar / revocar / copiar / QR / WhatsApp
- Taula d'historial d'accessos (IP, hora, acció)
- PIN opcional per a cada token

Estimació: **2 dies**

### Fase E — V2: Sol·licitud d'Absència i Notificacions ✅

- Formulari de sol·licitud d'absència des del portal
- **Web Push** (no FCM) per canvis de torn — veure [`docs/help/employee-portal/notificacions-push.md`](../help/employee-portal/notificacions-push.md)
- Múltiples tokens per empleat amb labels (EP3+)

---

## 18.13 Configuració per Tenant

Taula al `settings_registry` (o nova taula de configuració del portal d'empleats):

```sql
-- Claus afegides a data.settings_registry:
-- 'employee_portal.enabled'           boolean, default: true
-- 'employee_portal.default_pin_required' boolean, default: true
-- 'employee_portal.token_expiry_days' integer, default: null (permanent)
-- 'employee_portal.geofencing_mode'   text,    default: heretat del tenant
-- 'employee_portal.ip_change_notify'  boolean, default: true
```

---

## 18.14 Decisions Adoptades

| # | Decisió | Justificació |
|---|---|---|
| 1 | JWT 15 min + refresh amb consulta BD | Revocació al refresh |
| 2 | Proxy Next.js obligatori | Cookie SameSite=Lax |
| 3 | `token_hash` a BD; secret a capa app | Mai a PostgreSQL |
| 4 | Cookie sense Domain compartit | Multi-tenant |
| 5 | PIN recomanat + avís si off | Fitxatge legal |
| 6 | EP8 L1 ≠ L2 (DMS) | Nivells legals separats |
| 7 | Logs particionats, TTL 90 dies | Escala |

## 18.15 Decisions tancades

1. Refresh valida revocació a BD; emergència (`p_compromised`) immediata.
2. EP8 L1 confirmació lectura; L2 via DMS existent.
3. Pla executable: [`plan-employee-portal.md`](../plans/checkin/plan-employee-portal.md).
