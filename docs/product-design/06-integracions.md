# 6. Integracions externes

> Aquesta capa és la que **multiplica el valor del producte sense escriure
> codi de negoci**. Una bona integració amb un calendari extern val per
> 10 features pròpies. Per això la tractem com a primera classe i amb un
> patró uniforme.

## 6.1 Principis

1. **Cada integració = un addon** (Hub & Spoke).
2. **Activació en 1-clic** des del tenant-portal (OAuth quan és possible,
   API key quan no).
3. **Configuració emmagatzemada xifrada** (`pgsodium` o equivalent) a
   `data.tenant_integrations`. Mai en clar a `metadata`.
4. **Auditoria sempre**: connexió, desconnexió, errors d'autenticació,
   webhooks rebuts → `data.audit_logs` i/o `data.communications`.
5. Cada integració té un **health check** visible al tenant (badge
   verd/vermell + última sync).
6. **Failure modes coneguts**: cap integració pot caure el sistema. Si
   Resend cau, els emails van a la cua i s'envien quan torni.
7. **Costos transparents**: si la integració té cost variable
   (WhatsApp, SMS, IA), es comptabilitza a `usage_metrics` i és visible
   al tenant.
8. **Reversible**: desconnectar no esborra les dades sincronitzades, només
   atura la sync.

## 6.2 Catàleg prioritzat

> Els \"sectors\" de la columna fan referència als **arquetips**
> (`field_service`, `practice`, `hospitality`, `lodging`, `workshop_maker`,
> `appointment_walkin`) definits a [03-sector-profiles.md](03-sector-profiles.md).

### Tier 1 — Imprescindibles (Fase A-B-C)

| Integració | Què aporta | Arquetips beneficiats | Estat |
|---|---|---|---|
| **Resend** | Email transaccional + BYOS (ja implementat) | Tots | ✅ |
| **Cloudflare R2 / S3** | Storage extern (DMS) | Tots | ✅ |
| **WhatsApp Business Cloud API** (via BSP) | Recordatoris, confirmacions, atenció ràpida | Tots, especialment `practice` i `lodging` | 🔴 alta |
| **Twilio (SMS)** o equivalent | Fallback recordatoris quan no WhatsApp | Tots | 🔴 alta |
| **Stripe (subscripcions)** | Facturació del SaaS al tenant | Intern | 🔴 alta |

### Tier 2 — Diferenciadors (Fase D-E)

| Integració | Què aporta | Arquetips beneficiats |
|---|---|---|
| **Google Calendar / Microsoft 365 Calendar** | Sync bidireccional agenda | `field_service`, `practice`, `appointment_walkin` |
| **Google / Apple Maps deep-links + rutes optimitzades** | Planificació de visites | `field_service`, `workshop_maker` (camp) |
| **OpenAI / Anthropic** (via gateway) | Redacció, classificació, resum 360°, suggeriments | Tots |
| **OpenAI Whisper** (via gateway) | Notes per veu → text | Tots, fort a `field_service` i `practice` |
| **Mindee / AWS Textract / Google DocAI** | OCR factures, tickets, targetes de visita | Tots |
| **Signaturit / Docusign / Validated ID** | Signatura electrònica (consentiments, contractes, pressupostos) | `practice`, RRHH, `workshop_maker` |
| **Holded / Quipu / Sage / FacturaDirecta** | Exportació facturació/comptabilitat | Tots |
| **Verifactu / TicketBAI / SII** | Compliment fiscal ES (factura electrònica obligatòria) | Tots (regulatori) |
| **Stripe Connect / Redsys / Bizum** | Cobrament al final-client (link de pagament) | Tots, especialment `practice` i `field_service` |
| **Google reCAPTCHA / hCaptcha** | Anti-spam a formularis públics (onboarding, reserves) | Tots |

### Tier 3 — Sectorials i de cua llarga (només si demanda real)

| Integració | Arquetip on aporta valor |
|---|---|
| **TheFork / CoverManager / OpenTable** | `hospitality` (reserves externes) |
| **Glovo / UberEats / JustEat webhooks** | `hospitality` (delivery) |
| **Booking.com / Airbnb / Expedia** (channel manager via Hostaway, Lodgify, Smoobu) | `lodging` |
| **Google Business Profile** | Tots (ressenyes, info pública, missatges entrants) |
| **Trustpilot / OpinionsLocales** | Captació automàtica post-servei | Tots |
| **CalDAV genèric** | Sectors amb agendes pròpies o calendaris d'equip |
| **Zapier / Make / n8n connector** | Tots (catch-all per integracions de la cua llarga) |
| **TPV físic (Sumup, Square, Verifone)** webhooks | `hospitality` (lectura de tickets, no POS pròpi) |
| **eRecepta / HL7 FHIR (light) / DICOM viewer** | `practice` salut (V2+, només si hi ha demanda forta) |
| **Sistemes d'alarma / IoT industrial** (genèric MQTT) | `workshop_maker` avançat |

