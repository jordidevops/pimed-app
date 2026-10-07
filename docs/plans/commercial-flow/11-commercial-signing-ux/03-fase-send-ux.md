# Fase 3 — Enviar per acceptar

> **Tall:** core natiu usable  
> **Prerequisit:** fase 2 amb feature flag on per tenant de prova  
> **Provider inicial:** firma nativa; DocuSeal s'afegeix a fase 8

## Objectiu

Substituir la fragmentació «Enviar PDF» + «Acceptar/Refusar» + diàleg de firma per una acció comercial principal i un únic bloc d'estat.

## 3.1 Jerarquia d'accions

En document emès:

1. **Enviar per acceptar** — CTA principal.
2. **Només entregar PDF** — secundari.
3. **Registrar resposta** / **Firma presencial** — menú secundari segons permisos.
4. **Més** — DMS, centre de signatures, imprimir, HTML tècnic.

En draft:

- CTA «Emetre»;
- cap firma, request ni retry PDF.

En request open:

- CTA principal «Veure resposta pendent»;
- reenviar/revocar dins la targeta;
- no crear una segona request.

## 3.2 Preflight

Abans d'enviar, el servidor retorna:

```text
target_type / target_id
document_label / number
client account
signer/contact candidates
formalization mode
provider availability
expires_at
pdf ready / render required
portal grant available
```

Regles:

- `signed_quote`: target quote/amendment;
- `separate_agreement`: target agreement version; si no existeix, oferir **Preparar acord**, no firmar quote;
- delivery note: target DN;
- expired/cancelled/rejected/superseded: no enviar;
- PDF/version obligatori abans de crear la request.

Si cal render:

1. render asíncron/síncron existent;
2. esperar resultat acotat o mostrar preparació;
3. crear request només quan `rendered_document_id` + version id existeixen;
4. error de render no deixa request open òrfena.

## 3.3 Diàleg «Enviar per acceptar»

### Camps

- destinatari/contact point;
- signant principal (nom opcional si encara no se sap);
- canal: Correu | WhatsApp (nudge portal) | Portal | Presencial;
- venciment;
- checkbox PDF adjunt (email);
- resum «El client acceptarà: …».

Sense «Copiar enllaç» (CS-D13 / CS-D58). WhatsApp només si hi ha grant portal viu; altrament deshabilitat amb causa.

No mostrar selector de provider quan només hi ha nativa. Fase 8 l'afegeix si DocuSeal és realment disponible.

### Confirmació

Mostrar:

- document/número/import;
- destinatari;
- data límit;
- text honest: el client rebrà el correu i/o podrà respondre al portal; el tenant no veu l'enllaç de resposta (CS-D58);
- en `separate_agreement`, deixar clar que es firma l'acord, no el pressupost.

## 3.4 Orquestració servidor

Edge Function proposada:

```text
send-commercial-decision-request
```

Flux:

1. verificar JWT intern i permís;
2. cridar preflight/create request idempotent;
3. crear sessió nativa remota lligada a `decision_request_id`;
4. crear delivery + token hashat;
5. si email: enqueue (token només al template server-side);
6. si WhatsApp: retornar només deep link de portal (host portal + path pendents), **mai** `raw_token` ni `/sign/...`;
7. registrar operation log amb `request_id`, mai raw token;
8. retornar estat request/delivery **sense** `raw_token` al client autenticat (CS-D58).

No acceptar al body `tenant_id`, `rendered_document_id`, `content_hash` o imports com a autoritat; es resolen al servidor.

## 3.5 Correu

### Template

Crear `commercial_decision_request` a `data.email_templates` amb ca/es/en:

- branding tenant;
- tipus i número;
- client;
- total/impostos resumits quan `show_prices=true`;
- validesa;
- CTA «Revisar i respondre»;
- text de seguretat i contacte;
- enllaç portal addicional només si hi ha grant.

No injectar HTML complet del document.

### Enqueue

Payload:

- `idempotency_key = commercial-decision:{request_id}:delivery:{delivery_id}`;
- recipient resolt des de contact point;
- template/locale;
- attachment descriptor si seleccionat;
- metadata només amb ids/correlation, mai token cru;
- tags comercials.

Adjunt:

- PDF immutable sense firma;
- default on quote/agreement, off DN;
- límit de mida explícit segons worker existent;
- si l'adjunt falla, delivery email falla: no enviar un correu que promet adjunt inexistent sense avisar.

