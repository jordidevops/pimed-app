# Pla de Redisseny: Sistema de Plantilles DOCX/HTML + Signing Roles

**Data**: Maig 2026  
**Estat**: En implementació (Fase 0 iniciada)  
**Lliurable V1**: DOCX + HTML, `template_type` immutable, `signing_roles_schema`, claus path-based (`{{prefix.field_path}}`), `context_refs`, entity pickers i HTML branch a `sign-document-router`.  
**Deixat per V2**: vegeu secció final.

---

## Motivació

El sistema actual (`20260522000001_dms_templates_signing_core.sql`) té:
- `data.document_template_locales` sense `html_content` ni `signing_roles_schema`
- `data.document_templates` sense `template_type`
- `api.create_document_template` sense `p_template_type`
- `sign-document-router` que no suporta `text/html` ni `order` per als signants
- Variables de contingut DOCX escanejades amb `{{key}}` (format nostre antic) però DocuSeal usa `[[key]]` nativament per a placeholders de contingut
- Regex d'extracció (`\w+`) que no admet claus amb punt (`employee.full_name`)
- Auto-fill actual basat en heurística de nom de clau (`email/name`) en lloc d'un binding determinista
- Clonació de locales que omet `storage_path` (bug)
- `select('*')` als hooks, problemàtic quan `html_content` existeixi

---

## Convencions DocuSeal (realitat de l'API)

| | DOCX | HTML |
|---|---|---|
| Variables de contingut | `[[Treballador.full_name]]` (natiu DocuSeal — substituït pre-signing, no interactiu) | `{{Treballador.full_name}}` (substitució server-side nostra) |
| Camps interactius (text/data) | `{{Camp;type=text;role=Treballador}}` (ompleble pel signant) | — |
| Camps de signatura | `{{Firma;type=signature;role=Treballador}}` | `<signature-field name="Firma" role="Treballador" required="true" style="width:150px;height:50px;display:inline-block;"> </signature-field>` |
| Endpoint DocuSeal | `POST /submissions/docx` + `variables:{k:v}` pre-emplenant `[[key]]` | `POST /submissions/html` |
| Escaneig variables | Dual: `/\[\[([\w.]+)\]\]/g` + `/\{\{([\w.]+)\}\}/g` (compat legacy) | `/{{\s*([\w.]+)\s*}}/g` |
| Escaneig rols | Regex tolerant `/\{\{[^}]*?;role=["']?([^;"'\}]+)/gi` | DOMParser sobre elements `*-field` |

### Estructura `signing_roles_schema` (per locale)

```json
{
  "Treballador": {
    "entity_type": "employee",
    "label": "Empleat que signa",
    "order": 1,
    "for_signing": true
  },
  "Empresa": {
    "entity_type": "user",
    "label": "Representant empresa",
    "order": 2,
    "for_signing": true
  }
}
```

`entity_type`: `'contact' | 'employee' | 'user' | 'person' | 'site' | 'asset' | 'tenant'`

### Model `variables_schema` (claus path-based)

```json
{
  "Treballador.full_name": {
    "type": "string",
    "label": "Nom del treballador",
    "required": true,
    "role": "Treballador"
  },
  "Treballador.metadata.nif": {
    "type": "string",
    "label": "NIF",
    "required": false
  },
  "site.name": {
    "type": "string",
    "label": "Nom del centre",
    "required": true
  }
}
```

Regla: la clau (`key`) ja conté el binding (`prefix + field_path`).
No s'afegeixen camps `source_entity_type` ni `source_field_path` al `VariableDef`.

### `context_refs` al payload del router (automatització i UI)

```json
{
  "context_refs": {
    "Treballador": { "entity_type": "employee", "entity_id": "..." },
    "Empresa": { "entity_type": "user", "entity_id": "..." },
    "site": { "entity_type": "site", "entity_id": "..." }
  }
}
```

Prioritat de resolució recomanada:
1. `variables` manuals del request (override explícit)
2. Resolució automàtica de claus path-based via `context_refs`
3. Fallback buit (`''`) amb warning estructurat

---

## Fases V1 (ordre d'implementació)

### FASE 0 — SQL + contractes (bloquejant per tot)

