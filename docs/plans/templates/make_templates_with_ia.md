# Estudi i Pla d'Implementació: Creació de Plantilles amb IA

## 1. Visió General i Objectius

La generació de plantilles de documents (tant el contingut com els esquemes de variables i rols de signatura) és un procés feixuc per a l'usuari final. L'objectiu és introduir un **"Centre de Confecció amb IA"** dins del mòdul de Documents (`/documents/templates`) que permeti:
1. Oferir a l'usuari **prompts dinàmics** d'alta qualitat llestos per ser copiats a IAs externes (ChatGPT, Claude, etc.).
2. Proveir un mecanisme per **enganxar un JSON estructurat** generat per la IA.
3. Obtenir de cop la **generació de múltiples idiomes (locales)**, l'HTML de base, i l'esquema exacte de variables i rols.
4. Incloure una **Vista Prèvia en temps real** perquè l'usuari pugui introduir dades de prova i validar l'aspecte de la plantilla abans de desar-la definitivament.

## 2. El Format d'Intercanvi JSON (Contracte IA ↔ App)

Per garantir la compatibilitat, la IA ha de generar un JSON predictible. Al prompt s'exigirà un esquema com el següent:

```json
{
  "roles": [
    { "key": "empresa", "label": "Empresa / Contractador" },
    { "key": "treballador", "label": "Treballador" }
  ],
  "variables": [
    { "key": "salari_brut", "label": "Salari Brut Anual", "type": "number" },
    { "key": "data_inici", "label": "Data d'Inici", "type": "date" }
  ],
  "locales": [
    {
      "locale": "ca",
      "format": "html",
      "content": "<div class=\"contract\">... {{ salari_brut }} ...</div>"
    },
    {
      "locale": "es",
      "format": "html",
      "content": "<div class=\"contract\">... {{ salari_brut }} ...</div>"
    }
  ]
}
```

> [!NOTE]
> **El problema del DOCX i la IA:** Models com ChatGPT no retornen nattivament un document `.docx` via JSON de forma fiable. Per a plantilles DOCX, el flux òptim és que la IA dissenyi els `roles` i les `variables`, però l'usuari pugi el Word (.docx) de forma manual (i el posa amb les etiquetes corresponents `[[ variable ]]`). El prompt per a DOCX s'adaptarà per només generar l'esquema o bé generar l'HTML i convertir-lo internament a PDF.

## 3. Experiència d'Usuari (UX): El "Template AI Wizard"

S'afegeix un nou botó a l'editor de plantilles: **"Generar Idiomes / Contingut amb IA"**. Això obrirà un Assistent (Wizard) amb els següents passos:

### Pas 1: El Prompt de Generació
El sistema genera un text copiador intel·ligent. 
*Exemple:*
> *"Actua com un expert legal i enginyer de programari. Necessito que creïs una plantilla per a un contracte de ___[POSA AQUÍ EL TEU CAS, EX: Confidencialitat (NDA) d'Empleats]___. \n\nGenera el contingut en format HTML (utilitzant LiquidJS per a les variables, per exemple `{{ nom_empresa }}`). Aquesta plantilla requerirà signatures de diverses parts.\n\nRetorna el resultat exclusivament en aquest format JSON validant per diversos idiomes (ca, es, en): [Esquema JSON...]"*