### Estat

- `queued`: acceptat per cua;
- `sent`: confirmat pel worker/provider email;
- `failed`: codi estable + retry;
- obrir el link crea event `opened`; cap píxel espia.

## 3.6 WhatsApp (nudge portal)

- **no** generar ni mostrar bearer de decisió al tenant;
- text curt: organització, document, número i deep link al **customer portal** (exigeix login grant; no és magic-link de firma);
- sense grant portal: canal deshabilitat o missatge «reviseu el correu» sense URL;
- `wa.me` només prepara la conversa;
- UI diu «WhatsApp obert», no «Enviat»;
- delivery canal `whatsapp_portal_nudge` queda `prepared` fins a ús del portal o reenviament.

No adjuntar PDF a WhatsApp V1. No hi ha «Copiar enllaç» de `/sign/:token`.

## 3.7 Targeta «Resposta del client»

A fitxa quote/agreement/DN:

- estat: pendent / acceptat / refusat / caducat / revocat / substituït;
- què s'ha enviat i a qui (emmascarat);
- darrer delivery i errors;
- venciment;
- proveïdor/canal;
- accions: reenviar correu, nudge WhatsApp (portal), revocar, registrar resposta, firma presencial; **sense** copiar enllaç de firma;
- després de decidir: signant, data, via i «Veure justificant».

Refetch:

- immediat després d'accions locals;
- `refetchOnWindowFocus`;
- polling 15–30 s només mentre request open i pàgina visible;
- aturar polling en outcome terminal.

## 3.8 Registrar resposta fora de PiMed

### Refús

- motiu obligatori;
- via `office`;
- confirmació que és una resposta comunicada per telèfon/email/etc.;
- apply directe, sense sessió ni pad.

### Acceptació presencial

- obre firma nativa presencial sobre la mateixa request/snapshot;
- apply es produeix per sessió signada;
- si la request ja es va decidir remotament, mostrar resultat i no obrir pad.

Acceptació verbal sense firma no és outcome `accepted` V1.

## Fitxers

- `CommercialDocumentShareSheet.tsx`
- `CommercialNativeSignDialog.tsx` (reduir/absorbir)
- `CommercialDocumentDetail.tsx`
- `QuoteDetailPage.tsx`
- `DeliveryNoteDetailPage.tsx`
- `AgreementsPage.tsx`
- `commercialFlowService.ts`
- locales commercial ca/es/en
- nova Edge `send-commercial-decision-request`
- `_shared/native-signing-email.ts` només si es reutilitza sense duplicar plantilla

## Proves

### Unit/Vitest

- target per formalization mode;
- jerarquia de CTA per status/request;
- defaults attachment;
- copy WhatsApp honest;
- polling només open/visible;
- reenviar crea delivery nou, no request nova.

### Integració

- enqueue idempotent;
- fallada email deixa request open + delivery failed;
- mateix `client_op_id` no duplica request/session/delivery;
- token no apareix en operation/email metadata;
- recipient cross-tenant denegat.

### UAT

1. Quote `signed_quote`: email → request pendent.
2. Quote `separate_agreement`: prepara acord → email d'acord; cap email de firma quote.
3. DN: WhatsApp prepara link; UI no afirma lliurament.
4. Reenviar crea token nou; revocar l'antic.
5. Registrar refús d'oficina sense pad.

## DoD

- [x] CTA principal únic i comprensible (flag on).
- [x] Email real de servidor via `enqueue_commercial_decision_delivery_email` + plantilla `commercial.decision_request` (ca/es/en); adjunt PDF diferit (worker path).
- [x] Request/session/delivery idempotents (RPC + intent lligat); rollback request si falla el send.
- [x] Estat i errors visibles (queued/failed delivery, revocar, toast honest WhatsApp-copy).
- [x] `separate_agreement` no demana doble firma (CTA ocult fins a target agreement_version; envia `agreement_version`).
- [x] DMS/centre relegats a «Més».
- [x] Targeta «Resposta pendent» amb reenviar/revocar.
- [x] Tres targets (quote / DN / agreement_version) provats via SQL smoke (`commercial_decision_three_targets_tests.sql`); UAT manual UI residual.
- [x] Adjunt PDF al correu diferit (worker path; plantilla + enqueue sense adjunt).

## Rollback

- feature flag off torna al share/sign antic;
- requests creades es mantenen consultables/revocables;
- worker email nou es pot desactivar sense alterar decisions.
