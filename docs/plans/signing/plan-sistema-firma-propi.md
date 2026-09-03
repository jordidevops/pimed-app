# Pla de Millora: Sistema de Firma Digital Propi (Presencial i Remota)

Aquest document detalla l'estratègia per implementar un sistema de firma digital propi, oferint una alternativa cost-efectiva a DocuSeal per a casos d'ús on una signatura electrònica avançada no és estrictament necessària, però es requereix un nivell de prova superior a una signatura en paper sense evidències. L'objectiu és proporcionar al tenant una cobertura legal bàsica mitjançant la recol·lecció d'evidències digitals.

## 1. Objectius del Sistema de Firma Propi

*   **Reducció de Costos:** Eliminar la dependència de serveis de tercers per a la signatura de documents no crítics, reduint els costos operatius per al tenant.
*   **Cobertura Legal Bàsica:** Proporcionar un mecanisme de signatura que, tot i no ser una signatura electrònica qualificada (segons eIDAS), reculli suficients evidències digitals (IP, timestamps, User-Agent, etc.) per a la seva validesa com a prova en molts contextos legals.
*   **Flexibilitat:** Suportar tant la signatura presencial (in-situ) com la remota (via email).
*   **Integració Nativa:** Oferir una experiència d'usuari fluida i integrada dins del flux de treball existent de l'aplicació.

## 2. Components Clau

### 2.1 Generació de Documents

*   **Reutilització del `DocumentOrchestrator`:** El component existent s'encarregarà de la pre-ompliment de variables i la selecció de plantilles.
*   **Conversió a PDF:**
    *   Per a plantilles HTML: Utilitzar una llibreria frontend (ex. `html2pdf.js`) per generar el PDF directament al navegador.
    *   Per a plantilles DOCX: Implementar un servei backend (Edge Function/RPC) que utilitzi llibreries com `mammoth.js` (per convertir DOCX a HTML) i posteriorment `html2pdf.js` o un servei de conversió de PDF (ex. `puppeteer` en un Edge Function) per generar el PDF final.

### 2.2 Signatura Presencial (Canvas)

Ideal per a albarans, parts de feina o acceptacions de servei al camp.

*   **Frontend (`SignaturePad` Component):**
    *   Un component React basat en un `canvas` que permeti al client dibuixar la seva signatura amb el dit o un llapis tàctil.
    *   Opcions per esborrar i reiniciar la signatura.
    *   Captura de la signatura com a imatge (SVG o Base64 PNG).