### Pas 1: El Prompt de Generació i Injecció del Context
El sistema genera un text intel·ligent per copiar. **Aquest pas és crític i ha d'informar la IA de l'ecosistema de dades de l'App.**
A l'hora de compilar aquest prompt, el codi llegirà els **rols per defecte** de sistema configurats a `/settings/templates` (ex: `worker`, `manager`, `approver`, `hr_director`, `client_signatory`, etc.) i els **esquemes d'entitats** actius (com els camps de l'entitat `employee`).

El prompt resultant serà similar a això:
> *"Actua com un expert legal... Necessito que creïs una plantilla per a ___[EL TEU CAS]___. 
> Genera el contingut en format HTML utilitzant tags LiquidJS. 
> 
> IMPORTANT: Tens a la teva disposició els següents Rols de Sistema. Si la plantilla requereix aquestes figures, designa'ls al JSON amb la key exacta: `worker`, `manager`, `hr_manager`, `client_signatory`, `external_party`...
> Per al rol `worker` (tipus empleat), utilitza exactament aquestes variables per imprimir les seves dades al text:
> - Nom complet: `{{ worker.full_name }}`
> - NIF/DNI: `{{ worker.document_id }}`
> - Telèfon: `{{ worker.phone }}`
> - Càrrec: `{{ worker.job_title }}`
> - Data d'incorporació: `{{ worker.starts_on }}`
> - Estat: `{{ worker.status }}`
> 
> Retorna el resultat exclusivament en aquest format JSON validant per diversos idiomes (ca, es, en): [Esquema JSON...]"*

### Pas 2: Importació
Un camp de text gran on l'usuari fa *Paste* del JSON obtingut. L'App el valida instantàniament amb `Zod`. Si és correcte, es parsegen els Rols, les Variables i els Locales en memòria.

### Pas 3: El "Playground" (Vista Prèvia Integrada)
Un cop el JSON és vàlid, el sistema carrega una interfície similar al `DocumentOrchestrator` actual (el modal de Generar Document):
- A l'esquerra: Un formulari generat dinàmicament amb les variables i rols deduïts per la IA, perquè l'usuari posi valors falsos (Dummy Data).
- A la dreta: Un `iframe` o panell que renderitza l'HTML (usant `LiquidJS` al navegador) en temps real.
- A dalt: Un selector de `locale` (per canviar entre `ca`, `es`, `en` generats) per veure com queden les traduccions.

### Pas 4: Desar i Sobreescriure
En confirmar, l'App desa automàticament els nous Rols i Variables a l'entitat de la Plantilla, i fa "Upsert" dels nous `locales` a la base de dades. Això resol de cop setmanes de feina del Tenant.

## 4. Pla d'Implementació Tècnica

### Fase 1: Creació del Model d'Importació i Zod Schema
1. Establir i definir rigorosament la interfície TypeScript (`AITemplateJSON`) i l'esquema de validació `Zod`.
2. Crear la lògica de transformació per fusionar els `roles` i `variables` que ja pogués tenir la plantilla amb els nous generats per la IA (evitant duplicitats).

### Fase 2: Component "AI Template Wizard"
1. Desenvolupar el component UI de l'assistent.
2. Afegir el generador del *Prompt*. Aquest mòdul de codi haurà d'agafar les etiquetes ja pre-configurades del sistema (com dades del tenant) i explicar-les al text perquè la IA en faci ús.
3. Formar el camp de *JSON Paste* amb auto-detecció d'errors (mostrant a l'usuari on falla l'esquema si ChatGPT o Claude s'han equivocat formatant).

### Fase 3: Integrar la Vista Prèvia (Preview) a l'Editor
Aquesta és una millora sol·licitada tant per l'assistent d'IA com per a l'editor estàndard de locales.
1. Desenvolupar un component `TemplatePreviewPlayground`.
2. Aquest component requereix:
   - Entrada: Codi font (HTML Liquid) i JSON de dades (Variables assignades en l'editor).
   - Render: Crida sincrònica al renderitzador local `liquidjs` al navegador i inserció de la sortida segura.
3. Inserir aquest component tant al pas 3 del nou *Wizard d'IA* com en el *Modal d'edició* habitual d'un idioma (`TemplateFormModal`).

### Fase 4 (Full de Ruta Futur): API Keys i Generació Nativa
L'arquitectura dissenyada (separació clara entre el generador de prompts i el parsejador del resultat Zod) facilita la futura Fase 4:
Quan el tenant pugui introduir la seva API Key d'OpenAI/Anthropic a `/settings/ai`, se substituirà el procés de copiar-enganxar per un botó "Executar IA i Importar" que farà la crida via el Backend de Supabase i abocarà el JSON processat directament a la pantalla de Vista Prèvia.
