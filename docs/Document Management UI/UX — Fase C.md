# Pla: Document Management UI/UX — Fase C

Millores integrals del flux de generació i gestió de documents: auto-selecció de locale, previsualitzacions HTML, selecció d'output correcta, navegació post-generació, nom de fitxer, filtratge de plantilles, redisseny del pas "Omple les variables" amb context i preview, i renomenat de "Rols de signatura" → "Rols de document".

---

## C1 — Auto-selecció del primer locale a `TemplateDetailPage`

**Fitxer:** `TemplateDetailPage.tsx`

- Quan `locales` carreguen i `activeTab === 'new-locale'`, establir `activeTab = locales[0]?.id`.
- Usar `useEffect([locales])` per sincronitzar.

---

## C2 — Fix `initialSource` a `TemplateDetailPage`

**Fitxers:** `TemplateDetailPage.tsx`, `useDocumentTemplateLocales.ts`

- Afegir `html_content` al `SELECT` del hook de locales (necessari per la preview del pas variables).
- Al cridar `setOrchestratorLocale(loc)`, passar `templateType` i `signingRolesSchema` a `initialSource`:
  ```ts
  initialSource={{
    kind: 'template_locale',
    localeId: loc.id!,
    localeName: loc.locale ?? '',
    variablesSchema: loc.variables_schema as ...,
    signingRolesSchema: loc.signing_roles_schema as ...,
    templateType: loc.mime_type?.includes('html') ? 'html' : 'docx',
    templateCategory: template?.category ?? null,
    htmlContent: loc.html_content ?? null,   // ← NOU
    templateName: template?.name ?? null,    // ← NOU per C5
  }}
  ```
- Afegir `htmlContent?: string | null` i `templateName?: string | null` a `OrchestratorSource` type.

---

## C3 — Pre-selecció correcta de l'outputAction per defecte

**Fitxer:** `DocumentOrchestrator.tsx`

- A l'`useEffect` de reset, canviar el default:
  - HTML → `'generate_html'`
  - DOCX → `'generate_docx'`
  - Desconegut → `'generate_docx'` (no mai `'generate_pdf'` per defecte)
- Fix idèntic al bloc "Nou document" del pas `done`.

---

## C4 — Botó "Veure document" al pas `done`

**Fitxer:** `DocumentOrchestrator.tsx`

- Si `result.document_id` existeix i `outputAction !== 'sign_docuseal'`, mostrar botó "Veure document" que faci `navigate('/documents/' + result.document_id)` + `onClose()`.
- Si el modal es tanca (`onClose`) amb `result.document_id` actiu i sense haver triat "Nou document", navegar automàticament al document generat.

---

## C5 — Nom de fitxer normalitzat (snake_case)

**Fitxer:** `DocumentOrchestrator.tsx`

- Afegir funció helper `toSnakeCase(name: string): string` que:
  - Converteix a minúscules.
  - Substitueix espais, guions i caràcters especials per `_`.
  - Elimina accents/diacrítics (via `normalize('NFD').replace(/\p{Mn}/gu, '')`).
- Al `handleProcess`, afegir `document_title: toSnakeCase(resolvedSource.templateName ?? 'document')` a l'`input` de `signingMutation`.

---

## C6 — Vista prèvia HTML a `TemplateDetailPage`

**Fitxer:** `TemplateDetailPage.tsx`

- Per locales `mime_type === 'text/html'`, dins la `TabsContent` afegir un `iframe` sandbox:
  - `srcDoc` = HTML amb variables substituïdes per `sample_values` i resaltades (`<mark style="background:#fef3c7">{{var}}</mark>`).
  - Alçada fixa (~300px), `overflow-y: auto`, classe `rounded-lg border`.
  - Estil responsive al contingut intern.
- **Rols de signatura:** al peu de la preview, badge per cada rol definit a `signing_roles_schema` mostrant el nom i tipus d'entitat.

---

## C7 — Vista prèvia HTML a `DocumentDetailPage`

**Fitxer:** `DocumentDetailPage.tsx`

- Afegir `isHtml = doc?.mime_type === 'text/html'`.
- Si `isHtml`:
  - Mostrar directament un `iframe` al body de la pàgina (no modal) amb `src` = signed URL del fitxer HTML guardat a Storage.
  - Alçada: `min-h-[400px] max-h-[70vh]` amb scrollbar.
  - El botó "Preview" passa a ser "Obrir en nova finestra" per documents HTML.

---

## C8 — Filtres, cercador i ordenació a `TemplatesPage`

**Fitxer:** `TemplatesPage.tsx`

- **Cercador** (`Input` amb icona Search): filtra per `name` i `description`.
- **Filtre per tipus** (botons toggle): `Tots | HTML | DOCX`.
- **Filtre per categoria** (botons toggle dinàmics des de les categories existents): `Tots | hr | legal | finance | ...`.
- **Ordenació** (select o botons): per `name` / `category` / data de creació.
- L'aplicació dels filtres és local (client-side) sobre el llistat ja carregat.
- Layout: buscador a l'esquerra, botons de tipus i categoria a la dreta, consistent amb `/documents`.

