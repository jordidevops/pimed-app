# Pla Arquitectònic Clean Rewrite: LiquidJS + Docxtemplater

## 0. Decisió de base
Aquest pla assumeix entorn 100% dev/local i accepta trencament total de compatibilitat.
No es manté codi legacy, no es mantenen sintaxis antigues, no hi ha shim temporal.
Objectiu: arquitectura neta, única i predictible.

---

## 1. Arquitectura objectiu

### 1.1 Components nous
1. Template Context Builder
- Construeix un context jeràrquic únic per email, HTML i DOCX.
- Resol context_refs, variables manuals, globals i col·leccions.

2. Liquid Renderer
- Únic motor per plantilles de text, HTML i subjects.
- Responsable de condicionals, loops i interpolació.

3. Docx Renderer
- Únic motor DOCX amb Docxtemplater + PizZip.
- Delimitadors de contingut: [[ ... ]].

4. Template Validation Service
- Validació sintàctica estricta en guardar plantilles.
- Refús immediat de sintaxi antiga.

5. Frontend Preview Engine
- Mateixa semàntica que backend per evitar drift.
- LiquidJS per HTML/email preview.
- DOCX preview renderitzat des del resultat real del backend (no simulació regex).

### 1.2 Components eliminats
1. renderConditionals
2. renderTemplate
3. renderDocumentConditionals
4. substituteHtmlVariables
5. Parsers regex de condicions legacy a runtime

---

## 2. Decisions tècniques recomanades

1. Sintaxi oficial única
- Variables: {{ variable }}
- If: {% if cond %} ... {% endif %}
- Unless: {% unless cond %} ... {% endunless %}
- Loop: {% for item in list %} ... {% endfor %}

