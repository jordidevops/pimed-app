# Estudi i Pla d'Implementació: Creació de Plantilles amb IA (v2)

## 1. Visió General i Objectius

La generació de plantilles de documents (tant el contingut com els esquemes de variables i rols de signatura) és un procés feixuc per a l'usuari final. L'objectiu és introduir un **"Centre de Confecció amb IA"** dins del mòdul de Documents (`/documents/templates`) que permeti:
1. Oferir a l'usuari **prompts dinàmics** d'alta qualitat llestos per ser copiats a IAs externes (ChatGPT, Claude, etc.).
2. Proveir un mecanisme per **enganxar un JSON estructurat** generat per la IA.
3. Obtenir de cop la **generació d'un locale complet** (contingut HTML + rols + variables d'aquell idioma), amb facilitats per duplicar-ho a altres idiomes.
4. Incloure una **Vista Prèvia en temps real** perquè l'usuari pugui introduir dades de prova i validar l'aspecte de la plantilla abans de desar-la definitivament.

---

## 2. Model de dades: Rols i Variables són per `locale`, no globals

**Correcció important respecte a la v1:** `roles` i `variables` **no són globals a la plantilla**, sinó que **cada locale té el seu propi conjunt**. Quan s'edita/crea un locale (incloent-hi afegir un nou idioma a una plantilla que ja en té), es comença en blanc i cal introduir els tres blocs: Contingut, Rols de document i Variables de la plantilla, específics d'aquell locale.

Conseqüències per al disseny:

### 2.1. Format JSON (Contracte IA ↔ App) — ara per locale
Cada element de `locales` ha d'incloure els seus propis `roles` i `variables`:

```json
{
  "locales": [
    {
      "locale": "ca",
      "format": "html",
      "roles": [
        { "key": "empresa", "label": "Empresa / Contractador" },
        { "key": "treballador", "label": "Treballador" }
      ],
      "variables": [
        { "key": "salari_brut", "label": "Salari Brut Anual", "type": "number" },
        { "key": "data_inici", "label": "Data d'Inici", "type": "date" }
      ],
      "content": "<div class=\"contract\">... {{ salari_brut }} ...</div>"
    },
    {
      "locale": "es",
      "format": "html",
      "roles": [
        { "key": "empresa", "label": "Empresa / Contratante" },
        { "key": "treballador", "label": "Trabajador" }
      ],
      "variables": [
        { "key": "salari_brut", "label": "Salario Bruto Anual", "type": "number" },
        { "key": "data_inici", "label": "Fecha de Inicio", "type": "date" }
      ],
      "content": "<div class=\"contract\">... {{ salari_brut }} ...</div>"
    }
  ]
}
```

Notes:
- Les `key` de rols/variables (`empresa`, `salari_brut`...) han de ser **idèntiques entre locales** (només canvia el `label`, que és el text traduït). Això és el que permet la funcionalitat de "copiar i traduir" (secció 2.2) i la validació de coherència entre idiomes (secció 4.4).
- El prompt a la IA ha de demanar explícitament: mateixes `key` a tots els locales, només `label` i `content` varien.

### 2.2. UX de l'editor: "Copiar des d'un altre idioma"
Quan l'usuari afegeix un nou locale a una plantilla que ja en té algun:
- L'editor ofereix un botó/acció **"Copiar Rols i Variables des de... [selector de locale existent]"**.
- En copiar: es dupliquen `roles` i `variables` (mateixes `key`, mateixos `label` inicialment) i el `content` (com a punt de partida per traduir), de manera que l'usuari només hagi de:
  1. Traduir els `label` de rols i variables.
  2. Traduir el text del `content` (mantenint les etiquetes `{{ ... }}` intactes).
- Aquesta acció és independent del flux d'IA: també és útil quan l'usuari crea manualment un nou idioma sense passar pel Wizard.
- Si l'usuari ve del Wizard d'IA i el JSON ja porta `roles`/`variables` amb `key` coincidents amb un locale existent, l'app pot suggerir automàticament aquest "copiar des de" com a pre-validació (avisant si les `key` no coincideixen amb les d'un locale ja existent de la mateixa plantilla — vegeu 4.4).

---

## 3. Experiència d'Usuari (UX): El "Template AI Wizard"

S'afegeix un nou botó a l'editor de plantilles: **"Generar amb IA"**, disponible tant en creació de plantilla nova com en afegir/editar un locale concret. L'assistent (Wizard) té els següents passos:

### Pas 1: El Prompt de Generació i Injecció del Context
El sistema genera un text intel·ligent per copiar, **per al locale que s'està editant** (no per a tots els idiomes alhora, encara que es pugui demanar generar-ne diversos en una sola resposta si l'usuari ho vol).