## 6.3 Patró tècnic uniforme

Per evitar acabar amb 20 implementacions divergents:

### Esquema de dades

```
data.tenant_integrations
  id              uuid PK
  tenant_id       uuid FK
  provider        text       -- 'resend', 'whatsapp_360dialog', 'google_calendar', ...
  status          text       -- 'connected' | 'disconnected' | 'error' | 'pending_oauth'
  config          jsonb      -- públic (no sensible): scopes, ids, preferències
  credentials_ref text       -- referència a vault/pgsodium
  last_health_check_at timestamptz
  last_health_status   text
  installed_by    uuid       -- auth.uid() de qui l'ha activat
  installed_at    timestamptz
  UNIQUE (tenant_id, provider)

data.integration_events    -- log per debugging
  id, tenant_integration_id, kind ('webhook_in'|'sync_out'|'error'|'health'),
  payload jsonb, error_text?, occurred_at
```

### Estructura d'una Edge Function per provider

`supabase/functions/integration-<provider>/`

Operacions bàsiques (cada provider implementa el subset que té sentit):

```ts
// connect: OAuth callback o emmagatzemar API key
POST /connect           → desa credentials xifrades, status='connected'
POST /disconnect        → revoca + status='disconnected', conserva històric
GET  /health            → ping i refresca last_health_*
POST /sync              → cridable manualment o per pg_cron
POST /webhook           → endpoint públic per al provider (signed payloads)
```

Cada un audita a `data.integration_events` i a `data.audit_logs`.

### Webhooks entrants

- Edge Functions exposades sense JWT, validades per **signatura HMAC** del
  provider.
- `tenant_id` resolt per `provider_account_id` desat al moment del connect.
- Persistència idempotent via `event_id` del provider (DEDUP key).

## 6.4 WhatsApp — nota especial

És **la** integració que defineix la percepció de modernitat del producte
en mercats Iberia/LATAM. Mereix atenció pròpia.

### Consideracions

- Aprovació de Meta per a **plantilles** (utility / marketing /
  authentication). Cal preparar plantilles ja en l'idioma de cada vertical.
- **Cost per missatge** segons país i categoria. Mostra-ho al tenant
  (vegeu §6.7).
- **Window de 24h**: dins, missatges lliures (text); fora, només
  plantilles aprovades.
- Cal **número dedicat** (compra dins de Meta o via BSP).
- BSPs recomanats: **360dialog, Twilio, MessageBird, Infobip**.

### Estratègia per fases

- **V1**: començar amb **un BSP que ofereixi API REST simple i revenda**
  (360dialog o MessageBird). Tenant no necessita compte propi de Meta.
- **V2**: opció **\"BYO WhatsApp\"** (porta el teu número/BSP), patró
  similar al BYOS d'email. Útil per tenants amb identitat de marca pròpia
  ja al WhatsApp.
- **Templates seed per arquetip**: cada `industry_archetype` defineix
  plantilles inicials (confirmació, recordatori 24h, recordatori 2h,
  no-show, post-servei). El vertical les pot estendre amb to específic.

### Inbound

- Missatges entrants → `data.communications` amb
  `direction='in'`, `channel='whatsapp'`, lligat al `Contact` (matching
  per telèfon E.164).
- Notificació al usuari assignat al Contact.

## 6.5 IA — arquitectura `ai-gateway`

L'IA toca tantes integracions diferents que la fem **una capa pròpia**, no
un addon més.

### Per què un gateway intern

1. **Abstracció de provider**: poder canviar OpenAI ↔ Anthropic ↔ Mistral ↔
   model local sense tocar la resta del codi.
2. **Quotes per tenant**: comptabilització uniforme a
   `data.usage_metrics` (vegeu §6.7).
3. **PII filter**: redacció de dades sensibles abans d'enviar a provider
   extern. Crític per `practice` (salut, legal).
4. **Audit**: tota crida queda a `data.ai_invocations` (prompt, model,
   tokens, cost, tenant, user, finalitat).
5. **Rate limit i cost ceiling**: tallar abans que se'n vagi de mans.
6. **Caching** quan és possible (mateixa pregunta + mateix context →
   resposta cacheada).

### Casos d'ús previstos (vegeu doc 07 per detall)

- Voice notes → text (Whisper)
- Resum 360° d'un Contact (LLM)
- Classificació automàtica (LLM)
- Redacció de comunicacions (LLM)
- OCR + estructuració (DocAI / Mindee + LLM)
- Cerca semàntica al DMS (embeddings)

### Política PII

- Per `practice` amb addon clínic: **proxy obligatori** que enmascari noms
  i identificadors abans del provider extern. Opció V2.5 de model local
  on-prem o europeu (Mistral, Cohere via UE).