2. DOCX oficial
- Delimitadors de contingut: [[ variable ]]
- Loops DOCX: [[#items]] ... [[/items]]
- Tags interactius de DocuSeal mantenen format {{Field;role=Role;type=signature}} perquè no col·lideixen amb [[ ]].

3. Escaping i seguretat
- HTML: escape per defecte de variables textuals.
- Camps explícitament html_safe només quan origen és de sistema o administrador confiable.
- Prohibit injectar HTML cru per defecte en variables dinàmiques.

4. Contracte de context únic
- Prohibit mapes plans tipus Role.field.
- Només context nested object/list.

5. Cap compatibilitat legacy
- En desar plantilla: si detecta {{#if}}, {{/if}}, {{#unless}}, {{/unless}} es rebutja.
- Migració SQL converteix tot el que existeix abans del cutover.

---

## 3. Flux complet de renderitzat

### 3.1 Email queue
1. Carregar template i traducció activa
2. Construir context unificat
3. Renderitzar subject amb Liquid
4. Renderitzar body amb Liquid
5. Si hi ha layout, renderitzar layout amb content ja renderitzat
6. Enviar via Resend

### 3.2 Sign document amb source HTML
1. Carregar html_content
2. Construir context unificat
3. Renderitzar HTML amb Liquid
4. Enviar HTML final a DocuSeal

### 3.3 Generate only amb source HTML
1. Carregar html_content
2. Construir context unificat
3. Renderitzar HTML amb Liquid
4. Encapsular HTML5
5. Pujar al DMS

### 3.4 Sign document amb source DOCX
1. Descarregar DOCX
2. Construir context unificat
3. Renderitzar DOCX amb Docxtemplater
4. Enviar DOCX renderitzat a DocuSeal
5. DocuSeal només gestiona camps interactius i flux de signatures

### 3.5 Generate only amb source DOCX
1. Descarregar DOCX
2. Construir context unificat
3. Renderitzar DOCX amb Docxtemplater
4. Pujar DOCX final al DMS

---

## 4. Model de context recomanat

## 4.1 Forma canònica
- Context arrel amb objectes, llistes i globals.

Exemple:

```json
{
  "globals": {
    "today": "2026-06-02",
    "date": "2026-06-02",
    "year": "2026",
    "now": "2026-06-02T10:30:00.000Z"
  },
  "tenant": {
    "id": "...",
    "name": "APP"
  },
  "worker": {
    "id": "...",
    "full_name": "Ada Lovelace",
    "email": "ada@example.com"
  },
  "employees": [
    { "full_name": "Ada Lovelace", "role": "Engineer" },
    { "full_name": "Grace Hopper", "role": "Manager" }
  ],
  "input": {
    "custom_note": "Text manual"
  }
}
```

## 4.2 Regles
1. body.variables passa a input i no sobrescriu objectes estructurats
2. context_refs només defineix bindings d entitat, no claus finals de plantilla
3. globals sempre disponibles: globals.today, globals.date, globals.year, globals.now

---

## 5. Pla de migració per fases

## Fase A: Hard Reset de sintaxi
1. Congelar edició de plantilles
2. Migració SQL massiva de sintaxi antiga a Liquid
3. Eliminar funcions legacy del codi
4. Desbloquejar edició

## Fase B: Backend engine swap
1. Afegir liquidjs, docxtemplater, pizzip a supabase/functions/deno.json
2. Crear mòduls shared liquid-renderer i docx-renderer
3. Reescriure process-email-queue per Liquid
4. Reescriure sign-document-router per Liquid + Docxtemplater

## Fase C: Contracte de context nou
1. Migrar RequestBody i SignDocumentInput a context nested
2. Eliminar suport intern de claus planes
3. Ajustar resolveContextVariables perquè retorni objecte jeràrquic

## Fase D: Frontend i validació estricta
1. Preview amb Liquid real
2. Validació de sintaxi en editor
3. Error blocking si plantilla no és sintaxi oficial

## Fase E: Cutover net
1. Eliminar qualsevol resta de regex renderer
2. Tests d integració e2e
3. Documentació final d arquitectura

---

## 6. Tasques backend

1. Crear supabase/functions/_shared/liquid-renderer.ts
- API: renderLiquid(template, context, mode)
- mode: text o html (control de política d escape)

2. Crear supabase/functions/_shared/docx-renderer.ts
- API: renderDocx(bytes, context)
- Delimitadors [[ ]]
- Error mapping de Docxtemplater a missatges funcionals

3. Reescriure process-email-queue/index.ts
- Substituir tota la pipeline renderConditionals/renderTemplate
- Render de translations amb Liquid
- Render de layout amb context complet

4. Reescriure sign-document-router/index.ts
- Branch HTML: Liquid
- Branch DOCX sign/generate_only: Docxtemplater
- Eliminar neteja regex de placeholders no resolts

5. Polítiques d error
- Syntax error plantilla => 400 invalid_template_syntax
- Variable no resolta => 400 missing_variable
- DOCX render error => 400 invalid_docx_template

---

## 7. Tasques frontend

1. TemplateDetailPage preview
- Substituir regex preview per Liquid real
- Mantenir sandbox i sanitització del HTML final en preview

2. TemplateFormModal
- Parser de variables: suport explícit de loops Liquid i DOCX loops
- Feedback immediat de sintaxi invàlida

3. Signing editor UX
- Catàleg de paths del context nested
- Inserció guiada de snippets if/for

4. API client
- Ajustar tipus de SignDocumentInput perquè admeti context objecte jeràrquic
- Eliminar tipus que assumeixin mapes plans

---

## 8. Tasques base de dades

1. Migració SQL de contingut
- data.email_templates.subject_template
- data.email_templates.html_body_template
- data.email_templates.text_body_template
- data.email_templates.translations (subject/html/text)
- data.document_template_locales.html_content

2. Evolució variables_schema
- Admetre type: object, list, string, number, date, boolean
- Afegir metadata de path i entity_type

3. Evolució signing_roles_schema
- Reforçar relació rol -> context path
- Afegir ordre i constraints de coherència

4. Auditoria
- Registrar TEMPLATE_ENGINE_MIGRATED, TEMPLATE_VALIDATION_FAILED, DOCX_RENDER_FAILED a data.audit_logs

---

## 9. Riscos i mitigacions

1. Risc: render diferent entre backend i frontend
- Mitigació: mateix motor Liquid i tests snapshots compartits

2. Risc: regressió en templates traduïts
- Mitigació: migrar també translations JSONB, no només camps base

3. Risc: DOCX gran consumeix memòria
- Mitigació: límit 20MB per fitxer i error explícit

4. Risc: variables no resoltes en runtime
- Mitigació: validació en desar + validació pre-send + mode estricte

5. Risc: trencament per sintaxi antiga residual
- Mitigació: bloqueig dur al validator i script SQL de verificació post-migració

---

## 10. Exemples de codi

## 10.1 Liquid Renderer shared
```typescript
import { Liquid } from "npm:liquidjs@10"

const engine = new Liquid({
  strictVariables: true,
  strictFilters: true,
})

export async function renderLiquid(template: string, context: Record<string, unknown>) {
  return await engine.parseAndRender(template, context)
}
```

## 10.2 Docx Renderer shared
```typescript
import PizZip from "npm:pizzip@3"
import Docxtemplater from "npm:docxtemplater@3"

export function renderDocx(input: Uint8Array, context: Record<string, unknown>): Uint8Array {
  const zip = new PizZip(input)
  const doc = new Docxtemplater(zip, {
    delimiters: { start: "[[", end: "]]" },
    paragraphLoop: true,
    linebreaks: true,
  })
  doc.render(context)
  return doc.getZip().generate({ type: "uint8array" })
}
```

## 10.3 Validació de sintaxi antiga en guardar
```typescript
const legacyPattern = /\{\{#(if|unless)\b|\{\{\/(if|unless)\}\}/
if (legacyPattern.test(template)) {
  throw new Error("Legacy syntax no permesa. Usa Liquid: {% if %} ... {% endif %}")
}
```

---

## 11. Criteris de done

1. No existeix cap ús de renderConditionals/renderTemplate/substituteHtmlVariables al repo
2. Totes les plantilles guardades passen validador Liquid
3. Tots els fluxos sign i generate_only funcionen per HTML i DOCX
4. Preview frontend coincideix amb render backend per casos de test oficials
5. Tipus de frontend i backend alineats amb context nested

---

## 12. Comandes de verificació recomanades

1. Buscar restes de codi legacy
- rg "renderConditionals|renderTemplate|renderDocumentConditionals|substituteHtmlVariables"

2. Buscar sintaxi antiga en plantilles SQL seeds o fixtures
- rg "\{\{#if|\{\{#unless|\{\{/if\}\}|\{\{/unless\}\}"

3. Buscar camps amb contracte pla antic
- rg "Record<string, string>" apps/tenant-portal/src/features/signing supabase/functions/sign-document-router

---

## 13. Execució recomanada en aquest repo

Ordre pràctic:
1. Migració SQL de contingut
2. Swap backend process-email-queue
3. Swap backend sign-document-router
4. Refactor frontend preview/editor
5. End-to-end tests locals

---

## 14. Estat d implementacio (2026-06-02)

### 14.1 Fet
1. Fase A completada: migracio SQL inicial a Liquid
2. Fase B completada: `liquid-renderer`, `docx-renderer`, `context-builder`, email queue i sign router
3. Fase D completada funcionalment:
  - preview HTML amb Liquid al tenant portal (TemplateDetail + Orchestrator)
  - parser DOCX actualitzat
  - validacio Liquid unificada a frontend mitjancant helper compartit
4. Fase E completada: imports Deno (`liquidjs`, `pizzip`, `docxtemplater`) + test matrix E1 implementada i E2 executada (6/6 PASS)
5. Fix critic aplicat a `generate_only`: Docxtemplater nomes per DOCX; PDFs es conserven sense render
6. Guardrails afegits (post-cutover):
  - validacio client de sintaxi Liquid al guardar plantilles HTML de signing
  - validacio client de sintaxi Liquid al guardar plantilles email
  - migracio DB de sanejament + triggers de bloqueig de sintaxi legacy
7. Fase C completada (hard cut):
  - `SignDocumentInput` i `RequestBody` usen `context` nested
  - `DocumentOrchestrator` envia `context` com a contracte principal
  - `sign-document-router` usa `context.input` com a font unica de variables manuals
  - peticions amb `variables` es rebutgen amb `legacy_variables_not_supported`
8. Errors funcionals de render implementats al router:
  - `invalid_template_syntax`
  - `invalid_docx_template`
9. Neteja documental regex/Handlebars aplicada a la guia d email:
  - `docs/email/conditional-blocks-in-templates.md` actualitzada a sintaxi Liquid

### 14.2 Pendent (gap real)
1. Sense gaps oberts per Fase E en aquest pla.
2. Evidencia d execucio:
  - `docs/plans/evidence/2026-06-02-phase-e2-signing-matrix.md`

### 14.3 Aclariment de plans (0-7 vs A-E)
1. El pla antic 0-7 (`docs/signing/template-system-redesign-plan.md`) i aquest pla A-E no son equivalents 1:1
2. La referencia antiga "Docxtemplater per a Signing (futura)" queda superada per aquest pla: en A-E passa a Fase B i s ha implementat
3. Quan hi hagi discrepancia, aquest document A-E es la font de veritat per al clean rewrite

### 14.4 Checklist de tancament C/D/E
1. C1. Definir contracte canonic `context` nested al request de signing i deprecar `variables` planes
2. C2. Actualitzar `SignDocumentInput` i `RequestBody` a aquest contracte, amb adaptador temporal si cal
3. C3. Ajustar UI/orchestrator per construir i enviar `context` directament
4. D1. Unificar validacio Liquid en un servei compartit (client + server) amb mateixa semantica d error
5. D2. Afegir missatges d error funcionals estables (`invalid_template_syntax`, `missing_variable`, `invalid_docx_template`)
6. E1. Crear test matrix minim:
  - sign/html
  - sign/docx
  - sign/pdf
  - generate_only/html
  - generate_only/docx
  - generate_only/pdf
7. E2. Executar proves locals i deixar evidencia al PR (logs + captures de casos clau)

Aquest ordre minimitza finestres de desalineació perquè backend i dades queden alineats abans de canviar UX.