**Fitxer**: `supabase/migrations/20260522000002_dms_templates_html_signing_roles.sql`

1. `ALTER TABLE data.document_templates ADD COLUMN template_type TEXT NOT NULL DEFAULT 'docx' CHECK (template_type IN ('docx','html'))`
2. Trigger `BEFORE UPDATE` d'**immutabilitat** de `template_type` — si canvia, `RAISE EXCEPTION`
3. `ADD COLUMN html_content TEXT` (NULL per DOCX) a `data.document_template_locales`
4. `ADD COLUMN signing_roles_schema JSONB NOT NULL DEFAULT '{}'` a `data.document_template_locales`
5. Canviar CHECK `mime_type`: substituir `'application/pdf'` per `'text/html'`
6. Afegir CHECK de consistència: `(mime_type='text/html' AND html_content IS NOT NULL) OR (mime_type LIKE '%wordprocessingml%' AND storage_path IS NOT NULL)`
7. `UPDATE data.document_template_locales SET is_active=false WHERE mime_type='application/pdf'` — desactivació segura
8. Actualitzar `api.document_templates`: exposar `template_type`
9. Actualitzar `api.document_template_locales`: exposar `signing_roles_schema` (**NO `html_content`** — càrrega lazy via hook separat)
10. Actualitzar `api.create_document_template`: afegir `p_template_type TEXT DEFAULT 'docx'`
11. Regenerar `database.types.ts` en ambdós llocs

### FASE 1 — Data layer frontend (depèn F0)

**`signingService.ts`**:
- `VariableDef` + `role?: string | null`
- Nous tipus `SigningRoleDef`, `SigningRolesSchema`
- `SignDocumentInput.signers` + `order?: number`
- `SignDocumentInput.context_refs?: Record<string, { entity_type: string; entity_id: string }>`
- Funció `fetchLocaleDetail(localeId)` per `html_content` (lazy)

**`useDocumentTemplateMutations.ts`**:
- `UpsertLocaleInput`: fer `file` opcional, afegir `htmlContent?`, `signingRolesSchema?`
- `useCloneTemplateMutation`: **bug** — afegir `storage_path` i `signing_roles_schema` al SELECT/INSERT de clonació

**`useLocalesBatch.ts`** + **`useDocumentTemplateLocales.ts`**: SELECT explícit sense `html_content`

**`useCreateTemplateMutation`**: passar `p_template_type` a la RPC

**NOU `useContacts.ts`**: wrapper React Query sobre `getContacts()` (patró `useEmployees.ts`)

### FASE 2 — Parsing robust (parallel amb F1)

Funcions pures noves a `TemplateFormModal.tsx`:

| Funció | Lògica |
|--------|--------|
| `extractDocxVariableKeys(xml)` | Dual: `\[\[([\w.]+)\]\]` + `\{\{([\w.]+)\}\}`, dedup, normalize |
| `extractDocxSigningRoles(xml)` | Tolerant: `/\{\{[^}]*?;role=["']?([^;"'\}]+)["']?/gi` |
| `extractHtmlVariableKeys(html)` | `/{{\s*([\w.]+)\s*}}/g` excloent atributs `*-field` |
| `extractHtmlSigningRoles(html)` | DOMParser → `querySelectorAll` amb fallback regex |

### FASE 3 — TemplateFormModal + TipTap (depèn F1+F2)

- Radio obligatori DOCX/HTML al crear plantilla
- DOCX: `accept=".docx"` (eliminar PDF), escaneig automàtic
- HTML: NOU `TemplateHtmlEditor` (TipTap) amb inserció de `{{var}}` i `<signature-field>`
- Catàleg de variables per entitat/rol (`employee`, `site`, `user`, `contact`, `asset`, `tenant`) que insereix claus path-based (`{{Treballador.full_name}}`)
- Secció "Rols de firma": `entity_type`, `label`, `order`, `for_signing`
- Secció "Variables": `key` tècnica path-based + `label` amigable (les etiquetes lliures no governen la resolució)
- Límit `html_content`: validació client 500 KB màx; XSS: **DOMPurify** al preview

