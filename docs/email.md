# Sistema d'email — Documentació tècnica

## Visió general

El sistema d'email gestiona l'enviament de correus electrònics per a cada tenant de forma aïllada i configurable. Utilitza una cua PostgreSQL (`pgmq`) per desacoblar la ingesta dels enviaments, i un Edge Function Worker (Resend) per al processament asíncron.

```
Aplicació / RPC
      │
      ▼
api.enqueue_email()          ← validació · resolució remitent · resolució plantilla · resolució layout
      │
      ▼
pgmq (cua)                   ← emmagatzematge persistent + delay si scheduled_at
      │
      ▼
Edge Function: process-email-queue   ← Worker periòdic (pg_cron / invocació externa)
      │  1. rate-limit check
      │  2. fetch email_log
      │  3. markProcessing
      │  4b. renderitzar plantilla  {{variables}}
      │  4c. embolcallar amb layout {{content}} + layout_variables
      │  5. enviar via Resend
      │  6. markSent / markFailed
      ▼
Resend API                   ← enviament real + Idempotency-Key
      │
      ▼ (temps real, via webhook)
Edge Function: resend-webhook        ← verifica signatura Svix → process_email_webhook()
      │                                 email.delivered  → delivered
      │                                 email.bounced    → bounced
      │                                 email.complained → complained
      │
      ▼
api.process_email_webhook()  ← actualitzar estat de lliurament
```

---

## Migracions

Tot el core del sistema d'email resideix al fitxer consolidat:

