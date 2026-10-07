# Fase 8 — DocuSeal comercial

> **Estat 2026-10-07:** Tall 1–4 ✅ + review fixes (`00008`) + throughput poll/reconcile (`00012`, backoff UI). Gate F / SLO / UAT residual. CS-D58–D60.  
> **Tall:** opcional, després del core natiu i portal  
> **Prerequisits:** fases 2–5; fase 7 només si es vol entrada des del portal; control d’enllaços CS-D58 ✅  
> **Cost:** consumeix crèdits; nativa continua sempre disponible si està habilitada

## Objectiu

Permetre que el tenant triï DocuSeal per documents importants sense crear una segona màquina d'estats comercial ni un segon document DMS.

## 8.1 Disponibilitat

Mostrar DocuSeal només si:

- signing feature efectiva;
- provider DocuSeal configurat/actiu;
- crèdits > 0;
- target té PDF/version canònica;
- template/submission compatible.

Si no:

- ocultar el selector si només hi ha nativa;
- o mostrar DocuSeal deshabilitat amb causa concreta;
- mai bloquejar la firma nativa per falta de crèdits.

## 8.2 Selecció de provider

Al diàleg de fase 3:

- default `native`;
- `DocuSeal` com opció explícita;
- ajuda: «Servei extern amb consum de crèdit»;
- confirmació del consum abans de crear submission.

Canviar provider en request open:

1. revocar/cancel·lar intent actiu anterior;
2. conservar request/snapshot;
3. crear intent del nou provider;
4. crear delivery/token/URL nou;
5. auditar `provider_changed`.

Mai dos providers actius per request.

## 8.3 Enllaç request ↔ submission

Contracte mínim:

- `decision_request_id` a metadata/bridge server-side;
- `signing_submissions.external_id` idempotent derivat de request + attempt;
- `source_document_id = rendered_document_id`;
- source version = `document_version_id`;
- result version id sota el mateix document DMS;
- participant/signer únic V1.

No confiar en metadata retornada pel browser. El webhook resol submission persistent → request.

## 8.4 Crèdits

- reservar/consumir una sola vegada quan DocuSeal accepta la creació de submission;
- idempotency key estable per attempt;
- retry de timeout consulta submission existent abans de consumir;
- webhook completed/declined no consumeix;
- cancel·lar després de crear no reemborsa automàticament tret que el contracte actual de crèdits ja ho permeti;
- error abans de crear submission no consumeix.

Tests de saldo abans/després obligatoris.

## 8.5 Webhook

Ampliar `supabase/functions/docuseal-webhook/index.ts`.

### Dedupe

- `webhook_event_id` únic via infraestructura existent;
- processing idempotent;
- events fora d'ordre tolerats;
- completed terminal guanya sobre viewed/started;
- completed vs declined impossible de reescriure després d'apply first-wins.

### Mapping

| DocuSeal | Domini |
|----------|--------|
| form/submission completed | `apply(... accepted ...)` |
| submission/form declined terminal | `apply(... declined ...)` |
| expired | expirar intent/token; request expira segons la seva pròpia validesa |
| cancelled per tenant | revocar intent, no client decline |
| error | request open + provider_failed event + retry visible |

### PDF resultat

En completed:

1. descarregar/verificar result;
2. afegir `document_version` al mateix DMS document;
3. guardar `result_document_version_id` idempotent;
4. aplicar outcome o reconciliar si apply ja s'ha fet;
5. preview comercial apunta a result.

Si PDF falla però DocuSeal diu completed:

- no perdre outcome;
- marcar `artifact_pending/failed`;
- job de reconciliació;
- alerta operativa;
- no crear una segona fila DMS.

## 8.6 Client UX

### Link extern (només destinatari del correu)

- `/sign/:token` mostra snapshot/resum i CTA «Continuar a DocuSeal»;
- no demana pad PiMed;
- retorn a pàgina d'estat amb polling acotat;
- refús a DocuSeal es reflecteix com declined.
- El tenant **no** rep ni veu aquest token/URL (CS-D58). Canvi de provider: nou delivery + correu/portal, sense retornar URL al tenant-portal.

### Portal