- Per altres arquetips: avís clar al primer ús i opt-in.

### Opció Enterprise (V2+)

- **Model local per tenant** (Ollama, vLLM, autoallotjat) per a clients
  amb requisits regulatoris durs (sanitat, legal corporatiu).

## 6.6 Mapeig integració × arquetip

Quines integracions encén el producte per defecte segons l'arquetip
(orientatiu, sempre opt-in):

| Arquetip | Suggerides al primer dia | Suggerides quan creix |
|---|---|---|
| `field_service` | WhatsApp, SMS, Google Calendar, Maps | OCR factures, Holded, signatura pressupostos, IA voice notes |
| `practice` | WhatsApp, SMS (recordatoris massius), Calendar | Signatura consentiments, IA voice notes (anamnesi), Stripe payment links |
| `hospitality` | WhatsApp, GBP, TPV físic | TheFork/CoverManager, Glovo (si delivery) |
| `lodging` | WhatsApp, GBP, channel manager | Signatura registres viatgers, IA classificació de reviews, taxa turística |
| `workshop_maker` | WhatsApp, OCR factures, Holded | Signatura pressupostos, Maps rutes, signatura contractes B2B |
| `appointment_walkin` | WhatsApp, Calendar, GBP | Stripe payment links, IA classificació reviews |

## 6.7 Comptabilització de consums

Algunes integracions costen diners variables. Cal exposar-ho al tenant per
evitar sorpreses i per poder facturar quan calgui.

### Taula `data.usage_metrics`

```
tenant_id, period (YYYY-MM), kind, qty, unit, cost_cents?
   kind ∈ {
     'whatsapp_utility', 'whatsapp_marketing',
     'sms_out', 'email_sent',
     'ai_tokens_in', 'ai_tokens_out', 'ai_audio_seconds',
     'storage_gb_month', 'ocr_pages'
   }
```

- Actualitzada per cada Edge Function després de cada operació
  (fire-and-forget).
- Vista `api.usage_summary` per al tenant: gràfic mensual + top-3 d'on va
  el consum.
- Quotes per pla → `data.plans.metadata.quotas` amb límits soft
  (avís) i hard (bloqueig).

### Bloqueig per quota

- **Soft** (90% del límit): banner + email al `owner`.
- **Hard** (100%): la integració es pausa, no es trenca; els missatges
  van a la cua amb status `quota_exceeded` i s'envien automàticament al
  cicle següent o quan el tenant amplia pla.

## 6.8 Auth i credencials — bones pràctiques

- **OAuth quan existeix**: refresh token al vault, mai a `config`.
- **API keys**: només xifrades amb `pgsodium`. Mai mostrades en clar
  després del primer guardat (només màscara `sk_***...XYZ`).
- **Rotació**: UI per rotar/revocar des del tenant.
- **Scopes mínims**: demanar només els permisos imprescindibles.
- **Revocació en cascada**: si un tenant es desactiva, totes les
  integracions queden en `disconnected` i les credencials s'esborren
  passat un período (90 dies).

## 6.9 Què no farem (anti-patrons)

- ❌ **Workflow builder visual** d'integracions (\"Quan passi X, fes Y\").
  El nostre target no l'usaria. Si cal aquest poder → connector Zapier/Make.
- ❌ **iPaaS pròpia**. Dejà vu d'altres SaaS que es perden construint
  middleware.
- ❌ **Sync \"intel·ligent\"** que desfà el que l'usuari fa al sistema
  extern. Sempre conflictes resolts cap a una direcció **declarada per
  integració** (ex: Google Calendar és font de veritat dels seus events).
- ❌ **Embeure SDKs JS de tercers al frontend** llevat dels de pagament
  oficials (Stripe Elements). Tot a través d'Edge Functions per controlar
  audit i credencials.

## 6.10 Decisions a tancar

1. **WhatsApp BSP de llançament**: 360dialog vs Twilio? *(Recomanació:
   360dialog per cost, Twilio si ja farem servir SMS — un sol vendor.)*
2. **Stripe Connect vs payment links simples**: V1 simple (link generat
   i enviat per WhatsApp/email), V2 Connect si arriba demanda.
3. **OCR provider de capçalera**: Mindee té millor pricing per pocs
   documents; Textract escala millor. *(Recomanació: començar Mindee.)*
4. **Calendar sync bidireccional o només pull?**: V1 pull (lectura de
   l'extern, escriure els nostres com a nous), V2 bidireccional amb
   matching per `external_event_id`.
5. **Verifactu/TicketBAI/SII** són **obligatoris** a Espanya per certs
   trams. Cal posar-ho a Tier 1 fiscal abans de massificar a empreses
   amb facturació.
6. **GDPR data processor agreements**: cal repositori de DPAs signats per
   provider, accessible al tenant des del panell d'integracions.
