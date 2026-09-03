# Estudi i Pla d'Implementació: Headers, Footers i Blocs en Plantilles de Documents (v2)

## 1. Visió General de la Proposta
L'objectiu és proveir a les plantilles de documents (tant **HTML** com **DOCX**) d'un sistema estandarditzat per incloure encapçalaments, peus de pàgina, i altres fragments de contingut reusable, de manera que:
1. S'utilitzin etiquetes especials a la plantilla on calgui (segons el tipus de bloc, veure secció 2.3).
2. Es puguin crear i gestionar "Blocs de Contingut" de forma centralitzada al tenant o site.
3. Es permeti seleccionar i desar l'assignació d'aquests blocs directament a la pantalla d'edició/ús de la plantilla de document.
4. Aquests blocs de contingut també tinguin accés a dades globals (com el nom del tenant o del site).

**Decisió presa:** es descarta el patró de "layout wrapper" (a l'estil plantilles d'email). Les plantilles HTML continuen sent documents HTML5 complets i vàlids (`<!DOCTYPE html>`...`<body>`), no fragments.

---

## 2. Tipus de Bloc: distinció fonamental

El punt més important d'aquest pla és que **"header/footer" no és un concepte únic**, sinó dos mecanismes diferents segons l'àmbit:

### 2.1. `PAGE_HEADER` / `PAGE_FOOTER` — repetit a cada pàgina
- És **metadata de la pàgina**, no contingut del flux del document.
- **HTML/PDF:** es renderitza amb LiquidJS per separat i es passa com `header.html`/`footer.html` a Gotenberg (paràmetres natius, no es concatena al `<body>`). Gotenberg/Chromium s'encarrega de repetir-lo a cada pàgina, independentment d'on caiguin els salts de pàgina del contingut.
- **DOCX:** correspon directament al header/footer natiu del fitxer Word (ja és per-pàgina per definició). Només blocs `format: TEXT` (limitació de Docxtemplater base).
- **L'etiqueta NO va dins el cos de la plantilla HTML.** Es selecciona des de la UI de la plantilla (toggle + selector de bloc), i l'app s'encarrega d'injectar-ho al mecanisme corresponent.
- **Gestió de marges (important):** cal reservar `marginTop`/`marginBottom` a Gotenberg perquè el header/footer no se superposi al contingut. Definir una alçada estàndard (ex: ~80px) i exigir que el contingut del bloc hi encaixi (CSS `overflow:hidden`, limitació de línies).