- mateix resum;
- redirecció DocuSeal des de sessió client (no staff);
- retorn al portal;
- estat «Processant resposta» fins webhook;
- fallback a nativa només amb nova acció del tenant, no automàtic.
- Actor `staff`: sense redirect DocuSeal ni URL (CS-D59).

## 8.7 Seguretat

- validar signatura del webhook segons contracte DocuSeal;
- secrets només a Edge;
- URL externa curta/TTL;
- no logar payload complet amb PII/signatures;
- allowlist de status/provider ids;
- request tenant/submission tenant verificats;
- **zero** `embed_src` / slug / `signer_links` / `docuseal_signing_url` a respostes del tenant-portal (CS-D58);
- fallada d'email no mostra URL DocuSeal al tenant (CS-D60).

## Proves

1. Provider ocult/deshabilitat segons config/crèdits.
2. Native amb 0 crèdits.
3. DocuSeal consumeix exactament un crèdit.
4. Retry timeout no duplica submission/crèdit.
5. completed → accepted/signed segons target.
6. declined → rejected/declined/disputed segons target.
7. webhook duplicat/fora d'ordre.
8. PDF resultat = nova versió mateix document.
9. artifact download failed + reconciliació.
10. canviar provider revoca l'anterior.
11. cross-tenant/metadata forjada.

## DoD

- [x] Selector només quan realment usable. *(tall 2: `canSignWithDocuseal`; default nativa; ack crèdit platform)*
- [x] Crèdit idempotent. *(tall 1: camí `action=sign` + `external_id` estable request+attempt)*
- [x] Webhook entra per apply únic. *(tall 1: `apply_commercial_decision_from_docuseal_submission`, via=`provider`)*
- [x] Decline comercial funciona. *(webhook declined + refús PiMed a `/sign`)*
- [x] PDF firmat al mateix DMS. *(reuse F5 + attachSignedDocument existent)*
- [x] Native intacta sense crèdits. *(default nativa; DocuSeal només si gated)*
- [x] Reconciliació observable. *(tall 4: `artifact_*` events/metadata + `reconcile-docuseal-signed-artifacts` cron; UI banner)*
- [x] CTA `/sign` DocuSeal sense URL al tenant. *(continue RPC amb token destinatari)*
- [x] Portal redirect DocuSeal. *(tall 3: `continue_customer_portal_pending_docuseal` grant-only; BFF `continue_docuseal` + CTA/poll; staff CS-D59)*
- [x] Canvi de provider en request open. *(tall 4: `prepare_commercial_decision_signing_attempt` + `provider_changed`; un sol bridge actiu)*

## Review fixes (post tall 4)

Migració `20261229000008` + edge/UI:

- reconcile només service_role + `signing_ops_job_runs`;
- CS-D58: `artifact_retry_url` interna; vista tenant sense URL DocuSeal;
- attach `ok` només amb `result_document_version_id`;
- bind sense catch silenciat; abort prepare si el send falla;
- dual-path decline → supersede/cancel DocuSeal best-effort;
- UI `/sign` no fingeix terminal si el server segueix `open`.

**Gate E:** residual UAT a F9 (rate-limit webhook, UAT 9xxx). No marcar escala “neta” només amb aquests fixes.

## Throughput ops (F9 scale tall 1 — 2026-10-07)

Mitigació hotspots (no Gate F / no SLO):

- **Poll `/sign` + portal:** backoff 2→4→8→15→30s + pause si tab hidden (~12–15 resolves/sessió; abans 40×3s). Helpers `providerWaitPoll`.
- **Reconcile artefacte:** cron `*/2` + batch 50 (`20261229000012`); edge concurrency 5 + soft budget ~22s; `duration_ms` / `detail.backlog_hint` a `signing_ops_job_runs`.
- Capacitat orientativa (no SLO): centenars–~1k attaches/h si PDF/URL és ràpid; si I/O és lent el time budget talla — Signing Ops backlog + «Run reconcile now» com a escape.

**Residual explícit:** webhook DocuSeal sense throttle producte; NAT/IP compartida al poll; seed full / SLO staging / UAT 9xxx (Gate F obert).

## Rollback

Deshabilitar provider comercial DocuSeal. Requests natives i outcomes existents no canvien. Submissions DocuSeal ja creades continuen rebent webhook/reconciliació fins estat terminal.