---

## C9 — Redisseny del pas `fill_variables` amb context i preview

**Fitxers:** `DocumentOrchestrator.tsx`, `useDocumentTemplateLocales.ts`

### 9a. Layout responsive (preview a dalt, formulari avall)
- Mòbil: preview HTML (col·lapsable amb botó) + formulari de variables.
- Desktop (`lg:`): opció de commutació entre "preview damunt" i "preview lateral" (2 columnes) via botó toggle.

### 9b. Context selector integrat al pas `fill_variables`
El `VarStep` s'amplia amb un panell de **context de dades** a sobre del formulari:

- **Si la plantilla té `signing_roles_schema`:**
  - Per cada rol (ordenat per `order`), un picker d'entitat (igual al que hi ha a `assign_contexts`) amb label del rol.
  - En seleccionar una entitat, s'auto-omplen les variables vinculades a aquell rol (`def.role === roleName`) amb heurística nom/email.
  - Els `context_refs` es construeixen aquí i es passen a `handleProcess`.

- **Si la plantilla NO té rols (generate-only):**
  - Un selector genèric "Context principal" amb tipus d'entitat configurable (employee / contact).
  - Variables sense rol s'omplen per heurística de nom de clau.

- Entitat seleccionada → badge mostrat, amb botó ✕ per netejar.
- Variables sense cap entitat assignada es mostren al formulari manual.

### 9c. Preview HTML en temps real
- `iframe` amb `srcDoc` calculat en temps real: `htmlContent` de la plantilla amb les variables de `variableValues` substituïdes.
  - Variables buides → resaltades en groc/taronja per indicar que falta valor.
  - Variables omplertes → mostrades amb el valor, sense `{{}}`.
- Col·lapsable: botó "Amagar/Mostrar vista prèvia" a dalt.
- **Només per plantilles HTML** (si `htmlContent` és null, la secció de preview no apareix).

### 9d. Validació
- Advertir (toast warning) si hi ha camps obligatoris buits en intentar avançar.
- **Bloquejar** "Continuar" si hi ha camps `required: true` sense valor.
- Si s'avança amb camps opcionals buits → substituir `{{var}}` per cadena buida (no deixar el tag).

### 9e. `context_refs` al `handleProcess` de `fill_variables`
- El context de rols escollit al pas `fill_variables` s'emmagatzema a l'estat `roleAssignments` (ja existent) o un nou estat `fillContextRefs`.
- Es passa a `handleProcess` si existeix, evitant necessitat del pas `assign_contexts` separat quan s'usa `generate_only`.

---

## C10 — Renomenar "Rols de signatura" → "Rols de document"

**Fitxers:** `TemplateFormModal.tsx`, `DocumentOrchestrator.tsx`, i18n strings

- **Label**: `'Rols de signatura'` → `'Rols de document'`
- **Descripció** (hint): 
  > `'Defineix els rols que intervenen en el document: determinen qui signa i quin tipus d\'entitat s\'usarà per omplir les variables associades a cada rol.'`
- **Columna "Signa"**: mantenir el checkbox `for_signing` però aclarir que si desmarcat és un "rol de context" (pre-omple variables però no signa).
- **Pas `assign_contexts`** al Orchestrator: títol → `'Assignar context per rol'` (ja és correcte), subtítol → millorar per indicar que els rols de context (non-signing) també s'han d'assignar per resoldre variables.
- **`scanDetectedRoles`**: `'Rols de document detectats:'`

---

## Ordre d'implementació recomanat

| # | Tasca | Complexitat |
|---|-------|-------------|
| 1 | C10 Renomenar rols | Baixa |
| 2 | C1 Auto-select locale | Baixa |
| 3 | C2 Fix initialSource + hook | Baixa |
| 4 | C3 outputAction default | Baixa |
| 5 | C5 Nom fitxer snake_case | Baixa |
| 6 | C4 Botó "Veure document" + nav | Baixa |
| 7 | C6 Preview HTML a TemplateDetailPage | Mitja |
| 8 | C7 Preview HTML a DocumentDetailPage | Mitja |
| 9 | C8 Filtres TemplatesPage | Mitja |
| 10 | C9 fill_variables redisseny complet | Alta |

---

## Fitxers a tocar (resum)

- `apps/tenant-portal/src/features/signing/components/TemplatesPage.tsx` (C8)
- `apps/tenant-portal/src/features/signing/components/TemplateDetailPage.tsx` (C1, C2, C6)
- `apps/tenant-portal/src/features/signing/components/DocumentOrchestrator.tsx` (C2, C3, C4, C5, C9, C10)
- `apps/tenant-portal/src/features/signing/components/TemplateFormModal.tsx` (C10)
- `apps/tenant-portal/src/features/signing/api/useDocumentTemplateLocales.ts` (C2)
- `apps/tenant-portal/src/features/documents/pages/DocumentDetailPage.tsx` (C7)
