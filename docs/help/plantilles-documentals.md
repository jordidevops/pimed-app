# Plantilles documentals

Guia completa del sistema de plantilles: formats suportats, esquemes JSON, sintaxi d'etiquetes i funcionament de l'auto-omplerta.

---

## 1. Visió general

El sistema suporta dos tipus de plantilles:

| Tipus | Extensió | Ús recomanat |
|-------|----------|--------------|
| **DOCX** | `.docx` | Contractes, cartes i documents formals amb format ric (taules, capçaleres, peus de pàgina, signes de puntuació precises). El servidor omple les variables i genera el PDF final. |
| **HTML** | (editor visual) | Documents senzills, informes interns, confirmacions. L'editor visual permet previsualitzar en temps real mentre s'omplen les variables. |

Una **plantilla** pot tenir múltiples **locales** (ca, es, en…). Cada locale conté:
- El fitxer DOCX o el contingut HTML.
- El **`variables_schema`**: defineix les variables que l'usuari ha d'omplir en generar el document.
- El **`signing_roles_schema`**: defineix els rols que intervenen (qui signa, de quin tipus d'entitat es seleccionarà).

---

## 2. `variables_schema` — Format JSON

### Estructura

```json
{
  "clau_variable": {
    "type": "string",
    "label": "Etiqueta visible",
    "required": true,
    "role": "NomRol",
    "order": 1
  }
}
```

### Camps

| Camp | Tipus | Obligatori | Valors possibles | Descripció |
|------|-------|:----------:|-----------------|------------|
| `type` | string | ✅ | `"string"` \| `"date"` \| `"number"` | Tipus de dada de la variable. Determina el control del formulari (text, datepicker o camp numèric). |
| `label` | string | ❌ | Qualsevol text | Etiqueta que es mostra al formulari de generació. Si s'omet, es mostra la clau. |
| `required` | boolean | ❌ | `true` \| `false` (default: `false`) | Si `true`, no es pot generar el document sense omplir aquest camp. |
| `role` | string | ❌ | Nom d'un rol definit a `signing_roles_schema` | Clau de l'**enfocament schema-based**: vincla la variable al rol indicat. Quan l'usuari assigna una entitat a aquell rol, la variable s'omple automàticament. Sense `role`, la variable és un camp manual sense auto-omplerta. Veure §5 i §6. |
| `order` | number | ❌ | Enter positiu (default: ordre d'inserció) | Ordre d'aparició al formulari de generació. |

### Convenció de noms: clau = camp de l'entitat

Per aprofitar l'**auto-omplerta completa**, la clau de la variable ha de coincidir exactament amb el nom del camp de l'entitat a la base de dades. Exemples:

| Clau variable | Entitat | Camp DB | Auto-omplerta |
|---------------|---------|---------|:-------------:|
| `full_name` | employee | `employees.full_name` | ✅ |
| `email` | employee / contact | `*.email` | ✅ |
| `job_title` | employee | `job_positions.name` (via `employees.job_position_id`; l'àlies de plantilla `job_title` continua funcionant) | ✅ |
| `document_id` | employee | `employees.document_id` | ✅ |
| `phone` | employee | `employees.phone` | ✅ |
| `display_name` | contact | `contacts.display_name` | ✅ |

Si la clau és arbitrària (p.e. `nom_empresa`), l'auto-omplerta usa heurístiques per decidir quin valor posar (si conté "email" → email, altrament → nom).

### Exemple complet

```json
{
  "full_name": {
    "type": "string",
    "label": "Nom complet del treballador",
    "required": true,
    "role": "Treballador",
    "order": 1
  },
  "job_title": {
    "type": "string",
    "label": "Lloc de treball",
    "required": false,
    "role": "Treballador",
    "order": 2
  },
  "email": {
    "type": "string",
    "label": "Email corporatiu",
    "required": true,
    "role": "Treballador",
    "order": 3
  },
  "data_incorporacio": {
    "type": "date",
    "label": "Data d'incorporació",
    "required": true,
    "order": 4
  }
}
```

---

## 3. `signing_roles_schema` — Format JSON

### Estructura

```json
{
  "NomRol": {
    "entity_type": "employee",
    "label": "Etiqueta visible",
    "order": 1,
    "for_signing": true
  }
}
```

### Camps

| Camp | Tipus | Obligatori | Valors possibles | Descripció |
|------|-------|:----------:|-----------------|------------|
| `entity_type` | string | ✅ | `"employee"` \| `"contact"` \| `"user"` \| `"person"` \| `"site"` \| `"asset"` \| `"tenant"` | Tipus d'entitat que s'associarà a aquest rol. Determina el selector que apareix al formulari ("Cercar empleat", "Cercar contacte"…) i els camps disponibles per a l'auto-omplerta. |
| `label` | string | ❌ | Qualsevol text | Etiqueta visible al formulari ("Treballador", "Responsable de RRHH"…). Si s'omet, s'usa el nom del rol. |
| `order` | number | ❌ | Enter positiu | Ordre d'aparició al formulari. |
| `for_signing` | boolean | ❌ | `true` \| `false` (default: `true`) | Si `true`, el rol és un signant actiu (apareixerà al flux de signatura Docuseal). Si `false`, actua com a **context de dades**: pre-omple variables però no firma el document. Els tipus `site`, `asset` i `tenant` no poden signar (sempre `false`). |

### Tipus d'entitat i camps disponibles per a auto-omplerta

| `entity_type` | Camps suggerits |
|---------------|----------------|
| `employee` | `full_name`, `email`, `job_title`, `document_id`, `phone` |
| `contact` | `display_name`, `email`, `phone`, `company_name` |
| `user` | `full_name`, `email` |
| `person` | `full_name`, `email` (empleat o contacte indistintament) |
| `site` | `name`, `address`, `city` |
| `asset` | `name`, `serial_number`, `model` |
| `tenant` | `name`, `tax_id` |

### Exemple complet

```json
{
  "Treballador": {
    "entity_type": "employee",
    "label": "Treballador",
    "order": 1,
    "for_signing": true
  },
  "Empresa": {
    "entity_type": "tenant",
    "label": "Empresa (context)",
    "order": 2,
    "for_signing": false
  }
}
```

---

## 4. Guia de plantilles DOCX

Les plantilles DOCX admeten **dos enfocaments per a les variables** (igual que les plantilles HTML; veure §5 per a la comparativa detallada):

### Variables de text path-based: `[[Rol.camp]]`

Sintaxi per inserir dades d'una entitat associada a un rol. **El servidor resol el valor directament des de la base de dades**, sense que l'usuari hagi d'omplir cap camp.

```
[[Treballador.full_name]]
[[Treballador.document_id]]
[[Treballador.job_title]]
[[Empresa.name]]
[[Empresa.tax_id]]
```

- `Rol` ha de coincidir exactament (majúscules/minúscules) amb la clau a `signing_roles_schema`.
- `camp` ha de ser un camp existent a la vista de l'entitat (p.e. `employees.full_name`).
- **No requereix cap entrada a `variables_schema`**; el servidor la resol automàticament via la BD.
- Equivalent a `{{Rol.camp}}` en HTML, però amb dobles claudàtors i resolució server-side.

### Variables schema-based: `{{variable_key}}`

Sintaxi per a variables que l'usuari veurà al formulari de generació (amb pre-omplerta opcional):

```
{{data_inici}}
{{salari_anual}}
{{full_name}}
```

- Requereix una entrada a `variables_schema` per a cada clau.
- Si la variable té `"role"` definit, s'omple automàticament quan l'usuari assigna l'entitat.
- L'usuari pot revisar i editar el valor abans de generar.
- Ideal per a dades que depenen de la decisió de l'usuari (dates, imports, textos lliures).

### Camps de signatura: `{{Camp;role=Rol;type=TIPUS}}`

Sintaxi per inserir zones interactives de signatura:

```
{{Firma;role=Treballador;type=signature}}
{{Inicials;role=Treballador;type=initials}}
{{DataSignatura;role=Treballador;type=date}}
{{TextLliure;role=Treballador;type=text}}
{{Casella;role=Treballador;type=checkbox}}
```

| Paràmetre | Descripció |
|-----------|-----------|
| `Camp` | Nom del camp (lliure, es mostra a l'interfície de signatura). |
| `role=NomRol` | Rol que ha de completar aquest camp. Ha de coincidir amb `signing_roles_schema`. |
| `type=TIPUS` | Tipus de camp interactiu. |

**Valors vàlids per a `type`:** `signature`, `initials`, `date`, `text`, `number`, `checkbox`, `image`.

### Exemple de document DOCX

```
Contracte de treball

Dades del treballador:
Nom: [[Treballador.full_name]]
DNI/NIE: [[Treballador.document_id]]
Lloc de treball: [[Treballador.job_title]]

Empresa: [[Empresa.name]]
CIF: [[Empresa.tax_id]]

Signatura del treballador:
{{Firma;role=Treballador;type=signature}}
Data: {{DataFirma;role=Treballador;type=date}}
```

---

## 5. Guia de plantilles HTML

Les plantilles HTML admeten **dos enfocaments per inserir dades d'entitat**: schema-based i path-based. Tots dos es poden combinar en la mateixa plantilla.

---

### Enfocament A — Schema-based: `{{variable_key}}`

La variable **existeix al `variables_schema`** i l'usuari la veu al formulari de generació. Si té `"role"` definit, es pre-omple automàticament quan l'usuari assigna una entitat al rol corresponent, però pot editar-la.

```html
<p>Benvolgut/da <strong>{{full_name}}</strong>,</p>
<p>El teu lloc de treball és: {{job_title}}</p>
<p>Data d'incorporació: {{data_incorporacio}}</p>
```

Schema corresponent:
```json
{
  "full_name":         { "type": "string", "label": "Nom complet",       "required": true,  "role": "Treballador", "order": 1 },
  "job_title":         { "type": "string", "label": "Lloc de treball",   "required": false, "role": "Treballador", "order": 2 },
  "data_incorporacio": { "type": "date",   "label": "Data incorporació", "required": true,                        "order": 3 }
}
```

- La clau ha de coincidir exactament amb l'entrada a `variables_schema`.
- Variables sense `role` al schema s'omplen manualment (sense auto-omplerta).
- La previsualització en temps real mostra el valor a mesura que l'usuari l'introdueix; els camps buits es marquen en groc.

---

### Enfocament B — Path-based: `{{Rol.camp}}`

La variable **no existeix al `variables_schema`**. El sistema la resol automàticament a partir de l'entitat assignada al rol indicat. L'usuari **no veu cap camp** per a ella al formulari.

```html
<p>Jo, <strong>{{Treballador.full_name}}</strong>, em comprometo a...</p>
<p>DNI/NIE: <strong>{{Treballador.document_id}}</strong></p>
<p>Lloc de treball: <strong>{{Treballador.job_title}}</strong></p>
```

- `Rol` ha de coincidir exactament amb la clau a `signing_roles_schema`.
- `camp` ha de ser un camp de l'entitat (`full_name`, `email`, `job_title`, `document_id`, `phone`…).
- **Cap entrada a `variables_schema`** és necessària per a aquestes variables.
- Equivalent a `[[Rol.camp]]` en DOCX, però amb dobles claus i resolució client-side.
- A la previsualització, apareixerà en groc fins que l'usuari assigni l'entitat al pas «Assignar contextos».

Camps resolts per a cada tipus d'entitat:

| `entity_type` | `camp` disponibles |
|---------------|-------------------|
| `employee` | `full_name`, `email`, `job_title`, `document_id`, `phone` |
| `contact` | `display_name`, `email`, `phone`, `company_name` |
| `user` | `full_name`, `email` |
| `site` | `name`, `address`, `city` |
| `asset` | `name`, `serial_number`, `model` |
| `tenant` | `name`, `tax_id` |

---

### Comparativa A vs B

| Característica | **A — Schema-based** `{{var}}` | **B — Path-based** `{{Rol.camp}}` |
|---|---|---|
| Cal definir al `variables_schema` | ✅ Sí | ❌ No |
| L'usuari veu el camp al formulari | ✅ Sí (pre-omplert) | ❌ No |
| L'usuari pot editar el valor | ✅ Sí | ❌ No |
| Camp `"role"` al schema | ✅ Per a auto-omplerta | — (no aplica) |
| Resolució | Client-side (auto-fill) | Client-side (des del role assignment) |
| Equivalent en DOCX | `{{variable_key}}` al .docx | `[[Rol.camp]]` al .docx |
| Ideal per a | Dates, imports, textos que l'usuari confirma | Nom, DNI, lloc de treball que vénen sempre de l'entitat |
| Previsualització HTML | ✅ Immediatament | ⏳ Quan s'assigna l'entitat |

**Regla d'or**: usa **path-based** quan el valor ve 100% de l'entitat i l'usuari no hauria de poder canviar-lo; usa **schema-based** quan el valor necessita confirmació o pot ser editat.

---

### Camps de signatura en HTML

L'editor visual insereix camps especials com a elements HTML personalitzats:

```html
<signature-field role="Treballador"></signature-field>
<date-field role="Treballador"></date-field>
<text-field role="Treballador"></text-field>
<initials-field role="Treballador"></initials-field>
<checkbox-field role="Treballador"></checkbox-field>
```

Usa els botons de la barra d'eines de l'editor per inserir-los (no cal escriure l'HTML manualment).

### Previsualització en temps real

Al formulari de generació, qualsevol variable omplerta es reflecteix immediatament a la previsualització. Les variables pendents d'omplir es marquen en groc per facilitar-ne la detecció.

### Exemple de plantilla HTML (enfocaments A+B combinats)

Plantilla d'avançament de nòmina: el nom s'insereix automàticament (B), i l'import i el motiu els confirma l'usuari (A):

```html
<h1>Sol·licitud d'Avançament de Nòmina</h1>
<p>
  El/la treballador/a <strong>{{Treballador.full_name}}</strong>
  sol·licita un avançament de <strong>{{import_sol}} EUR</strong>.
</p>
<p>Motiu: {{motiu}}</p>
<p>Signa per aprovar:</p>
<signature-field role="Director_RRHH"></signature-field>
```

Schema de variables corresponent (sense entrada per a `full_name`, ja que és path-based):
```json
{
  "import_sol": { "type": "number", "label": "Import sol·licitat (EUR)", "required": true,  "order": 1 },
  "motiu":      { "type": "string", "label": "Motiu",                   "required": false, "order": 2 }
}
```

---

## 6. Auto-omplerta: com funciona

L'auto-omplerta s'aplica als **camps schema-based** (`{{variable_key}}` amb `"role"` definit al schema). Quan l'usuari assigna una entitat a un rol, el sistema resol automàticament totes les variables vinculades a aquell rol. L'ordre de resolució per a cada variable és:

```
1. variable_key === 'email'
   → usa l'email de l'entitat seleccionada

2. variable_key === 'full_name' o 'display_name'
   → usa el nom de l'entitat seleccionada

3. variable_key coincideix amb un camp de l'entitat (job_title, document_id, phone…)
   → usa el valor exacte d'aquell camp

4. Heurística: variable_key conté "email", "correu" o "mail"
   → usa l'email

5. Qualsevol altre cas
   → usa el nom de l'entitat
```

> Les variables **path-based** (`{{Rol.camp}}` en HTML, `[[Rol.camp]]` en DOCX) **no segueixen aquest flux**: es resolen directament des del role assignment sense passar pel schema.

**Prioritat**: mai s'esborren valors que l'usuari ja ha introduït manualment. L'auto-omplerta només omple camps buits.

### Requisits per a l'auto-omplerta completa

1. La variable ha de tenir el camp `role` apuntant al rol correcte (`"role": "Treballador"`).
2. La clau de la variable ha de coincidir amb el camp de l'entitat (`"full_name"`, `"job_title"`, etc.) per a la resolució exacta.
3. Si la clau és diferent del camp DB (p.e. `"nom_treballador"`), s'aplicarà la heurística de nom.

> Per a valors que mai ha d'editar l'usuari (nom, DNI, lloc de treball), considera usar l'enfocament **path-based** directament (`{{Treballador.full_name}}` en HTML o `[[Treballador.full_name]]` en DOCX) i estalviar una entrada al schema.

### Exemple pas a pas

Plantilla HTML amb:
```json
"signing_roles_schema": {
  "Treballador": { "entity_type": "employee", "for_signing": true }
}
"variables_schema": {
  "full_name":  { "role": "Treballador" },
  "job_title":  { "role": "Treballador" },
  "email":      { "role": "Treballador" }
}
```

Usuari selecciona l'empleat *Joan Garcia* (job_title: "Enginyer de software", email: "joan@empresa.com"):

| Variable | Valor auto-omplert | Motiu |
|----------|-------------------|-------|
| `full_name` | `Joan Garcia` | Coincidència exacta amb camp `full_name` |
| `job_title` | `Enginyer de software` | Coincidència exacta amb camp `job_title` |
| `email` | `joan@empresa.com` | Coincidència exacta amb camp `email` |

---

## 7. Bones pràctiques

> **Convenció de claus de rol**: la **clau** del rol al JSON (`signing_roles_schema`) és un identificador tècnic en anglès (`worker`, `hr_manager`, `client_signatory`). L'**etiqueta** (`label`) és el text visible en català/castellà. Als exemples Liquid/DOCX, `{{ worker.full_name }}` i `role="worker"` usen la **clau**, no el label.

1. **Tria l'enfocament adequat per a cada variable**:
   - **Schema-based** (`{{var}}` + `role` al schema): quan l'usuari ha de veure o confirmar el valor (dates, imports, textos lliures, camps que poden variar).
   - **Path-based** (`{{Rol.camp}}` en HTML / `[[Rol.camp]]` en DOCX): quan el valor ve 100% de l'entitat assignada i no té sentit que l'usuari l'editi (nom, DNI, lloc de treball en documents de conformitat).

2. **Usa claus de variable que coincideixin amb camps DB** (`full_name`, `email`, `job_title`…) en l'enfocament schema-based per aprofitar l'auto-omplerta exacta.

3. **Defineix sempre `label`** per a una millor UX al formulari de generació.

4. **Marca com `required: true`** les variables sense les quals el document no té sentit.

5. **Usa `for_signing: false`** per a rols de context (p.e. l'empresa) que proporcionen dades però no signen.

6. **DOCX**: `[[Rol.camp]]` (path-based, server-side) i `{{variable_key}}` (schema-based) es poden combinar en el mateix document Word. Utilitza `[[Rol.camp]]` per als camps d'identitat i `{{variable_key}}` per a dates, clàusules o imports.

7. **HTML**: l'editor visual facilita els fragments schema-based; escriu `{{Rol.camp}}` directament per a camps path-based quan vulguis que el nom o el DNI apareguin sense camp de formulari.

8. **Evita duplicar el mateix valor** en els dos enfocaments (p.e. `{{full_name}}` schema-based I `{{worker.full_name}}` path-based per al mateix rol): és redundant i pot generar inconsistències si l'usuari edita la versió schema-based.

---

## 8. Blocs de contingut (capçaleres i peus)

Les plantilles HTML poden reutilitzar **blocs** definits a **Configuració → Plantilles → Blocs de contingut** (`/settings/templates`).

### Tipus de bloc

| Tipus | On s'aplica | Etiqueta al cos HTML | Notes |
|-------|-------------|----------------------|-------|
| `PAGE_HEADER` | Capçalera de **cada pàgina** del PDF | *(cap)* | El servidor l'envia a Gotenberg com a `header.html`. **No** cal posar res al cos de la plantilla. |
| `PAGE_FOOTER` | Peu de **cada pàgina** del PDF | *(cap)* | Igual, via `footer.html` (p. ex. peu legal RGPD). |
| `DOCUMENT_HEADER` | Inici del **document** (una vegada) | `{{ document_header }}` | Liquid; s'injecta al renderitzar. |
| `DOCUMENT_FOOTER` | Final del **document** (una vegada) | `{{ document_footer }}` | Liquid; s'injecta al renderitzar. |
| `CUSTOM` | Slot opcional per slug | `{{ custom_block_<slug> }}` | Suportat al servidor; la UI de mapping encara no exposa slots CUSTOM. |

### `default_block_mapping`

A la fitxa de la plantilla (`/documents/templates/:id`), la secció **Blocs** assigna UUIDs de blocs als slots (`page_header`, `page_footer`, `document_header`, `document_footer`). Es desa a `document_templates.default_block_mapping`.

### Avís de duplicació

Si el cos HTML conté `{{ document_header }}` o `{{ document_footer }}` **i** alhora s'assigna `PAGE_HEADER`/`PAGE_FOOTER`, el PDF final pot mostrar elements duplicats. El wizard i l'editor manual avisen en aquest cas.

### DOCX i blocs

Els slots `PAGE_HEADER`/`PAGE_FOOTER` apareixen a la UI per plantilles DOCX, però el servidor **encara no** els aplica al flux Word/PDF. Per DOCX, usa contingut dins el `.docx` o blocs només com a referència futura.

---

## 9. Generació de plantilles amb IA

### On s'obre

1. **Documents → Plantilles** → obre una plantilla **pròpia del tenant** (no de plataforma; clona-la si cal).
2. A la fitxa d'un **idioma**, botó **Generar amb IA** (o edita l'idioma i el mateix botó dins el formulari).
3. Requisit: rol **owner** o **manager**.

### Flux del wizard (3–4 passos)

| Pas | Acció |
|-----|--------|
| 1. Prompt | Configura el document (tipus, signants, rols, notes). Copia el prompt o **Executar IA i importar** (requereix clau a `/settings/ai`). |
| 2. Importar | Enganxa el JSON retornat per la IA (o ve del pas anterior). Validació Zod + Liquid + coherència variables. |
| 3. Vista prèvia | Playground amb dades de prova; opcionalment comparar amb un altre idioma existent (només lectura). |
| 4. Confirmació | Si ja hi havia contingut, diff de rols/variables/HTML abans d'aplicar. |

### Format JSON (un locale)

El contracte IA retorna **un sol locale** amb `roles`, `variables` i (si HTML) `content`. Les `key` de rols i variables han de ser **idèntiques** entre idiomes si la plantilla en té diversos; només canvien `label` i `content`.

```json
{
  "locale": "ca",
  "format": "html",
  "roles": [
    { "key": "worker", "label": "Treballador/a", "entity_type": "employee", "for_signing": true }
  ],
  "variables": [
    { "key": "data_inici", "label": "Data d'inici", "type": "date", "required": true }
  ],
  "content": "<div>...</div>"
}
```

**Mode DOCX**: la IA genera només `roles` + `variables`; el fitxer `.docx` es puja manualment amb `[[clau]]` i camps `{{Camp;role=rol;type=signature}}`.

### Copiar des d'un altre idioma

A l'editor de locale, **Copiar des de…** duplica rols, variables i contingut d'un idioma existent com a punt de partida per traduir (també útil sense IA).

### Configuració IA del tenant

A **Configuració → IA** (`/settings/ai`): claus per OpenAI, Anthropic o Gemini; model per proveïdor; proveïdor per defecte per al wizard.

---

## 10. Sintaxi LiquidJS disponible

El motor és **LiquidJS 10** (servidor i previsualització client). S'aplica al **cos HTML de la plantilla** i al contingut Liquid dels **blocs** injectats (`document_header`, etc.).

### Interpolació

```liquid
{{ salari_brut }}
{{ worker.full_name }}
{{ tenant.name }}
{{ globals.today }}
```

### Filtres habituals (estàndard LiquidJS)

| Filtre | Exemple | Resultat típic |
|--------|---------|----------------|
| Data | `{{ data_inici \| date: "%d/%m/%Y" }}` | `15/03/2026` |
| Data amb hora | `{{ globals.now \| date: "%d/%m/%Y %H:%M" }}` | `15/03/2026 14:30` |
| Majúscules | `{{ worker.full_name \| upcase }}` | `MARIA GARCIA` |
| Minúscules | `{{ motiu \| downcase }}` | `text` |
| Capitalitzar | `{{ worker.job_title \| capitalize }}` | `Enginyer software` |
| Valor per defecte | `{{ motiu \| default: "—" }}` | Guionet si buit |
| Escapar HTML | `{{ text \| escape }}` | Entitats HTML |

**Recomanació**: per a variables `type: "date"` al schema, usa sempre `| date: "%d/%m/%Y"` al HTML.

### Condicionals i bucles

```liquid
{% if import_sol > 1000 %}
  <p>Requereix aprovació de direcció.</p>
{% endif %}

{% unless worker.status == "inactive" %}
  <p>Contracte actiu.</p>
{% endunless %}

{% for item in llista_epi %}
  <li>{{ item }}</li>
{% endfor %}
```

### Context automàtic (no cal declarar al schema)

- `tenant.*`, `site.*`
- `globals.date`, `globals.today`, `globals.year`, `globals.now` (també `today`, `year`, `now` a nivell arrel)
- `document_header`, `document_footer`, `custom_block_*` (si hi ha blocs assignats)

---

## 11. Signatura: DocuSeal vs firma pròpia

### HTML

L'editor insereix `<signature-field role="worker">`, `<date-field>`, etc. La **firma pròpia (native)** processa principalment `<signature-field>`.

### DOCX

Sintaxi DocuSeal: `{{Firma;role=worker;type=signature}}`. Tipus: `signature`, `initials`, `date`, `text`, `number`, `checkbox`, `image`.

| Proveïdor | Tipus de camp DOCX |
|-----------|-------------------|
| **DocuSeal** | Tots els tipus anteriors |
| **Firma pròpia** | Només `type=signature` (substituït per marcador intern); la resta queda al Word o requereix DocuSeal |

---

## 12. Camps i tipus d'entitat (actualitzat)

### `entity_type` al `signing_roles_schema`

| Valor | Descripció | Pot signar? |
|-------|------------|:-----------:|
| `employee` | Empleat | Sí (si `for_signing: true`) |
| `contact` | Contacte / client | Sí |
| `user` | Usuari del portal | Sí (UI); resolució server-side limitada |
| `person` | Persona genèrica | Sí (UI); resolució server-side limitada |
| `site` | Seu / local | No (context) |
| `asset` | Actiu | No (context) |
| `tenant` | Empresa | No (context; usa també `tenant.*` al Liquid) |
| `catalog_item` | Article del catàleg | No (context) |

### Camps per `entity_type` (auto-omplerta / path-based)

| `entity_type` | Camps |
|---------------|-------|
| `employee` | `full_name`, `email`, `phone`, `job_title`, `document_id`, `starts_on`, `status` |
| `contact` | `display_name`, `email`, `phone`, `company_name` |
| `user` | `full_name`, `email` |
| `person` | `full_name`, `email` |
| `site` | `name`, `address`, `city` |
| `asset` | `name`, `serial_number`, `model` |
| `tenant` | `name`, `tax_id`, `slug`, `logo_url`, `address`, `phone`, `email`, `website` |
| `catalog_item` | `name`, `sku` |

---

## 13. Auditoria i automatitzacions

Generar un document crea o actualitza registres de **signatura** (`signing_submissions`) quan s'usa el flux de firmes. L'event d'auditoria dedicat **`DOCUMENT_GENERATED`** (previst per automatitzacions) **encara no està implementat**. Els events relacionats avui són:

- `TEMPLATE_*`, `TEMPLATE_LOCALE_*` — canvis a plantilles
- `SIGNING_SUBMISSION_CREATED`, `SIGNING_SUBMISSION_STATUS_CHANGED` — cicle de signatura

Quan s'implementi `DOCUMENT_GENERATED`, podrà disparar regles d'automatització post-generació.