**NOU `TemplateHtmlEditor.tsx`**: TipTap + toolbar + "Inserir variable" + "Inserir camp firma"

### FASE 4 — DocumentOrchestrator (depèn F1+F3)

- Step `'select_signers'` → `'assign_contexts'`
- Entity picker per cada rol: `useEmployees` / `useContacts` / users / person (combined)
- `confirmAssignContexts()`: construir `context_refs` i auto-resoldre variables path-based
- Claus no path-based (legacy/manual) continuen com a inputs manuals al pas `fill_variables`
- `handleProcess()`: construir `signers` amb `order: rol.order - 1`
- `generate_pdf` ocult per templates HTML

### FASE 5 — sign-document-router HTML branch (depèn F0)

- `Signer` + `order?: number`
- `RequestBody.context_refs` + validació a `parseBody()`
- `resolveSourceFile()` branch `text/html`: llegir `html_content`, retornar sense Storage
- NOU `resolveContextVariables()`: parseig `prefix.field_path` + càrrega d'entitats de `context_refs` + traversal dot-notation (inclou `metadata.*`)
- `submitToDocuseal()` + `variables` al requestBody DOCX + `order` als submitters
- NOU `submitHtmlToDocuseal()`: substitució segura `{{key}}` (escape `<>`) → `POST /submissions/html`
- `generateOnlyVersion()` HTML: `TextEncoder` → upload `text/html` al DMS

### FASE 6 — Admin portal (parallel amb F3+F5)

- `document-templates.ts`: `template_type`, `html_content`, `signing_roles_schema`; eliminar PDF de `allowedExtensions`
- `AdminPlatformDocumentTemplates.tsx`: radio DOCX/HTML; `LocaleFormDialog` bifurca per tipus; fix `placeholder=` literals a `t(...)`

### FASE 7 — QA i rollout

1. Tests SQL: immutabilitat `template_type`, locales PDF desactivats, CHECK consistència
2. Tests edge: DOCX (existent), HTML, `generate_only` HTML, ordre signatura
3. Tests frontend: regressió `document_existing`, flux `assign_contexts`, clonació completa
4. Rendiment: `useLocalesBatch` sense `html_content`
5. i18n audit: `grep 'placeholder="[A-Z]' apps/`

---

## Fitxers afectats

### Nous
- `supabase/migrations/20260522000002_dms_templates_html_signing_roles.sql`
- `apps/tenant-portal/src/features/signing/components/TemplateHtmlEditor.tsx`
- `apps/tenant-portal/src/features/contacts/api/useContacts.ts`

### Modificats
- `apps/tenant-portal/src/types/database.types.ts` (regen)
- `supabase/functions/_shared/database.types.ts` (regen)
- `apps/tenant-portal/src/features/signing/api/signingService.ts`
- `apps/tenant-portal/src/features/signing/api/useDocumentTemplateMutations.ts`
- `apps/tenant-portal/src/features/signing/api/useDocumentTemplateLocales.ts`
- `apps/tenant-portal/src/features/signing/api/useLocalesBatch.ts`
- `apps/tenant-portal/src/features/signing/components/TemplateFormModal.tsx`
- `apps/tenant-portal/src/features/signing/components/DocumentOrchestrator.tsx`
- `apps/tenant-portal/src/features/signing/components/TemplatesPage.tsx`
- `apps/tenant-portal/src/locales/ca/signing.json`
- `apps/admin-portal/app/admin/actions/document-templates.ts`
- `apps/admin-portal/components/dashboard/settings/AdminPlatformDocumentTemplates.tsx`
- `supabase/functions/sign-document-router/index.ts`

### Sense canvis
- `supabase/functions/docuseal-webhook/index.ts`

---

## Decisions de disseny