El codi llegeix:
- Els **rols per defecte de sistema** configurats a `/settings/templates` (ex: `worker`, `manager`, `approver`, `hr_director`, `client_signatory`, etc.).
- Els **esquemes d'entitats** actius (camps de l'entitat `employee`, etc.).
- Si la plantilla ja té un altre locale, **els `roles`/`variables` (keys) d'aquell locale**, per demanar a la IA que reutilitzi les mateixes `key` (vegeu 2.2).
- Si el sistema de Blocs (Headers/Footers, pla relacionat) ja està actiu: instrucció explícita perquè la IA **no inclogui headers/footers de pàgina dins el `content`**, ja que es gestionen per separat (vegeu secció 4.1).

Exemple (resum del prompt generat):
> *"Actua com un expert legal i enginyer de programari. Necessito que creïs el contingut per a una plantilla de ___[EL TEU CAS, ex: Confidencialitat (NDA) d'Empleats]___, en l'idioma **[locale]**.
>
> Genera el contingut en format HTML utilitzant tags LiquidJS (`{{ variable }}`).
>
> IMPORTANT — Rols: si la plantilla requereix figures de Rols de Sistema, designa'ls amb la key exacta: `worker`, `manager`, `hr_manager`, `client_signatory`, `external_party`...
>
> IMPORTANT — Variables d'entitat: per al rol `worker` (tipus empleat), utilitza exactament aquestes variables: `{{ worker.full_name }}`, `{{ worker.document_id }}`, `{{ worker.phone }}`, `{{ worker.job_title }}`, `{{ worker.starts_on }}`, `{{ worker.status }}`.
>
> [Si existeix un altre locale] IMPORTANT — Aquesta plantilla ja té el locale `es` amb aquestes `roles`/`variables` (keys): [...]. Utilitza exactament les mateixes `key`, només tradueix els `label` i el contingut a `ca`.
>
> [Si sistema de blocs actiu] IMPORTANT — No incloguis cap capçalera ni peu de pàgina al contingut; es gestionen per separat mitjançant blocs reutilitzables.
>
> Retorna el resultat exclusivament en aquest format JSON, per al locale `[locale]`: [Esquema JSON d'un sol locale...]"*

### Pas 2: Importació
Camp de text gran on l'usuari fa *Paste* del JSON. Validació en cascada:
1. **Validació estructural (Zod):** forma del JSON, tipus de camps.
2. **Validació semàntica Liquid (dry-render):** es renderitza el `content` amb LiquidJS i dades dummy generades a partir de `variables`/`roles`; es capturen excepcions (tags mal tancats, etc.) i es mostren de forma comprensible.
3. **Validació de coherència variables declarades ↔ usades:** s'extreuen totes les referències `{{ ... }}` del `content` i es contrasten amb les `key` de `variables`/`roles` declarades. Es reporten:
   - Variables usades al `content` però no declarades.
   - Variables declarades però no usades (avís informatiu, no bloquejant).
4. **Si s'està afegint un locale a una plantilla existent:** comprovar que les `key` de `roles`/`variables` coincideixen amb les de l'altre/s locale/s ja existents (mateix conjunt de keys). Si no coincideixen, avisar clarament ("Aquest idioma defineix variables diferents de les de `es`. Vols continuar igualment, o prefereixes usar 'Copiar des de es' i traduir?").

Si tot és correcte, es parsegen Rols, Variables i Content en memòria per a aquest locale.

### Pas 3: El "Playground" (Vista Prèvia Integrada)
Un cop el JSON és vàlid, el sistema carrega una interfície similar al `DocumentOrchestrator` actual:
- A l'esquerra: formulari generat dinàmicament amb les variables i rols d'aquest locale, perquè l'usuari posi valors de prova (Dummy Data).
- A la dreta: panell que renderitza l'HTML (usant `LiquidJS` al navegador, sandboxed/sanititzat — vegeu 4.3) en temps real.
- Si la plantilla té més d'un locale: selector per alternar i comparar visualment amb els altres idiomes ja existents (no editables des d'aquí, només referència).

