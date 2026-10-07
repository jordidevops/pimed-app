---

# Especificació Tècnica: Sistema de Gestió i Firma de Documents Multi-Tenant

## 1. Objectiu Principal

Desenvolupar un mòdul de creació i firma de documents basat en plantilles (DOCX i HTML) per a una aplicació web React multi-tenant (SaaS). El sistema ha de permetre omplir variables dinàmiques al frontend i delegar la conversió a PDF i el procés legal de firma a l'API de DocuSeal. El sistema es divideix en una Fase 1 (MVP actual) i una Fase 2 (Futur).

---

## 2. Abast del Sistema de Firmes

### Decisió de producte: DocuSeal només plataforma (sense BYO)

**Decisió vigent:** les organitzacions **no** poden connectar el seu propi compte DocuSeal (BYO). DocuSeal funciona exclusivament amb el compte central de la plataforma (PiMed). Cada firma DocuSeal consumeix 1 crèdit de l'organització.

**Control d'enllaços (CS-D58–D60, CF-28):** el tenant no veu ni rep (UI/API) l'URL de firma de la contrapart. Lliurament via correu PiMed i/o customer portal; WhatsApp només com a nudge al portal. Fallada d'email no mostra l'URL. DocuSeal comercial (F8) no exposa slug/embed al tenant-portal.

La via “pròpia” sense dependre del DocuSeal de tercers és la **firma nativa** de la plataforma (sessions, PDF, evidències), no un BYO DocuSeal.

#### Per què no obrim BYO DocuSeal

| | Pros d’obrir BYO | Contres / riscos |
|---|---|---|
| Cost | L’organització paga DocuSeal directament; menys crèdits PiMed | Es perd el model de crèdits i el marge operatiu clar |
| Control | Organitzacions enterprise amb compte propi | L’organització veu tots els enllaços de firma al seu DocuSeal → risc d’usurpar la firma de la contrapart |
| Operativa | Self-hosted / compte dedicat | Webhook, secrets i suport es multipliquen; un sol `DOCUSEAL_WEBHOOK_SECRET` de plataforma no cobreix comptes aliens |
| Producte | Feature “enterprise” | UI, validació de clau, migracions i runbooks que avui no existeixen |

#### Problemes de fer BYO malament

- **Exposar BYO a la UI sense webhook per compte:** les firmes es creen al DocuSeal aliè però els events no tornen de forma fiable a PiMed → estats penjats.
- **Prometre BYO al copy sense formulari de configuració:** confusió de producte (estat actual històric a `/settings/signing`).
- **Assumir que amagar l’enllaç a la UI de PiMed protegeix la firma en BYO:** inútil, perquè el titular del compte DocuSeal ja té tots els submitter links a l’API/UI de DocuSeal.
- **Permetre canviar de mode amb firmes en curs:** veure secció següent.

#### Canviar de plataforma ↔ BYO (si algun dia es reconsiderés)

Les submissions DocuSeal viuen al compte que les va crear. Un canvi de mode **no migra** firmes en curs:

1. El nou compte no pot consultar ni cancel·lar `docuseal_submission_id` de l’altre.
2. Els webhooks deixen d’arribar (o arriben al lloc incorrecte).
3. A la BD de PiMed queden IDs orfes i estats desincronitzats.

Caldría una política dura: tancar o completar totes les firmes DocuSeal actives **abans** de canviar de mode. Aquest flux **no està implementat**.

#### Persistència del mode a les firmes

**No:** el mode `platform` / `byo` es guarda a `data.tenant_signing_config` (configuració de l’organització), **no** a cada fila de `data.signing_submissions`.

Cada submission desa `docuseal_submission_id`, `external_id`, estat, signants, etc., però **no** registra amb quin compte (plataforma vs BYO) es va crear. Inferir-ho a posteriori només es podria fer mirant el compte DocuSeal on existeix aquell ID, no amb un camp de la nostra BD.

Si mai es reobrís BYO, caldria afegir un snapshot per submission (p. ex. `docuseal_account_mode` / `api_url` al moment de l’enviament) abans de permetre canvis de mode.

#### Estat tècnic llegat (no producte)

Al backend hi ha esquelet històric (`signing_mode` enum, Vault, `api.save_tenant_docuseal_config`, bifurcació al `sign-document-router`). **No hi ha UI** per activar BYO ni a tenant-portal ni a admin-portal. El mode per defecte és `platform`. Aquest esquelet es deixa adormit; no s’ha d’exposar a usuaris ni documentar-se com a feature disponible.