| Decisió | Raó |
|---------|-----|
| Claus path-based (`{{prefix.field_path}}`) | El binding va dins la clau: menys heurístiques, millor mantenibilitat i debug |
| Resolver server-side amb `context_refs` | Suporta UI i processos automàtics amb la mateixa lògica |
| PDF eliminat **només** de templates | `document_existing` al DMS continua suportant PDF a `sign-document-router` |
| Variables DOCX: dual `[[key]]`+`{{key}}` durant transició | `[[key]]` = contenidor de contingut natiu DocuSeal; `{{key}}` (sense attrs) = compat amb templates antics que usaven el nostre format antic |
| `html_content` NO a `api.document_template_locales` VIEW | Evita inflate del catàleg al batch; càrrega lazy via `fetchLocaleDetail` |
| `generate_pdf` ocult per HTML | No hi ha conversió backend en aquest lliurable |
| Parsing rols HTML via DOMParser | Robustesa vs regex fràgil d'ordre d'atributs |
| Admin `signing_roles_schema`: JSON raw | Suficient per tècnics; TipTap és UX de tenant portal |

---

## V2 — Estat d'implementació

### Implementat (migracions `20260528000001_signing_v2_plan_size_locale_audit.sql` + `20260529000001_signing_v2_mark_reviewed_and_fixes.sql` + `20260529000002_signing_mark_reviewed_hardening.sql`)

| Funcionalitat | Estat | Notes |
|---------------|-------|-------|
| **Límit de mida dinàmic per pla** | ✅ **DONE** | `data.plans.max_html_template_size_kb` (free=200 KB, pro=500 KB, enterprise=0=il·limitat). Exposat a `api.plans`. Check enforced a `api.upsert_document_template_locale` (ERRCODE `check_violation`). |
| **Auditoria de canvis de plantilla** | ✅ **DONE** | Trigger `data.trg_audit_document_template_locales` (AFTER INSERT/UPDATE/DELETE). Accions: `TEMPLATE_LOCALE_CREATED`, `TEMPLATE_LOCALE_UPDATED`, `TEMPLATE_LOCALE_DELETED`. Payload: sha256 del `html_content` (mai el text sencer), mida en bytes, camps canviats. |
| **Bug fix `octet_length()`** | ✅ **DONE** | Migr. `20260529000001`. Reemplaça `length()` (caràcters) per `octet_length()` (bytes UTF-8 reals) a `api.upsert_document_template_locale` i al trigger d'audit. |
| **Hardening — mark-reviewed** | ✅ **DONE** | Migr. `20260529000001` + `20260529000002`. Columnes `reviewed_at`, `reviewed_by` a `data.signing_submissions`. RPC SECURITY DEFINER `api.mark_signing_submission_reviewed` (owner/manager, idempotent, audit únic, validació d'estat terminal backend, EXECUTE tancat a PUBLIC). Botó al `SigningSubmissionDetail` (visible si terminal + no revisat). Badge "Revisada" amb timestamp. |

### Pendent

| Funcionalitat | Dificultat | Notes |
|---------------|-----------|-------|
| **Hardening del Signing Center — cancel** | Mig | RPC + crida a DocuSeal `DELETE /api/submissions/:id` + botó amb confirmació. |
| **Hardening del Signing Center — resend** | Mig | Crida a DocuSeal `POST /api/submitters/:id/send_reminder` + botó per cada signant pendent. |
| **Retirada de `{{key}}` DOCX** | Fàcil (risc baix) | Script de migració de placeholders un cop estabilitzada la sintaxi `[[key]]`. |
| **Editor HTML avançat** | Mig | Taules, imatges, estils avançats al TipTap (v1 és editor bàsic). |
| **Variables dinàmiques complexes** | Difícil | Variables `source: 'computed'` (data avui, NIF empresa…). Canvi d'arquitectura a `variables_schema`. |
| **Aprovació en 2 passos** | Difícil | Workflow: draft → revisor aprova → signatura. Nou estat + notificacions. |
| **Conversió HTML → PDF** | Difícil | Edge function amb Puppeteer/wkhtmltopdf (infra Deno pesada). |
| **Plantilles condicionals** | Molt difícil | Mini-motor de templates al servidor. |
| **Signatura mòbil nativa** | Molt difícil | Integració amb app mòbil. |

### Bug obert (V1)
- `submitHtmlToDocuseal()` retorna 422 de DocuSeal (`template_ids or documents is required`). Cal verificar si `POST /submissions/html` és l'endpoint correcte per al pla DocuSeal EU, o adaptar el payload al format `POST /submissions` genèric amb `documents:[{html:'...'}]`.
