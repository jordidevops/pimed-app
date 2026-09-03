---

# Especificació Tècnica: Sistema de Gestió i Firma de Documents Multi-Tenant

## 1. Objectiu Principal

Desenvolupar un mòdul de creació i firma de documents basat en plantilles (DOCX i HTML) per a una aplicació web React multi-tenant (SaaS). El sistema ha de permetre omplir variables dinàmiques al frontend i delegar la conversió a PDF i el procés legal de firma a l'API de DocuSeal. El sistema es divideix en una Fase 1 (MVP actual) i una Fase 2 (Futur).

---

## 2. Abast del Sistema de Firmes

### Fase 1 (MVP - Integració amb DocuSeal)

* **Nivell 2 (DocuSeal de la Startup):** La plataforma utilitza el compte central de DocuSeal de la nostra startup. El tenant ha de comprar crèdits de firma a la nostra app. Cada firma resta un crèdit.
* **Nivell 3 (BYO DocuSeal - Bring Your Own):** El tenant pot introduir la seva pròpia `API_KEY` de DocuSeal al seu perfil. Les peticions s'envien a través de la seva clau, sense consumir crèdits de la startup.

### Fase 2 (V2 - Firma Pròpia)

* **Nivell 1 (Firma Pròpia - FOS DE L'ABAST ACTUAL):** Implementació futura on s'imitarà el flux de l'API de DocuSeal directament al nostre backend. Inclourà conversió pròpia de DOCX a PDF, motor de recol·lecció de firmes via web, auditoria d'IP/User-Agent, incrustació d'imatge SVG i segellat criptogràfic del PDF amb un certificat digital propi per tenir validesa legal com a tercer independent.

---

## 3. Motor de Plantilles i Etiquetes

El sistema ha de ser 100% compatible amb la sintaxi nativa de DocuSeal per evitar manipulacions complexes abans d'enviar el document a l'API.

* **Etiquetes de Text Dinàmic:** `[[nom_variable]]`. Aquestes s'ompliran a la nostra app abans d'enviar a DocuSeal, o es passaran com a *values* a l'API. Diferenciarem lògicament entre variables autoemplenades pel context de l'app (ex. nom del tenant) i variables manuals introduïdes per l'usuari en un formulari previ.
* **Etiquetes de Firma:** `{{signature;role=Client}}` o `{{date;role=Client}}`. Aquestes es deixaran intactes al document perquè DocuSeal les processi.

---

## 4. Component Frontend: `<DocumentOrchestrator />`

Component aïllat de React que actua com a màquina d'estats.

* **Estat 1 (Càrrega i Anàlisi):** Rep el fitxer original (DOCX o cadena HTML). Llegeix les etiquetes `[[variable]]` i detecta quines falten per omplir basant-se en el context actual de l'app.
* **Estat 2 (Formulari Manual):** Mostra els *inputs* perquè l'usuari ompli les variables manuals que falten. Demana els noms i emails dels signants basant-se en els rols detectats (`role=X`).
* **Estat 3 (Selecció de Proveïdor):** Mostra un selector per escollir l'opció de firma. Amaga els nivells desactivats pel tenant. Si se selecciona Nivell 2, valida que el saldo de crèdits sigui més gran que 0.
* **Estat 4 (Processament):** Utilitza `docxtemplater` (o interpolació per HTML) per generar el document preparat en local.
* **Estat 5 (Enviament):** Crida al nostre backend passant el fitxer preparat, els signants i el proveïdor escollit. Mostra un missatge d'èxit ("Enviat a signar") en rebre resposta.

---

## 5. Backend i Base de Dades (Edge Functions / Supabase / Firebase)

S'han d'implementar les següents estructures de dades i lògica de servidor.

* **Esquema de Base de Dades (Taula Tenants):** Afegir columnes `firma_activada` (boolean), `proveidor_firma_defecte` (enum), `docuseal_api_key` (text), `credits_firma` (integer).
* **Esquema de Base de Dades (Taula Documents):** Afegir registre amb `id`, `tenant_id`, `status` (pending, signed, error), i `docuseal_submission_id`. Protegir amb Row Level Security (RLS) perquè cada tenant només vegi els seus documents.
* **Endpoint de Router de Firmes (`/api/sign-document`):** Rep la petició. Si és Nivell 3 (BYO), injecta la `docuseal_api_key` del tenant a l'encapçalament i fa el POST a l'API de DocuSeal. Si és Nivell 2 (Startup), comprova saldo, resta 1 crèdit, utilitza la `API_KEY` de l'entorn del servidor i fa el POST a DocuSeal.
* **Endpoint Webhook (`/api/docuseal-webhook`):** Escolta els esdeveniments de DocuSeal. Quan un document canvia a estat completat, descarrega el PDF firmat de DocuSeal, el guarda al nostre `Storage` (bucket privat) i actualitza l'estat a la base de dades.

---

## 6. Generació de Documents Sense Firma (Drafts / Pressupostos)

Per als casos d'ús on no cal una firma legal, no farem servir l'API de DocuSeal ni consumirem recursos de servidor.

* **HTML a PDF:** S'utilitzarà una llibreria frontend (ex. `html2pdf.js` o similar) per generar i descarregar el document directament al navegador de l'usuari un cop les variables `[[ ]]` estiguin substituïdes.
* **DOCX a DOCX:** L'arxiu generat per `docxtemplater` amb les dades omplertes s'oferirà com a descàrrega directa (`.docx`) sense passar a PDF.

---