### 2.2. `DOCUMENT_HEADER` / `DOCUMENT_FOOTER` — un sol cop, dins el flux
- És **contingut normal del body**, apareix una vegada allà on l'autor de la plantilla decideixi.
- **HTML:** l'autor de la plantilla escriu `{{ document_header }}` / `{{ document_footer }}` dins el seu HTML, on vulgui. Substitució LiquidJS normal.
- **DOCX:** sense equivalent net (no té sentit fora d'un header/footer de secció natiu); es manté fora d'abast per DOCX.

### 2.3. Resum etiquetes vs. selecció UI

| Tipus de bloc | Etiqueta a la plantilla? | Mecanisme |
|---|---|---|
| `PAGE_HEADER` / `PAGE_FOOTER` (HTML) | No — selecció via UI | Paràmetre `header.html`/`footer.html` a Gotenberg |
| `PAGE_HEADER` / `PAGE_FOOTER` (DOCX) | Sí, dins header/footer natiu del .docx (`[[ header_block ]]`) | Docxtemplater, només blocs `TEXT` |
| `DOCUMENT_HEADER` / `DOCUMENT_FOOTER` (HTML) | Sí (`{{ document_header }}`) | LiquidJS, body normal |
| `CUSTOM` (HTML) | Sí (`{{ custom_block_xxx }}`) | LiquidJS, body normal |

### 2.4. Avís de possible duplicació
Quan l'usuari activa `PAGE_HEADER`/`PAGE_FOOTER` per una plantilla que ja conté `{{ document_header }}`/`{{ document_footer }}`, mostrar un avís no bloquejant (poden coexistir, però el cas habitual és confusió):
> "Aquesta plantilla ja inclou un encapçalament/peu de document. Activar també una capçalera/peu de pàgina farà que aparegui un element addicional a cada pàgina del PDF. Vols continuar?"

---

## 3. Viabilitat segons el Format (resum)

### 3.1. HTML (LiquidJS + Gotenberg)
- **Viabilitat:** Molt alta per a tots els tipus de bloc (`PAGE_*`, `DOCUMENT_*`, `CUSTOM`), formats `HTML` o `TEXT`.
- Els blocs `HTML` s'han de renderitzar amb LiquidJS (amb context global) abans d'injectar-se, perquè les etiquetes globals (`{{ tenant.name }}`) s'hi interpretin.

### 3.2. DOCX (Docxtemplater + Gotenberg/LibreOffice)
- **Viabilitat:** Mitjana-alta, amb limitació clara.
- Només es contemplen `PAGE_HEADER`/`PAGE_FOOTER`, i només blocs de `format: TEXT` (Docxtemplater base substitueix per text pla, no HTML ni subdocuments).
- Contingut ric (taules, imatges) a capçaleres DOCX: fora d'abast d'aquest pla — s'ha de dissenyar nativament al document Word base, usant etiquetes globals (`[[ tenant.name ]]`) directes sense passar per "Blocs".
- La UI de mapeig de blocs per a plantilles DOCX només mostra `PAGE_HEADER`/`PAGE_FOOTER` amb blocs `format: TEXT`.

---

## 4. Arquitectura del Sistema de Blocs

### 4.1. Model de Dades

1. **`document_content_blocks`** (Nova taula):
   - `id` (uuid)
   - `tenant_id` (uuid)
   - `name` (string) — Nom descriptiu ("Peu legal estàndard").
   - `block_type` (enum) — `PAGE_HEADER`, `PAGE_FOOTER`, `DOCUMENT_HEADER`, `DOCUMENT_FOOTER`, `CUSTOM`.
   - `format` (enum) — `HTML`, `TEXT`.
   - `content` (text) — El contingut pròpiament dit.
   - `created_at`, `updated_at`.
   - RLS per `tenant_id`.

2. **`document_templates`** (Modificació):
   - Afegir columna `default_block_mapping` (jsonb). Estructura suggerida:
     ```json
     {
       "page_header": "uuid-del-bloc",
       "page_footer": "uuid-del-bloc",
       "document_header": "uuid-del-bloc",
       "document_footer": "uuid-del-bloc",
       "custom_block_xxx": "uuid-del-bloc"
     }
     ```
   - Les claus disponibles depenen del `format` de la plantilla (HTML vs DOCX) i de quines etiquetes `{{ document_header }}` / `{{ custom_block_xxx }}` detecta el parser dins la plantilla (vegeu Fase 3).

### 4.2. Gestió de Variables Globals (Context Builder)
A `supabase/functions/_shared/context-builder.ts`:
- Injectar automàticament un sub-objecte `tenant` i/o `site` per a totes les operacions de generació (`name`, `address`, `logo_url`, etc.), disponible tant per a la plantilla principal com per al pre-renderitzat dels blocs.

---

## 5. Pla d'Implementació Pas a Pas

### Fase 1: Model de Dades i Variables Globals
1. **Migracions SQL:**
   - Crear taula `document_content_blocks` amb l'enum `block_type` de 5 valors (secció 4.1) i RLS per `tenant_id`.
   - Afegir camp JSONB `default_block_mapping` a `document_templates`.
2. **Context Builder Backend:**
   - Assegurar que `tenant`/`site` siguin accessibles tant pel renderitzat principal com pel pre-renderitzat de blocs.

### Fase 2: Gestió UI de Blocs (Settings)
1. Nou apartat `/settings/documents` → "Blocs de Contingut".
2. Taula de blocs disponibles, filtrable per `block_type` i `format`.
3. Modal/Pàgina per crear/editar: Editor Richtext/Codi HTML per blocs `HTML`, Textarea per blocs `TEXT`.

### Fase 3: Edició i Selecció a les Plantilles de Documents
1. **Parsing de la plantilla** (nou pas, important): en obrir `TemplateFormModal`/`TemplateDetailPage`, analitzar el contingut de la plantilla per detectar quines etiquetes `{{ document_header }}`, `{{ document_footer }}`, `{{ custom_block_xxx }}` (HTML) o `[[ header_block ]]`/`[[ footer_block ]]` (DOCX, dins headers/footers natius) hi són presents.
2. **UI d'assignació de blocs**, condicionada per format de plantilla i resultat del parsing:
   - HTML: mostrar sempre selectors per `PAGE_HEADER`/`PAGE_FOOTER` (independents del contingut). Mostrar selectors per `DOCUMENT_HEADER`/`DOCUMENT_FOOTER`/`CUSTOM` només si la plantilla conté l'etiqueta corresponent.
   - DOCX: mostrar només `PAGE_HEADER`/`PAGE_FOOTER`, filtrant blocs a `format: TEXT`.
   - Implementar l'avís de duplicació descrit a la secció 2.4.
3. Desar el mapeig a `default_block_mapping`.

### Fase 4: Integració de Renderitzat
1. **Lectura del mapeig:** a `sign-document-router.ts`, llegir `default_block_mapping` i recuperar el `content` dels blocs referenciats.
2. **Pre-renderitzat dels blocs:** cada bloc (`HTML` o `TEXT`) es processa amb LiquidJS i el context global (`tenant`, `site`, etc.) abans d'usar-se.
3. **Bifurcació segons `block_type`:**
   - `DOCUMENT_HEADER`/`DOCUMENT_FOOTER`/`CUSTOM` (HTML) → s'injecten al `context` com variables normals (`context.document_header = "..."`) i LiquidJS les substitueix dins el body com de costum.
   - `PAGE_HEADER`/`PAGE_FOOTER` (HTML) → NO van al `context` del body; es passen com paràmetres separats (`header.html`/`footer.html`) a la crida de Gotenberg, juntament amb `marginTop`/`marginBottom` adequats.
   - `PAGE_HEADER`/`PAGE_FOOTER` (DOCX) → substitució `[[ ... ]]` dins els headers/footers natius via Docxtemplater (text pla).

---

## 6. Cas d'Ús: Exemple de Flux de Treball

1. L'usuari va a "Blocs de Contingut" i crea el bloc "Peu Legal DOCX", `block_type: PAGE_FOOTER`, `format: TEXT`, contingut: `Document generat per [[ tenant.name ]]. Tots els drets reservats.`
2. Descarrega la seva plantilla de Word i afegeix al peu de pàgina natiu l'etiqueta `[[ footer_block ]]`.
3. Al Tenant Portal, a "Assignació de blocs" de la plantilla, mapeja `page_footer` → "Peu Legal DOCX".
4. En processar el document, l'API construeix el context amb la informació del tenant, pre-renderitza el bloc i el substitueix dins el footer natiu del .docx.
5. El fitxer Word resultant incorpora el text legal amb el nom del tenant al peu de cada pàgina.

**Exemple addicional (HTML, PAGE_HEADER + DOCUMENT_HEADER coexistint):**
1. La plantilla HTML conté `{{ document_header }}` al principi del body (ex: un títol/logo gran de portada).
2. L'usuari també activa `PAGE_HEADER` i selecciona un bloc petit amb el nom del tenant.
3. En renderitzar: el `document_header` s'injecta una vegada al body via LiquidJS; el `page_header` es renderitza i s'envia per separat a Gotenberg, apareixent a cada full del PDF.
4. La UI mostra l'avís de la secció 2.4 abans de desar aquesta combinació.

---

## 7. Instruccions per a la IA que farà el Pla Detallat d'Implementació

Aquesta secció és per a la persona/IA amb accés al codi, que ha de convertir aquest pla en tasques concretes. Coses a revisar i decidir explícitament:

1. **Inventariar l'enum actual** de `block_type` (si ja existeix algun camp similar) i confirmar el pas a 5 valors (`PAGE_HEADER`, `PAGE_FOOTER`, `DOCUMENT_HEADER`, `DOCUMENT_FOOTER`, `CUSTOM`). Revisar impacte en dades existents si ja hi ha blocs creats amb l'enum antic (`HEADER`/`FOOTER`/`CUSTOM`).
2. **Revisar la crida actual a Gotenberg** (`liquid-renderer` o equivalent): comprovar quins paràmetres ja s'envien (`marginTop`, `marginBottom`, `header.html`, `footer.html`) i si cal afegir-los de zero o ja existeix infraestructura parcial.
3. **Definir l'alçada estàndard** per `PAGE_HEADER`/`PAGE_FOOTER` en HTML (marges Gotenberg) i com es comunica aquesta restricció a l'usuari que edita el bloc (preview amb mida fixa? avís de truncament?).
4. **Implementar el parser de plantilles** (Fase 3.1): definir si es fa amb regex simple sobre el codi font de la plantilla o aprofitant el parser/AST de LiquidJS ja disponible. Revisar on viu actualment el codi de les plantilles (`document_templates.content` o similar) per saber des d'on s'ha de llegir.
5. **Docxtemplater:** confirmar la versió actual i si ja suporta mòduls addicionals (per exemple per a contingut ric en headers). Si no, documentar explícitament que queda fora d'abast i per què (limitació de la versió base).
6. **`sign-document-router.ts`:** mapejar el flux actual de construcció del `context` i identificar el punt exacte on cal:
   - afegir `tenant`/`site` (Fase 1),
   - resoldre `default_block_mapping` i pre-renderitzar blocs (Fase 4),
   - bifurcar entre injecció al `context` (DOCUMENT_*/CUSTOM) vs. paràmetres Gotenberg (PAGE_* en HTML) vs. Docxtemplater natiu (PAGE_* en DOCX).
7. **RLS i permisos:** seguir el patró existent d'altres taules per `tenant_id`; revisar si cal afegir-hi `site_id` també (el pla original esmenta "tenant o site" com a àmbit dels blocs — cal decidir si els blocs són per tenant, per site, o ambdós, i com es resol la precedència).
8. **UI:** revisar components existents (`TemplateFormModal`, `TemplateDetailPage`) per determinar si el panell d'assignació de blocs hi cap com a secció nova o necessita un nou tab/pàgina.
9. **Migració de dades:** si ja hi ha plantilles en producció amb headers/footers "hardcoded" al contingut, valorar si cal una eina/script de migració assistida cap al nou sistema de blocs, o si es manté retrocompatibilitat indefinida.