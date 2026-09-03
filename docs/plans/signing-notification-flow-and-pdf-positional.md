# Pla: Notification Flow Control + PDF Positional Support

**Creat:** 2026-05-29  
**Prioritat:** Phase A (Notification Flow) → Phase B (PDF Positional)  
**Estat:** Disseny revisat, no implementat

---

## 1. Context i descobertes del codi actual

### Sistema actual (com funciona ara)
- `sign-document-router` força `send_email: false` per DOCX/PDF i HTML.
- El pas "done" del wizard mostra únicament `result.signing_url` (primer signant).
- `data.signing_submissions.signers` guarda un snapshot JSONB de tots els signants.
- `docuseal-webhook` ja actualitza el snapshot `signers[]` amb `signing_url` (via slug) i estat per cada signant.
- `SigningSubmissionDetail` ja mostra la URL global i la URL per signant al drawer.
- Infraestructura d'email robusta: `api.enqueue_email(jsonb)` → `email_send_queue` → `process-email-queue`.

### Gap analysis (el que falta)
1. Cap mode de notificació al payload/model de submissions.
2. Cap control d'UI per triar la política de flux (DocuSeal auto vs app-gestionat).
3. Cap lògica de seqüenciació automàtica (enviar signant #2 quan #1 completa).
4. `sign-document-router` captura únicament la URL del primer signant a la resposta.
5. El lookup del webhook depèn d'`external_id`, però **l'assignació actual és únicament al primer signant (`idx === 0`)** → events `form.*` de signants 2+ fallen silenciosament.

---

## 2. Bugs crítics identificats al codi actual

### BUG-1: Webhook cec per als signants 2+ en events `form.*` *(crític)*

**Fitxer:** `supabase/functions/docuseal-webhook/index.ts` línies 570–592  
**Problema:** En events `form.*` (com `form.completed`), `data` ÉS el submitter directament (no la submission). La lògica de lookup és:

```
externalId = data.external_id         // undefined per signants 2+ (cap external_id assignat)
          || data.application_key     // null (DocuSeal no el posa aquí)
          || data.submitters?.[0]?.external_id  // undefined perquè data NO té .submitters
```

→ `externalId` és `null` → webhook retorna `{ processed: false, reason: "no_external_id" }` sense error visible.  
→ Cap actualització d'estat ni notificació seqüencial per signants 2+.

**Fix:** Assignar `external_id` a tots els submitters amb format `${submissionExternalId}:s${idx}`. Al webhook, extreure el prefix per fer el lookup de la submission.

---

### BUG-2: URL de slug hardcoded a `sign-document-router` *(menor)*

**Fitxer:** `supabase/functions/sign-document-router/index.ts` línia 634  
**Problema:**
```typescript
: (typeof firstSigner?.slug === "string" ? `https://docuseal.eu/s/${firstSigner.slug}` : undefined);
```
Usa el domini `docuseal.eu` hardcoded en lloc de `DOCUSEAL_SIGNING_BASE_URL`. El webhook usa correctament `DOCUSEAL_SIGNING_BASE_URL` per construir les mateixes URLs.

**Fix:** Substituir per `${DOCUSEAL_SIGNING_BASE_URL}/s/${firstSigner.slug}`.

---

### BUG-3: `mime_type` i `template_type` de `document_template_locales` no inclouen PDF *(bloquejant per Phase B)*

**Fitxer:** `supabase/migrations/20260522000002_dms_templates_html_signing_roles.sql`  
**Problema:**
- La migració elimina `'application/pdf'` del CHECK de `mime_type`.
- El CHECK de `template_type` només permet `('docx', 'html')`.
- Locales PDF existents van ser desactivats (`is_active=false`).

**Fix Phase B:** Nova migració que:
1. Restaura `'application/pdf'` al CHECK de `mime_type`.
2. Afegeix `'pdf'` al CHECK de `template_type`.
3. Reactiva els locales PDF si escau.

---

### BUG-4: `api.enqueue_signing_notification` necessita GRANT a `service_role` *(crític per webhook)*

**Problema:** `api.enqueue_email` únicament té `GRANT EXECUTE TO authenticated`. El webhook usa `createAdminClient()` (service_role). Si la nova RPC `api.enqueue_signing_notification` és `SECURITY DEFINER` i només es concedeix a `authenticated`, el webhook no la podrà cridar.

**Fix:** A la migració de la nova RPC:
```sql
GRANT EXECUTE ON FUNCTION api.enqueue_signing_notification(...) TO authenticated, service_role;
```

---

## 3. Phase A — Notification Flow Control

### A1. Extensions del model de dades

**Nova migració:** `supabase/migrations/20260530000001_signing_notification_mode.sql`

```sql
-- Enum de modes
CREATE TYPE data.signing_notification_mode AS ENUM (
  'docuseal_auto',       -- DocuSeal envia els emails directament
  'app_manual',          -- cap email automàtic; URLs visibles a l'app
  'app_auto_all',        -- app envia email a tots els signants immediatament
  'app_auto_sequential'  -- app envia email al signant #1; cada signer N+1 quan N completa
);

-- Columnes noves a data.signing_submissions
ALTER TABLE data.signing_submissions
  ADD COLUMN notification_mode    data.signing_notification_mode NOT NULL DEFAULT 'app_auto_sequential',
  ADD COLUMN notification_enabled boolean                        NOT NULL DEFAULT true,
  ADD COLUMN next_signer_index    integer                        NULL,
  ADD COLUMN first_email_sent_at  timestamptz                    NULL,
  ADD COLUMN last_notification_at timestamptz                    NULL;

-- Config de tenant: mode per defecte
ALTER TABLE data.tenant_signing_config
  ADD COLUMN default_notification_mode data.signing_notification_mode NOT NULL DEFAULT 'app_auto_sequential';
```

**Taula normalitzada de submitters (OBLIGATÒRIA per orquestració seqüencial fiable):**

```sql
CREATE TABLE data.signing_submitters (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  submission_id          uuid NOT NULL REFERENCES data.signing_submissions(id) ON DELETE CASCADE,
  tenant_id              uuid NOT NULL REFERENCES data.tenants(id),
  signer_order           integer NOT NULL,
  role                   text,
  email                  text NOT NULL,
  name                   text NOT NULL DEFAULT '',
  external_submitter_id  text,          -- external_id enviat a DocuSeal per a aquest signant
  signing_url            text,
  status                 text NOT NULL DEFAULT 'pending',
  notified_at            timestamptz,
  email_log_id           uuid,          -- FK a data.email_logs per traçabilitat
  opened_at              timestamptz,
  completed_at           timestamptz,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  UNIQUE (submission_id, signer_order)
);
```

> **Nota de disseny:** Sense la taula `signing_submitters`, les actualitzacions concurrents del JSONB `signers` poden causar race conditions quan múltiples events del webhook arriben en ràpida successió. La taula normalitzada és **obligatòria** per a l'orquestració seqüencial, no opcional.

El JSONB `signing_submissions.signers` es manté com a snapshot per a la vista existent i per compatibilitat amb codi que el llegeix directament.

---

### A2. Vistes API i tipus de frontend

**Actualitzar `api.signing_submissions`** per exposar:
- `notification_mode`
- `notification_enabled`
- `next_signer_index`
- `first_email_sent_at`
- `last_notification_at`

**Nova vista `api.signing_submitters`** que exposa `data.signing_submitters` (filtrada per RLS `tenant_id`).

**Regenerar tipus** un cop fetes les migracions:
```powershell
supabase gen types typescript --local 2>$null | Set-Content "apps/tenant-portal/src/types/database.types.ts" -Encoding utf8
Copy-Item "apps/tenant-portal/src/types/database.types.ts" "supabase/functions/_shared/database.types.ts"
```

**Actualitzar `apps/tenant-portal/src/features/signing/api/signingService.ts`:**

```typescript
// SignDocumentInput afegeix:
notification_mode?: 'docuseal_auto' | 'app_manual' | 'app_auto_all' | 'app_auto_sequential';

// SignDocumentResult afegeix:
signer_links?: Array<{
  role?:        string;
  name?:        string;
  email?:       string;
  order?:       number;
  signing_url?: string | null;
}>;
```

---

### A3. sign-document-router — matriu de comportament

#### Fix BUG-1: external_id per a tots els submitters

```typescript
// Nou format: "${submissionExternalId}:s${idx}"
const submitters = signers.map((s, idx) => ({
  email:       s.email,
  name:        s.name,
  role:        s.role ?? `Signer ${idx + 1}`,
  order:       s.order ?? idx,
  external_id: `${externalId}:s${idx}`,  // TOTS els signants ara tenen external_id
}));
```

#### Fix BUG-2: slug URL

```typescript
const signingUrl = typeof firstSigner?.embed_src === "string"
  ? firstSigner.embed_src
  : (typeof firstSigner?.slug === "string"
      ? `${DOCUSEAL_SIGNING_BASE_URL}/s/${firstSigner.slug}`  // ← fix: usa variable
      : undefined);
```

#### Capturar TOTES les URLs dels submitters

```typescript
// Extreure URL per a cada submitter de la resposta de DocuSeal
const allSubmitters = Array.isArray(result.submitters)
  ? (result.submitters as Array<Record<string, unknown>>)
  : [];

const signerLinks = allSubmitters.map((s, idx) => ({
  order:       idx,
  email:       s.email as string ?? "",
  role:        s.role as string ?? "",
  signing_url: typeof s.embed_src === "string"
    ? s.embed_src
    : (typeof s.slug === "string"
        ? `${DOCUSEAL_SIGNING_BASE_URL}/s/${s.slug as string}`
        : null),
}));

return { submissionId, signingUrl: signerLinks[0]?.signing_url, signerLinks };
```

#### Matriu mode → comportament

| Mode | `send_email` a DocuSeal | Email immediat (app) | Lògica seqüencial |
|---|---|---|---|
| `docuseal_auto` | `true` | cap | DocuSeal gestiona l'ordre |
| `app_manual` | `false` | cap | — |
| `app_auto_all` | `false` | tots els signants ara | — |
| `app_auto_sequential` | `false` | signer #1 ara; la resta via webhook | webhook → `enqueue_signing_notification` |

Per als modes `app_auto_all` i `app_auto_sequential`, sign-document-router fa la crida inicial a `api.enqueue_signing_notification` **dins la mateixa transacció de creació de submission** (o just després), per garantir que el primer email sempre s'envia.

---

### A4. docuseal-webhook — orquestració de notificacions

#### Fix BUG-1 al webhook: lookup per external_id amb strip de suffix

```typescript
// Per form.* events: data.external_id = "${submissionExternalId}:s${idx}"
// Extreure el submissionExternalId stripejant el sufix ":sN"
const rawExtId = data.external_id ?? data.submitters?.[0]?.external_id ?? null;
const submissionExternalId = rawExtId?.replace(/:s\d+$/, '') ?? null;
const signerIdx = rawExtId ? parseInt(rawExtId.split(':s')[1] ?? '-1', 10) : -1;

// Lookup per docuseal_submission_id si tenim data.id i és una submission.* event
// O per external_id (stripejat) per a form.* events
```

**Prioritat de lookup:**
1. `docuseal_submission_id = data.id` (per a events `submission.*`)
2. `external_id = submissionExternalId` (per a events `form.*` amb el sufix eliminat)
3. Si cap → ignorar event amb warning

#### Trigger de notificació seqüencial

Quan `event_type === 'form.completed'` i `notification_mode === 'app_auto_sequential'`:

```typescript
// Cridar RPC per encuar email del següent signant
await adminClient.rpc('enqueue_signing_notification', {
  p_submission_id:  submission.id,
  p_signer_order:   completedSignerOrder + 1,
  p_reason:         'sequential_next',
});
// Fire-and-forget: errors de notificació no trenquen el flux principal
```

#### Nova RPC: `api.enqueue_signing_notification`

```sql
CREATE OR REPLACE FUNCTION api.enqueue_signing_notification(
  p_submission_id  uuid,
  p_signer_order   integer,
  p_reason         text DEFAULT 'manual'
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_submitter  data.signing_submitters%ROWTYPE;
  v_submission data.signing_submissions%ROWTYPE;
  v_log_id     uuid;
BEGIN
  -- Obtenir submitter i submission
  SELECT * INTO v_submitter
  FROM data.signing_submitters
  WHERE submission_id = p_submission_id AND signer_order = p_signer_order;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'submitter_not_found';
  END IF;

  SELECT * INTO v_submission
  FROM data.signing_submissions WHERE id = p_submission_id;

  -- Encuar email via infraestructura existent
  SELECT api.enqueue_email(jsonb_build_object(
    'tenant_id',    v_submission.tenant_id,
    'event_type',   CASE WHEN p_signer_order = 0 THEN 'signing.request.initial'
                         ELSE 'signing.request.next_signer' END,
    'to_email',     v_submitter.email,
    'to_name',      v_submitter.name,
    'variables',    jsonb_build_object(
      'signer_name',    v_submitter.name,
      'signer_email',   v_submitter.email,
      'signer_role',    v_submitter.role,
      'document_title', v_submission.document_title,
      'signing_url',    v_submitter.signing_url,
      'current_order',  p_signer_order + 1,
      'total_signers',  (SELECT COUNT(*) FROM data.signing_submitters WHERE submission_id = p_submission_id)
    )
  )) INTO v_log_id;

  -- Actualitzar notified_at al submitter
  UPDATE data.signing_submitters
  SET notified_at = now(), email_log_id = v_log_id, updated_at = now()
  WHERE id = v_submitter.id;

  -- Actualitzar last_notification_at a la submission
  UPDATE data.signing_submissions
  SET last_notification_at = now(), next_signer_index = p_signer_order
  WHERE id = p_submission_id;

  -- Audit log
  PERFORM data.log_audit_event(
    'SIGNING_NOTIFICATION_SENT',
    'signing_submitter',
    v_submitter.id,
    jsonb_build_object('submission_id', p_submission_id, 'order', p_signer_order, 'reason', p_reason)
  );

  RETURN v_log_id;
END;
$$;

-- Grants: necessari per authenticated (frontend resend) i service_role (webhook)
GRANT EXECUTE ON FUNCTION api.enqueue_signing_notification(uuid, integer, text)
  TO authenticated, service_role;
```

---

### A5. Templates d'email per a signatura

Afegir a la migració (o a seeds) els nous event types:

| `event_type` | Ús |
|---|---|
| `signing.request.initial` | Primer email al signant #1 |
| `signing.request.next_signer` | Email seqüencial a signants posteriors |
| `signing.reminder` | (Reservat per futur) |

Variables disponibles als templates:
- `signer_name`, `signer_email`, `signer_role`
- `document_title`
- `signing_url` — URL única de signatura per a aquest signant
- `tenant_name` — resolt automàticament per la infraestructura d'email
- `current_order`, `total_signers`

El layout de marca del tenant es resol automàticament via la lògica existent de `api.enqueue_email`.

---

### A6. UI — DocumentOrchestrator

**Pas `select_signers`:**
- Afegir selector "Flux de notificació" amb les 4 opcions (default `app_auto_sequential`).
- Explicació curta sota el selector (1 frase per opció).
- El mode seleccionat s'envia a `SignDocumentInput.notification_mode`.

**Pas `done`:**
- `docuseal_auto`: ocultar bloc d'URL directa al wizard (DocuSeal gestiona el lliurament). Mostrar CTA a Signing Center.
- `app_*` modes: si `notification_enabled = true` → mostrar "Email enviat a [signer_name]". Si `app_manual` → mostrar CTA per copiar URLs per signant.
- Sempre disponibles al Signing Center.

**Títol condicional del diàleg:**
```typescript
const dialogTitle = hasSigningRoles
  ? t('orchestrator.title.sign', 'Preparar i signar document')
  : t('orchestrator.title.generate', 'Preparar document');
```

**Preview de dos columnes** al pas `fill_variables` per a DOCX/HTML: `DialogContent` expandit a `max-w-5xl` amb panell de variables a l'esquerra i preview a la dreta.

---

### A7. Signing Center — UX updates

**`SigningSubmissionDetail.tsx`:**
- Mostrar badge de mode de notificació (color per mode).
- Per signant: mostrar estat de notificació (`pending / sent / completed`) amb timestamp.

**Accions noves per signant:**
- "Copiar URL de signatura" (sempre disponible si hi ha URL).
- "Reenviar email" (disponible si mode `app_*`; crida `api.enqueue_signing_notification`).
- "Enviar ara al següent" (disponible si mode `app_auto_sequential` i hi ha signant pendent).

**Llista d'events:** afegir events de tipus `SIGNING_NOTIFICATION_SENT` a la timeline de la submission.

---

## 4. Phase B — PDF Positional Fields

### B1. Dades i tipus

**Nova migració:** `supabase/migrations/20260530000002_pdf_fields_schema.sql`

```sql
-- Restaurar suport PDF a document_template_locales
ALTER TABLE data.document_template_locales
  DROP CONSTRAINT IF EXISTS document_template_locales_mime_type_check;

ALTER TABLE data.document_template_locales
  ADD CONSTRAINT document_template_locales_mime_type_check
  CHECK (mime_type IN (
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'text/html',
    'application/pdf'         -- ← restaurat
  ));

-- Restaurar 'pdf' a template_type
ALTER TABLE data.document_templates
  DROP CONSTRAINT IF EXISTS document_templates_template_type_check;

ALTER TABLE data.document_templates
  ADD CONSTRAINT document_templates_template_type_check
  CHECK (template_type IN ('docx', 'html', 'pdf'));  -- ← afegit 'pdf'

-- Afegir camps de camp posicional
ALTER TABLE data.document_template_locales
  ADD COLUMN pdf_fields_schema jsonb NULL;  -- [{ id, role, type, page, x, y, w, h, required, label }]
```

**Model TypeScript (`signing/types/documentFields.ts`):**

```typescript
export type FieldType = 'signature' | 'initials' | 'text' | 'date' | 'checkbox';
export type FieldSource = 'tag' | 'position';

export interface DocumentField {
  id:       string;
  role:     string;
  type:     FieldType;
  source:   FieldSource;
  label?:   string;
  required: boolean;
  // Per camps posicionals (source='position'):
  page?:    number;  // 0-indexed
  x?:       number;  // [0..1] relatiu a l'amplada de la pàgina
  y?:       number;  // [0..1] relatiu a l'alçada de la pàgina
  w?:       number;  // [0..1]
  h?:       number;  // [0..1]
}
```

Les coordenades normalitzades [0..1] permeten independència de resolució i faciliten el mapeig a `areas` de DocuSeal.

### B2. Editor visual de camps PDF

**Prerequisit:** Instal·lar dependències al `apps/tenant-portal`:
```bash
npm install react-pdf pdfjs-dist
```

**Configuració Vite** (`vite.config.ts`): Afegir worker de pdfjs-dist:
```typescript
// vite.config.ts
import { viteStaticCopy } from 'vite-plugin-static-copy';
// ...
plugins: [
  viteStaticCopy({
    targets: [
      {
        src: 'node_modules/pdfjs-dist/build/pdf.worker.min.mjs',
        dest: '',
      },
    ],
  }),
]
```

I configurar el worker path a l'entrada de l'app:
```typescript
import { GlobalWorkerOptions } from 'pdfjs-dist';
GlobalWorkerOptions.workerSrc = '/pdf.worker.min.mjs';
```

**Component `PdfFieldEditor.tsx`** (lazy loaded per evitar bundle bloat):
- Carrega el PDF via `react-pdf` (`<Document>`, `<Page>`).
- Overlay de canvas per dibuixar/arrossegar/redimensionar camps.
- Panell lateral: llista de camps, assignació de rol i tipus, marcar com obligatori.
- Coordenades guardades en format normalitzat [0..1].
- Suporta múltiples pàgines.

### B3. Payload builder per a DocuSeal

**Cas A (tags embedits):** DOCX amb `{{FIELD:role:type}}`, HTML amb `{{FIELD:role:type}}`, PDF amb tags. DocuSeal detecta automàticament → no cal camps al payload.

**Cas B (PDF posicional):** Construir `documents[].fields[]` per a DocuSeal:

```typescript
function buildDocuSealFields(fields: DocumentField[]): DocuSealField[] {
  return fields.map(f => ({
    name:       f.label ?? `${f.role}_${f.type}`,
    role:       f.role,
    type:       f.type,  // 'signature', 'initials', 'text', 'date', 'checkbox'
    required:   f.required,
    areas: [{
      x:      f.x! * 100,      // DocuSeal espera [0..100]
      y:      f.y! * 100,
      w:      f.w! * 100,
      h:      f.h! * 100,
      page:   (f.page ?? 0) + 1,  // DocuSeal és 1-indexed
    }],
  }));
}
```

### B4. Validació

Bloquejar enviament quan:
- `template_type = 'pdf'` i `pdf_fields_schema` és buit o nul.
- Hi ha rols de signant sense cap camp assignat al PDF.
- Coordenades fora de rang [0..1].
- Coordinades se superposen entre camps del mateix signant.

---

## 5. Fitxers a crear / modificar

### Nous fitxers
| Fitxer | Fase |
|---|---|
| `supabase/migrations/20260530000001_signing_notification_mode.sql` | A1 |
| `supabase/migrations/20260530000002_pdf_fields_schema.sql` | B1 |
| `apps/tenant-portal/src/features/signing/utils/templateAnalysis.ts` | A6 |
| `apps/tenant-portal/src/features/signing/types/documentFields.ts` | B1 |
| `apps/tenant-portal/src/features/signing/components/PdfFieldEditor.tsx` | B2 |

### Fitxers modificats
| Fitxer | Canvis principals | Fase |
|---|---|---|
| `supabase/functions/sign-document-router/index.ts` | Fix BUG-2 slug URL; fix BUG-1 external_id; capturar totes les URLs; implementar matriu de modes; enviar email inicial per `app_auto_*` | A3 |
| `supabase/functions/docuseal-webhook/index.ts` | Fix BUG-1 lookup amb strip de sufix; trigger notificació seqüencial | A4 |
| `apps/tenant-portal/src/features/signing/components/DocumentOrchestrator.tsx` | Títol condicional; selector de mode; done step condicional; preview de dues columnes | A6 |
| `apps/tenant-portal/src/features/signing/components/TemplateFormModal.tsx` | Moure funcions d'extracció a `utils/templateAnalysis.ts`; afegir suport PDF | A6/B |
| `apps/tenant-portal/src/features/signing/api/signingService.ts` | Ampliar `SignDocumentInput`, `SignDocumentResult`, `SignerSnapshot` | A2 |
| `apps/tenant-portal/src/features/signing/components/SigningSubmissionDetail.tsx` | Badge mode, accions per signant, timeline notifications | A7 |
| `apps/tenant-portal/src/locales/ca/signing.json` | Noves claus: mode selector, etiquetes, missatges | A6/A7 |
| `apps/tenant-portal/src/types/database.types.ts` | Regenerar amb `supabase gen types typescript --local` | A2/B1 |
| `supabase/functions/_shared/database.types.ts` | Còpia sincronitzada de l'anterior | A2/B1 |
| `apps/tenant-portal/package.json` | Afegir `react-pdf`, `pdfjs-dist` | B2 |
| `apps/tenant-portal/vite.config.ts` | Configurar pdfjs worker | B2 |

---

## 6. Pla de verificació

### Matriu de modes (tests manuals)

| Mode | Email DocuSeal? | Email app? | URL al wizard? | URL al Center? |
|---|---|---|---|---|
| `docuseal_auto` | ✅ tots immediats | ❌ | ❌ (ocult) | ✅ |
| `app_manual` | ❌ | ❌ | ✅ per signant | ✅ |
| `app_auto_all` | ❌ | ✅ tots ara | ✅ per signant | ✅ |
| `app_auto_sequential` | ❌ | ✅ signer #1 ara; resta quan l'anterior completa | ✅ per signant | ✅ |

### Validació de persistència
- Snapshot `signers` conté `role/order/url/status` per cada signant.
- Taula `signing_submitters` sincronitzada amb cada event del webhook.
- `notified_at` s'actualitza per cada email enviat.
- `next_signer_index` avança correctament en mode seqüencial.

### Robustesa d'errors
- Fallida de cua d'email no trenca l'estat de signatura (fire-and-forget).
- Reintent manual des del Signing Center funciona independentment.
- Webhook idempotent: processar el mateix event dues vegades no duplica notificacions (`notified_at` present → skip).

### Regressió
- Flux DOCX/HTML existent (sense canvis de mode) funciona igual.
- Llistat i filtres del Signing Center continuen funcionant.
- API view `api.signing_submissions` continua retornant tots els camps anteriors.

---

## 7. Límits d'abast

**Inclòs ara:**
- Arquitectura del flux de notificació i controls d'UI.
- Persistència i claredat de la URL per signant.
- Disseny de l'orquestració seqüencial d'emails.
- Suport PDF posicional (disseny i implementació de fons).

**Diferit (pròxim increment):**
- Cadències de recordatoris i escalat SLA.
- Dashboards de lliurament d'email.
- Enrutament avançat (còpia legal, aprovadors condicionals).
- Firma en persona (kiosk mode).




**Cadències de recordatoris i escalat SLA**
Un signant rep l'email però no signa en X hores/dies. Cal un sistema que rellegeixi `signing_submitters` periòdicament (via `pg_cron`), detecti qui porta massa temps en estat `sent` sense `completed_at`, i torni a encuar un email de recordatori. L'"escalat SLA" és la variant més avançada: si el signant segueix sense respondre després de N recordatoris, l'acció canvia (notifica al gestor, cancel·la la submission, o bloqueja el document). Tota la infraestructura de cua ja existeix (`reminders_queue`, `process-reminders-queue`); el que falta és la lògica de detecció i configuració de les cadències (interval, màxim de reintents) per tenant.

---

**Dashboards de lliurament d'email**
Ara sabem si *s'ha encuat* un email (`email_log_id` a `signing_submitters`), però no si *ha arribat*. Un dashboard de lliurament requeriria connectar els events de l'ESP (proveïdor d'email: bounced, opened, clicked) via webhook inbound → actualitzar `data.email_logs` amb estat de lliurament → exposar mètriques a l'admin-portal. Depèn de la integració BYOS SMTP / Resend webhook, que és infraestructura no implementada.

---

**Enrutament avançat (còpia legal, aprovadors condicionals)**
Dos sub-casos:
- **Còpia legal:** enviar un CC automàtic (sense signing_url, només lectura) a un email fix (assessoria legal, RRHH...) quan s'inicia o completa una submission. Requeriria un nou rol de submitter de tipus `observer` a DocuSeal + lògica al router.
- **Aprovadors condicionals:** un signant intermedi no signa el document sinó que *aprova o rebutja* el flux abans que el signant final actuï. DocuSeal té suport per a rols `approver`; el que falta és l'UI de configuració per definir condicions (si rol X aprova → continua; si rebutja → cancel·la + notifica) i la lògica de branca al webhook.

---

**Firma en persona (kiosk mode)**
Un cas d'ús on el signant no rep cap email: un empleat acosta el mòbil/tauleta a un responsable que introdueix la seva signatura directament a la pantalla. El flux seria: el gestor obre la submission al Signing Center → selecciona "Signar en persona" per a un signant concret → el dispositiu entra en mode kiosk (oculta la nav, pantalla completa) → es mostra l'iframe de DocuSeal amb la URL del signant → quan completa, surt del mode kiosk. Requeriria UI específica i gestió de sessió per evitar que el kiosk exposi dades del gestor.