*   **Backend / Estampació:**
    *   El PDF generat es passa al backend juntament amb la imatge de la signatura del client.
    *   El backend estamparà la imatge de la signatura del client i la signatura de l'operari (recuperada de `data.employees.signature_blob`) al PDF.
    *   **Recollida d'Evidències:** En el moment de la signatura, es registraran:
        *   `user_id` de l'operari que recull la signatura.
        *   `client_id` del signant.
        *   `project_id` al qual pertany el document.
        *   `timestamp` exacte de la signatura.
        *   `geolocation` (si el dispositiu de l'operari ho permet i l'usuari ho accepta).
        *   `device_info` (User-Agent del dispositiu de l'operari).

### 2.3 Signatura Remota (Email-based)

Per a pressupostos o documents que requereixen l'acceptació d'un client que no està presencialment.

*   **Frontend (Flux d'Enviament):**
    *   Des del projecte, l'usuari selecciona "Enviar a Signar (Propi)".
    *   Es genera el PDF del document i es puja al DMS (`data.documents`).
    *   Es crea un registre a `data.document_signing_sessions` amb un `signing_token` únic i de curta durada.
    *   S'envia un correu electrònic al signant (utilitzant el `Email Workflow` existent) amb un enllaç únic: `[URL_TENANT]/sign/[signing_token]`.
*   **Pàgina Pública de Signatura (`/sign/[token]`):**
    *   Una pàgina pública (sense autenticació de l'aplicació) on el client pot visualitzar el document PDF.
    *   Un `SignaturePad` (canvas) per dibuixar la signatura o un checkbox d'acceptació.
    *   Un botó "Signar Document".
*   **Backend (Recollida d'Evidències i Estampació):**
    *   Quan el client signa, la petició al backend inclourà el `signing_token` i la signatura.
    *   El backend validarà el token, recuperarà el document del DMS.
    *   **Recollida d'Evidències:** Es registraran:
        *   `IP` del signant.
        *   `User-Agent` del navegador del signant.
        *   `timestamps` (obertura de l'enllaç, visualització del document, signatura).
        *   `geolocation` (si el navegador ho permet i l'usuari ho accepta).
    *   La signatura i les evidències s'estampen al PDF.
    *   El PDF final signat es guarda al DMS, possiblement com una nova versió del document original.
    *   L'estat de la sessió de signatura (`data.document_signing_sessions`) s'actualitza a "Signed".

## 3. Evidències i Cobertura Legal (Bàsica)

Per augmentar la validesa de la signatura, el sistema recollirà i estamparà les següents evidències:

*   **Registres d'Auditoria (`data.document_signatures_audit`):** Una taula dedicada a emmagatzemar totes les dades recollides per cada signatura:
    *   `document_id`
    *   `signing_session_id` (per a signatures remotes)
    *   `signer_id` (si és un contacte conegut)
    *   `signer_name`, `signer_email` (si no és un contacte conegut)
    *   `timestamp_sent`, `timestamp_opened`, `timestamp_viewed`, `timestamp_signed`
    *   `ip_address`
    *   `user_agent`
    *   `geolocation` (lat/lon)
    *   `signature_image_blob` (la imatge de la signatura)
    *   `document_hash` (hash SHA256 del document abans de la signatura per verificar la integritat).
*   **PDF Estampat:** El PDF final inclourà:
    *   La imatge de la signatura del client i de l'operari.
    *   Un bloc de text visible (o una pàgina addicional) amb un resum de les evidències recollides (data, hora, IP, etc.).
    *   Un identificador únic del document i un enllaç a la sessió d'auditoria.
*   **Limitacions:** És crucial comunicar al tenant que aquesta no és una signatura electrònica avançada o qualificada segons la normativa eIDAS (que requereix certificats digitals emesos per tercers de confiança). No obstant això, proporciona un nivell de prova significativament superior a una signatura manuscrita sense cap evidència addicional, sent vàlida en molts contextos comercials i legals com a prova d'acceptació.

## 4. Integració amb el Flux de Projectes

*   **Pestanya "Documents" / "Facturació":** A la vista de detall del projecte (`/projects/[id]`), s'afegirà una opció clara per "Generar i Signar Document".
*   **Selector de Mètode de Firma:** Un modal permetrà escollir entre:
    *   "Signatura Presencial (Propi)"
    *   "Signatura Remota (Propi)"
    *   "Signatura Remota (DocuSeal)" (si el tenant té DocuSeal activat).
*   **Actualització d'Estat:** L'estat del projecte o del document es podrà actualitzar automàticament a "Pendent de Signatura" o "Signat" un cop el procés s'iniciï o es completi.

## 5. Full de Ruta d'Implementació

### Fase 1: Signatura Presencial (MVP)
1.  **Backend:** Implementar RPC/Edge Function per estampar imatges (signatura client + operari) i metadades al PDF.
2.  **Frontend:** Desenvolupar el component `SignaturePad` i integrar-lo al flux de generació d'Albarans/Parts de Feina.
3.  **Base de Dades:** Crear la taula `data.document_signatures_audit` per registrar les evidències.

### Fase 2: Signatura Remota (MVP)
1.  **Base de Dades:** Crear la taula `data.document_signing_sessions` per gestionar els tokens i estats.
2.  **Backend:** Implementar RPC/Edge Function per generar tokens, enviar correus i recollir evidències de la pàgina de signatura pública.
3.  **Frontend:** Desenvolupar la pàgina pública de signatura (`/sign/[token]`) i integrar el `SignaturePad` o l'opció d'acceptació.
4.  **Integració:** Connectar el flux de generació de Pressupostos amb l'enviament de signatures remotes.

### Fase 3: Millores i Auditoria
1.  **Generació de Certificat d'Evidències:** Desenvolupar un PDF addicional o un annex al document signat que resumeixi totes les evidències recollides de manera llegible.
2.  **DMS Integration:** Assegurar que els documents signats es versionen correctament dins del DMS.
3.  **UI/UX:** Millorar la visualització de l'estat de signatura dins del projecte i les notificacions al tenant.
