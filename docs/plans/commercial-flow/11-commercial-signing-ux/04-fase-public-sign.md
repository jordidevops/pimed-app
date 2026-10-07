# Fase 4 — Pàgina pública comercial `/sign/:token`

> **Tall:** core client  
> **Prerequisits:** fases 2–3  
> **Principi:** mostrar exactament què es decideix abans de demanar cap acció

## Objectiu

Mantenir la ruta coneguda `/sign/:token`, però oferir una variant comercial mòbil, clara i segura. El flux DMS genèric continua funcionant.

## 4.1 Resolució del token

### Discriminació

1. POST a resolver comercial: hash SHA-256 del token i lookup de token actiu.
2. Si no és comercial, usar el resolver DMS genèric existent.
3. Mai enviar ids interns o tipus des del client per decidir la branca.

Nous links comercials usen token de `commercial_decision_access_tokens`, no `document_signing_sessions.signing_token`.

### Safe link

- GET/HEAD de l'URL només serveix l'aplicació; no decideix, consumeix ni marca opened;
- la SPA fa POST explícit al resolver;
- scanners de correu no poden refusar/acceptar;
- rate limit per hash/IP;
- `Referrer-Policy: no-referrer`;
- CSP sense scripts/imatges de tercers innecessaris;
- cap raw token a logs/Sentry/analytics.

### Resposta pública allowlist

```text
tenant public branding
request status / expiry
document kind / number / locale
snapshot_json public
exact PDF download handle
provider
signer hints
legal/privacy copy
```

Mai:

- tenant ids interns innecessaris;
- notes/costos/marges;
- DMS paths;
- altres documents del client;
- email completa si no cal.

## 4.2 Presentació

Mobile-first, sense `iframe` com a contingut principal:

- tenant/logo/remitent;
- «Pressupost», «Acord» o «Albarà» + número;
- client;
- línies, subtotal, impostos i total si `show_prices=true`;
- validesa;
- condicions/resum del snapshot;
- copy específic:
  - quote: «Acceptes aquesta oferta i les seves condicions»;
  - agreement: «Signes aquest acord i el pressupost annex»;
  - DN: «Confirmes la recepció/execució descrita»;
- PDF exacte descarregable com a evidència, no com a única vista.

Per DN `show_prices=false`, no mostrar imports ni insinuar conformitat econòmica.

## 4.3 Acceptar

Formulari:

- nom i cognoms;
- càrrec/representació opcional o obligatori segons compte;
- checkbox «He revisat el document i tinc autoritat per acceptar-lo»;
- `SignaturePad`;
- CTA «Acceptar i signar».

Flux natiu:

1. validar request/token open;
2. resoldre la sessió nativa lligada server-side;
3. capturar IP/UA al servidor;
4. processar/stampar via pipeline natiu;
5. sessió `signed` → `apply_commercial_decision_request(accepted)`;
6. esperar/pollejar resultat terminal acotat;
7. mostrar justificant.

El navegador no rep el signing token intern ni decideix quin `request_id` aplicar.

Errors:

- stamp/render temporal: request continua open, permet retry idempotent;
- ja decidit: mostrar outcome existent;
- hash/target invàlid: tancar accions i avisar tenant;
- provider no disponible: missatge honest, no fallback silenciós a acceptació sense firma.

## 4.4 Refusar

UI de pes visual equivalent a acceptar:

- acció «Refusar» visible, no amagada;
- confirmació;
- motiu opcional amb categories lliures/no obligatòries;
- cap checkbox d'acceptació;
- cap pad.

Servidor:

1. lock/apply outcome declined;
2. marcar sessió nativa comercial `declined`, no `cancelled`;
3. revocar tokens/sessions germans;
4. notificar tenant asíncronament.

Si apply perd la carrera, mostrar outcome real.

## 4.5 Estats terminals

| Estat | Pàgina |
|-------|--------|
| accepted | Acceptat el dia/hora, signant, botó justificant/PDF |
| declined | Refusat el dia/hora; motiu si és visible |
| expired | Enllaç caducat; «Demanar nou enllaç» notifica tenant |
| revoked | Enllaç revocat; contacte tenant |
| superseded | Existeix versió posterior; no redirigir automàticament a un token nou |
| target cancelled | Document ja no vigent |

No mostrar formularis en estat terminal.

## 4.6 Justificant

Vista/PDF separat del document comercial:

- tenant;
- document i hash;
- outcome;
- signant declarat;
- provider i via;
- timestamp UTC + locale;
- ids de traça no sensibles;
- versió PDF abans/després de firma si aplica.

Client no veu IP completa, UA cru ni metadata operativa.

## 4.7 Privacitat i copy legal

- eliminar afirmacions genèriques «eIDAS» si no estan justificades;
- Art. 13 accessible abans de decidir;
- explicar finalitat, responsable, evidències capturades i contacte;
- IP server-side; eliminar dependència ipify;
- no carregar analytics abans de consentiment si no són estrictament necessàries.

## 4.8 Accessibilitat i responsive

DoD:

- 320 px sense scroll horitzontal;
- CTA accessibles amb teclat;
- ordre de focus i focus visible;
- `aria-live` per processing/error/outcome;
- labels reals al canvas/pad i alternativa si el pad no és usable;
- contrast AA;
- ca/es/en complets, inclòs el pad;
- PDF no és l'única font d'informació.

## Fitxers

- `apps/tenant-portal/src/App.tsx`
- `apps/tenant-portal/src/pages/PublicSignPage.tsx`
- component comercial nou recomanat: `CommercialDecisionPage.tsx`
- `apps/tenant-portal/src/features/signing/components/SignaturePad.tsx`
- `supabase/functions/process-signing-token/index.ts` (branca genèrica intacta)
- Edge noves o separades:
  - `resolve-commercial-decision-token`
  - `process-commercial-decision-token`
- shared public branding/locale helpers

## Proves

### Seguretat

- token hash lookup; raw absent en DB/logs;
- GET/HEAD no muta;
- rate limit;
- token revocat/expirat;
- request d'un altre tenant inaccessible;
- body forjat amb altre target ignorat;
- CSP/referrer policy.

### Funcional

- accept quote/agreement/DN;
- decline sense pad;
- doble tab accept vs decline;
- retry stamp;
- resultats terminals;
- generic DMS token continua igual.

### A11y/mobile

- Playwright 320/390/768;
- keyboard only;
- axe o equivalent;
- ca/es/en;
- `show_prices=false`.

## DoD

- [x] Client entén document, import i conseqüència abans de decidir.
- [x] Refús sense firma i amb el mateix pes visual.
- [x] Generic DMS no regressa (fall-through a `get_signing_session_public`).
- [x] Snapshot immutable, no dades vives.
- [x] Tokens i headers segurs (hash-only; sense ipify al client).
- [x] Justificant disponible (`get_commercial_decision_receipt` + UI).
- [x] i18n ca/es/en a la pàgina pública (locale del snapshot); a11y mòbil residual (UAT visual).

## Rollback

- deixar de generar tokens comercials;
- tokens/requests existents continuen resolubles fins revocació;
- variant DMS genèrica no depèn del feature flag comercial.