| Fitxer | Contingut |
|---|---|
| `20260415000002_email_system_core.sql` | ENUMs, taules, triggers (transicions d'estat), RLS, vistes API, `enqueue_email()`, `process_email_webhook()`, `pop_email_messages()`, `archive_email_message()` |

> **Nota:** les migracions addacionals (templates/events/layouts) estenen el core però no alteren les taules principals d'estat.

---

## Cicle de Vida d'Estat i Webhooks

### Màquina d'estats

```
queued ──► processing ──► sent ──► delivered  (terminal)
                 │          └──► bounced     (terminal)
                 │          └──► complained  (terminal — queixa spam)
                 │          └──► suppressed  (terminal — adreça suprimida)
                 └──► failed ──► queued      (retry, si attempt_count < max_retries)
                        └──► failed (dead_letter = true si exhaurits els reintents)
```

**Estats terminals:** `delivered`, `bounced`, `complained`, `suppressed`, i `failed` amb `is_dead_letter = true`. El trigger `enforce_email_status_transition` a la BD rebutja qualsevol transició no vàlida.

### Font d'actualitzacions d'estat

El sistema **no fa polling periòdic** a Resend per saber si un correu ha estat lliurat. En comptes, depèn exclusivament de l'Edge Function `resend-webhook` per rebre actualitzacions en temps real:

| Font | Mètode | Estats que actualitza |
|---|---|---|
| Worker `process-email-queue` | Direct (Resend API response) | `queued → processing → sent \| failed` |
| Edge Function `resend-webhook` | Webhook Resend → `process_email_webhook()` | `sent → delivered \| bounced \| complained` |
| Admin (manual sync) | `syncResendStatus()` a l'Admin-Portal | Qualsevol estat, com a eina de debug |

### Edge Function `resend-webhook`

**URL:** `https://<project-ref>.supabase.co/functions/v1/resend-webhook`

**Seguretat — verificació Svix (HMAC-SHA256):**

Resend utilitza la biblioteca Svix per signar cada webhook. Per cada petició, la funció:

1. Llegeix els headers `svix-id`, `svix-timestamp`, `svix-signature`.
2. Verifica que el timestamp estigui dins del rang ±5 minuts (anti-replay).
3. Calcula `HMAC-SHA256(secret, "{svix-id}.{svix-timestamp}.{raw-body}")` i el compara amb la signatura rebuda en temps constant.
4. Rebutja amb `401` si la signatura no coincideix.

**Mapping d'events:**

| Event Resend | Estat intern |
|---|---|
| `email.delivered` | `delivered` |
| `email.bounced` | `bounced` |
| `email.complained` | `complained` |
| `email.delivery_delayed` | `processing` (best-effort; pot fallar si l'estat actual no ho permet) |
| Altres (`email.opened`, `email.clicked`, etc.) | Ignorat (ack 200, no processed) |

**Resposta:** sempre `200 OK` per evitar reintents de Resend, tret dels casos de condició de carrera (vegeu més avall).

**Maneig de Condicions de Carrera (Race Conditions):**

Si Resend envia un webhook (ex: `email.delivered`) abans que el Worker hagi fet el COMMIT de l'`INSERT` a `email_logs` — és a dir, el `provider_message_id` encara no existeix a la BD — la funció retorna deliberadament un **404**. Resend interpreta el 404 com un error recuperable i programa un reintent amb backoff exponencial, donant temps al Worker a finalitzar la transacció. Un cop el `provider_message_id` és visible a la BD, el reintent del webhook processarà correctament l'actualització d'estat.

Per a la resta d'errors d'RPC (ex: transicions d'estat invàlides), la funció continua retornant `200 OK` per evitar bucles de reintents sobre errors inrecuperables.

---

## Taules de dades (`schema: data`)

### `data.email_configs`

Configuració general d'email per tenant. **Una fila per tenant**, creada automàticament a l'onboarding.

| Columna | Tipus | Descripció |
|---|---|---|
| `tenant_id` | uuid PK | |
| `default_provider` | `email_provider` | `resend` (default) |
| `default_from_name` | text | Nom del remitent fallback de l'account |
| `default_reply_to` | text | Reply-To fallback de l'account |
| `default_layout_id` | uuid FK | Layout per defecte aplicat a totes les plantilles del tenant |
| `layout_variables` | jsonb | Variables estàtiques del tenant per a layouts (`logo_url`, `footer_text`, etc.) |
| `rate_limit_per_hour` | int | Màx. correus/hora (usat pel Worker per throttling) |
| `rate_limit_per_day` | int | Màx. correus/dia |
| `max_retries` | int | Reintents màxims en error (default 3) |
| `retention_days` | int | Dies de retenció de logs (default 90) |
| `metadata` | jsonb | Perfils de remitent per departament (`sender_profiles[]`) |

> **Sender Profiles (departaments):** `email_configs.metadata` pot contenir una clau `sender_profiles` amb un array de perfils de remitent per departament (ex: `vendes`, `suport`, `facturacio`). Cada perfil té `from_email`, `from_name` i `reply_to` propis. La funció `enqueue_email()` pot resoldre el remitent a partir d'un camp `sender_profile` al payload, permetent que cada departament enviï amb la seva pròpia identitat sense necessitat de múltiples dominis.

> `default_from_email` no existeix. L'adreça remitent es resol sempre des d'un domini verificat o del domini de plataforma.

---

### `data.email_domains`

Dominis verificats per tenant. Múltiples per tenant, un de `is_primary`.

| Columna | Tipus | Descripció |
|---|---|---|
| `id` | uuid PK | |
| `tenant_id` | uuid | |
| `domain` | text | Ex: `empresa.cat` |
| `verification_status` | `domain_verification_status` | `pending` / `verified` / `failed` |
| `dns_records` | jsonb | Registres TXT/CNAME per verificar |
| `verified_at` | timestamptz | |
| `is_primary` | boolean | Domini principal (únic per tenant via índex parcial) |
| `default_from_email` | text | Ex: `noreply@empresa.cat` |
| `default_from_name` | text | Nom remitent específic d'aquest domini |
| `default_reply_to` | text | Reply-To específic d'aquest domini |

---

### `data.email_templates`

Plantilles de contingut i layouts per tenant i per plataforma.

| Columna | Tipus | Descripció |
|---|---|---|
| `id` | uuid PK | |
| `tenant_id` | uuid **nullable** | NULL = plantilla de plataforma |
| `name` | text | Nom intern descriptiu |
| `slug` | text | Referència per API (ex: `welcome-email`) |
| `event_type` | text | Event que dispara la plantilla (ex: `user.welcome`) |
| `subject_template` | text | Assumpte amb `{{variables}}` |
| `html_body_template` | text | Cos HTML amb `{{variables}}` |
| `text_body_template` | text | Cos text pla amb `{{variables}}` |
| `variables_schema` | jsonb | Catàleg de variables (`{"name": "string"}`) |
| `is_layout` | boolean | Plantilla de layout/wrapper (usa `{{content}}`) |
| `layout_id` | uuid FK → email_templates | Layout específic per a aquesta plantilla |
| `use_layout` | boolean | Embolcallar amb layout? (default `true`) |
| `is_platform_default` | boolean | Visible com a fallback per tots els tenants |
| `is_active` | boolean | |

**Constraint bàsic:**
```sql
CHECK (tenant_id IS NOT NULL OR is_platform_default = true)
```
Cada plantilla o pertany a un tenant o és una plantilla de plataforma (o ambdues coses a la vegada no és possible per la unicitat dels índexs).

**Índexs únics:**
```
UNIQUE (tenant_id, slug)      WHERE tenant_id IS NOT NULL
UNIQUE (slug)                 WHERE is_platform_default = true
UNIQUE (tenant_id, event_type) WHERE event_type IS NOT NULL AND tenant_id IS NOT NULL
                                AND is_layout = false AND is_active = true
UNIQUE (event_type)            WHERE is_platform_default = true
                                AND is_layout = false AND is_active = true
```

---

### `data.email_logs`

Registre complet del cicle de vida de cada correu. El Worker actualitza l'estat; el frontend només pot fer SELECT.

| Columna | Tipus | Descripció |
|---|---|---|
| `id` | uuid PK | |
| `tenant_id` | uuid | |
| `idempotency_key` | text UNIQUE per tenant | Impedeix duplicats |
| `status` | `email_status` | `queued` → `processing` → `sent` / `failed` / `bounced` / `delivered` |
| `email_type` | `email_type` | `transactional` / `bulk` |
| `priority` | int | `0` = normal; valors més alts = prioritat major |
| `from_email` | text | Resolt per `enqueue_email()` |
| `from_name` | text | |
| `to_emails` | text[] | |
| `cc_emails` | text[] | |
| `bcc_emails` | text[] | |
| `reply_to` | text | |
| `template_id` | uuid FK | Plantilla usada (resolta abans de la inserció) |
| `template_variables` | jsonb | Variables per renderitzar el template |
| `layout_id` | uuid FK | Layout a aplicar (resolt per `enqueue_email()`) |
| `subject` | text | Assumpte inline o resolució posterior |
| `html_body` | text | Cos inline (buit si és template-based) |
| `text_body` | text | |
| `attachments` | jsonb | `[{"filename": "...", "storage_path": "..."}]` |
| `provider_message_id` | text | ID retornat per Resend/Sendgrid |
| `attempt_count` | int | Nombre de reintents fins ara |
| `max_retries` | int | |
| `is_dead_letter` | boolean | Superat `max_retries` |
| `last_error` | text | |
| `error_history` | jsonb | Historial de tots els errors |
| `scheduled_at` | timestamptz | NULL = enviar immediatament |
| `sent_at` | timestamptz | |
| `delivered_at` | timestamptz | |

---

## Observabilitat (Admin-Portal)

L'Admin-Portal inclou un panell de monitorització complet a `/admin/email-logs`:

| Secció | Descripció |
|---|---|
| **Historial de logs** | Taula paginada amb filtres per tenant, site, estat i cerca per destinatari/assumpte/ID. Exportació CSV. |
| **Detall del log** | Modal amb totes les dades del correu, temps de procés i lliurament, i eina de sincronització manual amb Resend. |
| **Queue Monitor** | Estat en temps real de la cua `pgmq`: missatges pendents, latència màxima, volum processat (arxiu). Inclou taula de missatges actius amb tenant i link al log. |
| **Gràfiques d'anàlisi** | Evolució diària d'enviaments (barres apilades), taxa d'èxit (donut), latència mitjana de procés (línies), top issues per tenant/site. |

---

## Resolució del remitent

La funció `api.enqueue_email()` determina `from_email`, `from_name` i `reply_to` seguint una cascada:

### Branca A — `from_email` absent al payload

```
Té domini primary verificat?
├── NO  → Plataforma:
│         from_email = platform_default_from_email || 'noreply@<platform_domain>'
│         from_name  = payload → config.default_from_name → platform_default_from_name
│         reply_to   = payload → config.default_reply_to
└── SÍ  → Domini primary:
          from_email = domain.default_from_email || 'noreply@<domain>'
          from_name  = payload → domain.default_from_name → config.default_from_name → platform
          reply_to   = payload → domain.default_reply_to → config.default_reply_to
```

### Branca B — `from_email` present al payload

```
El domini del from_email és verificat?
├── NO  → Plataforma (sobreescriu from_email):
│         from_email = platform_default_from_email || 'noreply@<platform_domain>'
│         from_name  = payload → config.default_from_name → platform_default_from_name
│         reply_to   = payload → config.default_reply_to
└── SÍ  → Domini verificat:
          from_email = payload (mantenir)
          from_name  = payload → domain.default_from_name → config.default_from_name → platform
          reply_to   = payload → domain.default_reply_to → config.default_reply_to
```

### Configuració de plataforma (`data.system_settings WHERE module = 'email'`)

```jsonc
{
  "platform_default_domain": "example.app",
  "platform_default_from_email": "noreply@example.app",
  "platform_default_from_name": "Example"
}
```

---

## Sistema de plantilles

### Resolució de la plantilla — ordre de prioritat

Quan es crida `api.enqueue_email()`, la plantilla es resol en aquest ordre. El primer que trobi guanya:

```
1. event_type  → plantilla activa del tenant  (is_layout=false, is_active=true)
                 si no → plantilla de plataforma amb el mateix event_type

2. template_slug → plantilla activa del tenant
                   si no → plantilla de plataforma amb el mateix slug

3. template_id (UUID) → directe (tenant o plataforma)
                        ERROR si no és accessible

4. Inline → subject + html_body/text_body al payload directament
            REQUEREIX "subject" obligatòriament
```

> Si no es troba plantilla i no hi ha `subject`, la funció llança una excepció.

#### Exemple de payload per event_type

```jsonc
{
  "tenant_id": "...",
  "idempotency_key": "welcome-user-42",
  "to": ["nou@empresa.cat"],
  "event_type": "user.welcome",
  "template_variables": { "name": "Anna", "link": "https://..." }
}
```

#### Exemple de payload per slug

```jsonc
{
  "tenant_id": "...",
  "idempotency_key": "inv-001-send",
  "to": ["client@gmail.com"],
  "template_slug": "invoice-sent",
  "template_variables": { "invoice_number": "F-001", "amount": "120,00 €" }
}
```

### Plantilles de plataforma (`is_platform_default = true`)

- Pertanyen a la plataforma (`tenant_id = NULL`).
- Actuen com a fallback si el tenant no té cap plantilla per a un `event_type` o `slug` determinat.
- Visibles (SELECT) per tots els usuaris autenticats via RLS.
- Gestionades pels administradors de la plataforma (no pels tenants).

**Casos d'ús:**
- Correus del sistema enviats abans que el tenant tingui cap plantilla pròpia (benvinguda, verificació d'email, reset de contrasenya…).
- Assegurar que sempre hi ha una plantilla per als events del sistema.

---

## Sistema de layouts

Un **layout** és una plantilla que embolcalla el contingut HTML d'altres plantilles. Conté la capçalera, el peu de pàgina i l'estil de la companyia, i usa `{{content}}` per injectar l'HTML intern.

### Estructura d'un layout

```html
<!DOCTYPE html>
<html>
<head><style>/* estilos corporativos */</style></head>
<body>
  <header>
    <img src="{{logo_url}}" alt="{{company_name}}">
  </header>
  <main>
    {{content}}
  </main>
  <footer>
    <p>{{footer_text}}</p>
  </footer>
</body>
</html>
```

### Resolució del layout en `enqueue_email()`

```
La plantilla té use_layout = true?
├── NO  → email sense layout
└── SÍ  → v_layout_id = COALESCE(
              template.layout_id,             ← layout específic de la plantilla
              email_configs.default_layout_id  ← layout per defecte del tenant
            )
           NULL → email sense layout (cap configurat)
```

El `layout_id` resolt es desa a `email_logs.layout_id` i el Worker l'aplica a l'hora d'enviar.

> **Nota:** les emails inline (sense plantilla) no reben mai cap layout.

### Renderització del layout al Worker

El Worker aplica el layout **després** de renderitzar la plantilla de contingut. L'ordre de fusió de variables és:

```
email_configs.layout_variables   ← variables estàtiques del tenant (prioritat més baixa)
     +
template_variables del log        ← variables de la crida concreta (sobreescriuen les estàtiques)
     +
{ content: "<html intern>" }      ← SEMPRE al final (no sobreescribible per l'usuari)
```

Això permet que un tenant defineixi `logo_url` o `footer_text` una sola vegada a `email_configs.layout_variables` i automàticament apareguin a tots els correus, sense haver-los de passar a cada crida.

#### Exemple de `layout_variables` a `email_configs`

```jsonc
{
  "logo_url": "https://cdn.empresa.cat/logo.png",
  "company_name": "Empresa Cat SL",
  "footer_text": "© 2026 Empresa Cat SL · Política de privacitat"
}
```

#### Exemple de plantilla que sobreescriu una variable estàtica

```jsonc
{
  "to": ["client@example.com"],
  "event_type": "invoice.sent",
  "template_variables": {
    "invoice_number": "F-001",
    "footer_text": "Factura generada automàticament."
  }
}
```

Aquí `footer_text` sobreescriu el valor estàtic del tenant per a aquest correu concret.

---

## Funcions RPC (`schema: api`)

### `api.enqueue_email(payload jsonb) → uuid`

Enqüea un correu i retorna l'`id` del log creat.

**Camps del payload:**

| Camp | Requerit | Descripció |
|---|---|---|
| `tenant_id` | ✅ | UUID del tenant |
| `idempotency_key` | ✅ | String únic per evitar duplicats |
| `to` | ✅ | Array de destinataris |
| `event_type` | ⬜ | Event per cercar plantilla |
| `template_slug` | ⬜ | Slug per cercar plantilla |
| `template_id` | ⬜ | UUID directe de la plantilla |
| `template_variables` | ⬜ | Variables per renderitzar la plantilla |
| `subject` | ⬜* | Assumpte (obligatori si no hi ha plantilla) |
| `html_body` | ⬜ | Cos HTML inline (sense plantilla) |
| `text_body` | ⬜ | Cos text pla inline |
| `from_email` | ⬜ | Ometre per usar el domini primary del tenant |
| `from_name` | ⬜ | Sobreescriu el default del tenant |
| `reply_to` | ⬜ | Sobreescriu el default del tenant |
| `cc` | ⬜ | Array de còpies |
| `bcc` | ⬜ | Array de còpies ocultes |
| `email_type` | ⬜ | `"transactional"` (default) o `"bulk"` |
| `priority` | ⬜ | Enter, default `0` |
| `scheduled_at` | ⬜ | ISO 8601, per envio diferit |
| `tags` | ⬜ | Array de strings per segmentar |
| `metadata` | ⬜ | Jsonb amb dades addicionals |
| `attachments` | ⬜ | Array `[{"filename":"...", "storage_path":"..."}]` |

**Errors possibles:**
- `tenant_id es obligatori`
- `idempotency_key es obligatori`
- `cal indicar almenys un destinatari a "to"`
- `No tens acces al tenant <id>`
- `El rol "viewer" no pot enviar emails`
- `El tenant no te dominis verificats i no hi ha domini de plataforma configurat…`
- `El domini "<dom>" no esta verificat per al tenant…`
- `Plantilla <id> no trobada o no accessible per al tenant <id>`
- `Cal indicar "event_type", "template_slug", "template_id" o "subject" (contingut directe)`

---

## Worker Edge Function (`process-email-queue`)

### Sistema de Doble Motor

A producció i staging, la funció s'activa per **dos mecanismes complementaris**:

| Motor | Mecanisme | Latència | Propòsit |
|---|---|---|---|
| **Instantani** | `pg_net` trigger | < 1 s | Processa el missatge just després de l'`INSERT` a `pgmq` |
| **Escombrada** | `pg_cron` cada 2 min | ≤ 2 min | Recupera missatges fallits, rate-limited o endarrerits |

**Motor instantani (`pg_net`):** Un trigger de base de dades crida `pg_net.http_post()` just després de cada inserció a `pgmq.q_email_send_queue`. Això envia una petició HTTP a l'Edge Function de forma asíncrona, sense bloquejar la transacció original.

**Motor d'escombrada (`pg_cron`):** Programat cada 2 minuts com a xarxa de seguretat. Processa qualsevol missatge que el trigger instantani no hagi pogut atendre (instàncies fredes, errors transitoris de `pg_net`, missatges en retry, etc.).

> **Nota de desplegament — `verify_jwt = false` obligatori:**
> Tant `process-email-queue` com `resend-webhook` han de tenir `verify_jwt = false` a `supabase/config.toml`.
> - `process-email-queue`: l'invoca `pg_net` (sense JWT d'usuari) i opera amb la `service_role_key`.
> - `resend-webhook`: l'invoca Resend des d'internet; l'autenticació es fa via verificació HMAC-SHA256 de la signatura Svix, no via JWT.
>
> ```toml
> [functions.process-email-queue]
> verify_jwt = false
>
> [functions.resend-webhook]
> verify_jwt = false
> ```

### Lògica de processament

Quan s'invoca (per qualsevol dels dos motors), la funció processa missatges de `pgmq` en lots:

1. Adquireix un lock de singleton (Redis/Upstash) per evitar concurrència entre instàncies.
2. Llegeix un batch de missatges de `pgmq` amb `api.pop_email_messages()`.
3. Per cada missatge:
   - **Rate-limit check** (Redis counters per tenant).
   - **Fetch** del `email_log` (via `api.worker_email_logs`).
   - **Guard**: si l'estat no és `queued`, s'arxiva i es salta.
   - **markProcessing**: `queued → processing`.
   - **Renderitza plantilla** (si `template_id` present): substitueix `{{variable}}` al subject, html i text.
   - **Renderitza layout** (si `layout_id` present i `html_body` no és NULL): embolcalla l'HTML intern, fusionant `layout_variables` + `template_variables` + `{content}`.
   - **Envia via Resend** (amb `Idempotency-Key`).
   - **markSent** o **markFailed** + retry/dead-letter logic.
   - **Arxiva** el missatge de la cua.

---

## Vistes API (`schema: api`)

| Vista | Accés | Descripció |
|---|---|---|
| `api.email_configs` | authenticated | Configuració del tenant autenticat |
| `api.email_domains` | authenticated | Dominis del tenant (inclou `is_primary`, `default_from_*`) |
| `api.email_templates` | authenticated + service_role (SELECT) | Plantilles del tenant + plataforma |
| `api.email_logs` | authenticated | Historial dels últims `retention_days` dies |
| `api.worker_email_logs` | service_role exclusiu | Vista pel Worker sense restriccions RLS |

---

## Flux de configuració recomanat per a un tenant nou

1. **Onboarding** (`public-onboarding`): inserció automàtica a `email_configs`.
2. **Domini**: l'usuari afegeix un domini → el sistema genera els registres DNS.
3. **Verificació DNS**: l'Edge Function comprova el domini → `verification_status = 'verified'`.
4. **Domain primary**: l'usuari marca el domini com a principal.
5. **Defaults del domini**: configura `default_from_email`, `default_from_name`, `default_reply_to`.
6. **Layout** (opcional): crea o selecciona un layout, el configura com a `default_layout_id` a `email_configs`, i defineix `layout_variables` (logo, peu de pàgina...).
7. **Plantilles** (opcional): crea plantilles de contingut amb `event_type` per als events del sistema.
8. **Enviar**: `api.enqueue_email()` ja funciona amb domini verificat, plantilla i layout.

---

## Tipus ENUM

| Tipus | Valors |
|---|---|
| `data.email_status` | `queued`, `processing`, `sent`, `delivered`, `bounced`, `failed`, `complained`, `suppressed` |
| `data.email_type` | `transactional`, `bulk` |
| `data.email_provider` | `resend`, `sendgrid` |
| `data.domain_verification_status` | `pending`, `verified`, `failed` |