### Pas 4: Desar
En confirmar, l'App fa "Upsert" del locale concret que s'estava editant (content + roles + variables d'aquell locale). Si el locale ja existia i tenia contingut previ, mostrar **diff o confirmació explícita** abans de sobreescriure (vegeu 4.5).

---

## 4. Pla d'Implementació Tècnica

### Fase 1: Model d'Importació i Zod Schema (per locale)
1. Definir interfície TypeScript (`AILocaleJSON`) i esquema `Zod` per a **un sol locale** (content + roles + variables), no per al conjunt de la plantilla.
2. Lògica per detectar/llistar les `key` de `roles`/`variables` dels locales existents d'una plantilla, per injectar-les al prompt i per a la validació de coherència (3.2.4).
3. Lògica de "Copiar des de..." (2.2): duplicar roles/variables/content d'un locale origen a un de destí, mantenint `key` i `label` originals com a punt de partida per traduir.

### Fase 2: Component "AI Template Wizard"
1. Desenvolupar el component UI de l'assistent, parametritzat per `locale` objectiu (no multi-locale d'un sol cop, encara que el prompt pugui suggerir-ho com a text lliure).
2. Generador del *Prompt*: agafa context de sistema (rols, esquemes d'entitats), `key`s d'altres locales existents, i instrucció sobre blocs de headers/footers si el sistema corresponent està actiu.
3. Camp de *JSON Paste* amb la cadena de validacions de 3.2 (Zod → dry-render Liquid → coherència variables ↔ content → coherència entre locales).

### Fase 3: Vista Prèvia (Preview) a l'Editor
1. Desenvolupar `TemplatePreviewPlayground`, reaprofitable tant des del Wizard com des del `TemplateFormModal` estàndard (edició manual d'un locale).
2. Entrada: `content` HTML Liquid + JSON de dades dummy (generat a partir de `variables`/`roles` del locale).
3. Render: crida sincrònica a `liquidjs` al navegador; sortida **sanititzada** abans d'inserir-se al DOM/iframe (vegeu 4.3).
4. Botó "Generar dades de prova" que ompli el formulari amb valors dummy raonables segons el `type` de cada variable (`number`, `date`, `text`...).

### Fase 4: Coordinació amb el sistema de Blocs (Headers/Footers)
1. Si el sistema de Blocs (pla `header_footer_doc_templates_v2.md`) ja està implementat: el prompt generat (Pas 1) ha d'incloure la instrucció de no generar headers/footers de pàgina al `content`.
2. Si encara no està implementat: deixar el text del prompt com a placeholder/flag fàcil d'activar més endavant (constant o config centralitzada, no hardcoded al component).

### Fase 5: Flux DOCX (esquema sense `locales` HTML)
1. Mode específic del Wizard per a DOCX: la IA genera només `roles`+`variables` (per al locale corresponent), sense `content` HTML.
2. L'usuari puja el `.docx` amb les etiquetes `[[ variable ]]` corresponents.
3. Validació: extreure les etiquetes `[[ ... ]]` del `.docx` (Docxtemplater) i contrastar-les amb les `key` de `variables`/`roles` retornades per la IA (mateixa lògica que 3.2.3, adaptada a sintaxi DOCX).

### Fase 6 (Full de Ruta Futur): API Keys i Generació Nativa
Quan el tenant pugui introduir la seva API Key a `/settings/ai`, substituir el copiar-enganxar per una crida directa via Backend de Supabase, abocant el JSON (d'un locale) directament al Pas 3 (Playground). L'arquitectura (Fases 1-3) ja queda preparada per a això perquè el generador de prompt i el parsejador/validador estan desacoblats de la UI de copiar-enganxar.

---

## 5. Instruccions per a la IA que farà el Pla Detallat d'Implementació

1. **Confirmar el model de dades actual** de `roles`/`variables`: revisar si ja estan emmagatzemats per locale (ex: dins de cada registre de `document_template_locales` o equivalent) o si calen migracions per moure'ls d'un possible camp "global" a la plantilla cap a cada locale. Aquest és el canvi de model més crític respecte a la v1 del pla.
2. **Revisar `TemplateFormModal` actual**: com s'edita avui un locale (content, roles, variables) per determinar on encaixa el botó "Generar amb IA" i el botó "Copiar des de [locale]".
3. **Inventariar els Rols de Sistema** definits a `/settings/templates` i els esquemes d'entitats disponibles (`employee` i altres), i el format exacte en què s'exposen al codi, per construir el generador de prompt (Fase 2.2).
4. **Revisar l'estat del pla de Blocs** (`header_footer_doc_templates_v2.md`): si ja hi ha `block_type` `PAGE_HEADER`/`DOCUMENT_HEADER` implementats, activar la instrucció corresponent al prompt (Fase 4); si no, deixar-ho com a flag desactivat però present al codi.
5. **Extracció de variables Liquid del `content`**: decidir mecanisme (regex vs. parser/AST de LiquidJS) per a la validació de coherència (3.2.3). Revisar si ja existeix utilitat similar al projecte (per exemple, en el sistema de Blocs si ja s'ha implementat el parser de plantilles).
6. **Sanitització HTML**: revisar quina llibreria de sanitització (si n'hi ha alguna ja al projecte, ex: DOMPurify) s'utilitza en altres punts on es renderitza HTML d'origen extern, i reaprofitar-la per al Playground.
7. **Flux DOCX existent**: revisar com es pugen i parsegen plantilles `.docx` actualment (Docxtemplater) per determinar com extreure les etiquetes `[[ ... ]]` i implementar la validació de la Fase 5.
8. **Diff/confirmació de sobreescriptura (Pas 4 del Wizard)**: revisar si existeix algun patró de confirmació/diff ja usat en altres parts de l'editor de plantilles per a coherència de UX.
9. **Generació de dades dummy** per `type` de variable (`number`, `date`, `text`, etc.): definir valors per defecte per a cada tipus, revisant si l'enum de tipus de variable ja existeix i és complet o cal ampliar-lo.