### Fase 1 (MVP - Integració amb DocuSeal)

* **DocuSeal de la plataforma:** La plataforma utilitza el compte central de DocuSeal. L’organització consumeix crèdits de firma a la nostra app. Cada firma resta un crèdit.
* **BYO DocuSeal:** **Fora d’abast de producte.** No s’ofereix a les organitzacions.

### Fase 2 (V2 - Firma Pròpia)

* **Firma nativa (integrada a la plataforma):** Sessions de firma, PDF (Gotenberg), evidències i fluxos remots/presencials sense passar pel compte DocuSeal de l’organització. Conviu amb DocuSeal plataforma segons feature flags i configuració admin.

---

## 3. Motor de Plantilles i Etiquetes

El sistema ha de ser 100% compatible amb la sintaxi nativa de DocuSeal per evitar manipulacions complexes abans d'enviar el document a l'API.

* **Etiquetes de Text Dinàmic:** `[[nom_variable]]`. Aquestes s'ompliran a la nostra app abans d'enviar a DocuSeal, o es passaran com a *values* a l'API. Diferenciarem lògicament entre variables autoemplenades pel context de l'app (ex. nom de l'organització) i variables manuals introduïdes per l'usuari en un formulari previ.
* **Etiquetes de Firma:** `{{signature;role=Client}}` o `{{date;role=Client}}`. Aquestes es deixaran intactes al document perquè DocuSeal les processi.

---

## 4. Component Frontend: `<DocumentOrchestrator />`

Component aïllat de React que actua com a màquina d'estats.

* **Estat 1 (Càrrega i Anàlisi):** Rep el fitxer original (DOCX o cadena HTML). Llegeix les etiquetes `[[variable]]` i detecta quines falten per omplir basant-se en el context actual de l'app.
* **Estat 2 (Formulari Manual):** Mostra els *inputs* perquè l'usuari ompli les variables manuals que falten. Demana els noms i emails dels signants basant-se en els rols detectats (`role=X`).
* **Estat 3 (Selecció de Proveïdor):** Mostra un selector per escollir l'opció de firma (DocuSeal plataforma i/o firma nativa segons configuració). Si se selecciona DocuSeal, valida que el saldo de crèdits sigui més gran que 0 quan calgui.
* **Estat 4 (Processament):** Utilitza `docxtemplater` (o interpolació per HTML) per generar el document preparat en local.
* **Estat 5 (Enviament):** Crida al nostre backend passant el fitxer preparat, els signants i el proveïdor escollit. Mostra un missatge d'èxit ("Enviat a signar") en rebre resposta.

---

## 5. Backend i Base de Dades (Edge Functions / Supabase)

S'han d'implementar les següents estructures de dades i lògica de servidor.

* **Configuració per organització (`tenant_signing_config`):** `is_active`, mode (defecte `platform`; BYO no exposat a producte), `signing_credits`, URL/clau de plataforma via secrets d'entorn.
* **Submissions (`signing_submissions`):** `id`, `tenant_id`, `status`, `docuseal_submission_id`, `external_id`, signants, etc. **Sense** camp de mode plataforma/BYO per fila (veure decisió més amunt).
* **Endpoint de Router de Firmes (`sign-document-router`):** Comprova activació i crèdits, utilitza la `DOCUSEAL_API_KEY` de l'entorn del servidor i fa el POST a DocuSeal; consumeix 1 crèdit en mode plataforma.
* **Endpoint Webhook (`docuseal-webhook`):** Escolta els esdeveniments del compte DocuSeal de plataforma. Quan un document canvia a estat completat, descarrega el PDF firmat, el guarda al `Storage` (bucket privat) i actualitza l'estat a la base de dades.

---

## 6. Generació de Documents Sense Firma (Drafts / Pressupostos)

Per als casos d'ús on no cal una firma legal, no farem servir l'API de DocuSeal ni consumirem recursos de servidor.

* **HTML a PDF:** S'utilitzarà una llibreria frontend (ex. `html2pdf.js` o similar) per generar i descarregar el document directament al navegador de l'usuari un cop les variables `[[ ]]` estiguin substituïdes.
* **DOCX a DOCX:** L'arxiu generat per `docxtemplater` amb les dades omplertes s'oferirà com a descàrrega directa (`.docx`) sense passar a PDF.

---
