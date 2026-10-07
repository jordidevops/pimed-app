# Fase 9 — Proves, escala, observabilitat i rollout

> **Prerequisit:** fases implementades que es vulguin declarar completes  
> **Objectiu:** demostrar integritat i escala; no tancar per «sembla funcionar»

## 9.1 Suites

### SQL/domain

Fitxer nou recomanat:

```text
supabase/tests/commercial_decision_requests_tests.sql
```

Cobertura:

- constraints/índexs/RLS/revokes;
- quote/amendment accept/reject;
- agreement prepare/sign/decline;
- DN sign/dispute + gates de factura;
- expiry/revoke/supersede/hash mismatch;
- idempotència;
- notifications/outbox;
- portal projections/aïllament;
- DocuSeal mapping si fase 8.

Afegir al runner d'acords els casos que canvien `separate_agreement`; no duplicar assertions contradictòries.

### Concurrència real

Un test SQL d'una sola connexió no demostra first-wins. Crear test d'integració amb dues connexions/transaccions:

1. mateixa request;
2. `accept` i `decline`;
3. `client_op_id` diferents;
4. alliberament simultani;
5. un sol outcome i un sol event comercial terminal;
6. cap deadlock;
7. perdedor rep `already_decided`.

Repetir amb:

- link vs portal;
- portal vs oficina;
- webhook duplicat;
- dues requests simultànies intentant obrir-se pel mateix target.

### Unit/Vitest

- selector target/formalization;
- jerarquia CTA;
- copy/badges/locales;
- keyset cursor;
- totals factura/pendent projectats;
- provider/crèdits;
- mapping de status.

### E2E/Playwright

- tenant envia;
- client `/sign`;
- portal read/decide;
- refresh remot;
- mòbil/a11y;
- fallades de cua/provider.

## 9.2 Perfil d'escala

Seed sintètic separat, mai a seeds normals:

```text
1 tenant gran
100.000 commercial_documents
500.000 commercial_document_lines
100.000 commercial_decision_requests
300.000 deliveries/tokens
500.000 decision events
25.000 invoices
100.000 payment allocations
10.000 requests open
```

Afegir almenys 20 tenants petits per detectar plans que ignoren `tenant_id`.

No persistir aquest dataset al repo com SQL gegant; generar-lo amb script reproduïble.

## 9.3 Queries a explicar

Executar `EXPLAIN (ANALYZE, BUFFERS)`:

1. targeta request a fitxa comercial;
2. pendents tenant;
3. pendents portal per compte;
4. llista portal quote/agreement;
5. llista DN;
6. llista factura;
7. detall factura + allocations/orígens;
8. lookup token hash;
9. job expiry batch;
10. notification/outbox pending.

Gate:

- cap seq scan global en llistes scoped;
- files llegides proporcionals a pàgina/resultat, no al tenant complet;
- índex compost respecta equality columns abans de cursor;
- índex parcial per `open/active`;
- no N+1 des del BFF;
- cap `OFFSET` profund.

Guardar els plans resumits i conclusions a l'implementation log de CF-28, no snapshots volàtils dependents d'una màquina.

## 9.4 SLO inicial

En entorn de prova documentat:

- list/pendents p95 < 400 ms;
- detail comercial p95 < 500 ms sense descàrrega PDF;
- apply DB p95 < 150 ms;
- lookup token p95 < 100 ms;
- cap transacció apply espera xarxa;
- worker email/provider té mètriques separades.

Si l'entorn no permet latència comparable, el gate és:

- pla estable;
- buffers/files acotats;
- locks curts;
- absència de scan global/N+1.

No maquillar l'SLO amb cache que trenqui revocació.

## 9.5 Observabilitat

Correlation id:

```text
commercial_decision_request_id
```

Mètriques mínimes:

- requests created/open/accepted/declined/expired/revoked;
- time-to-decision;
- delivery queued/sent/failed per canal;
- token resolve denied/rate-limited;
- native stamp failed;
- DocuSeal webhook/reconciliation failed;
- apply already-decided conflicts;
- portal projection latency/error;
- queue age/dead-letter.

Logs:

- estructurats;
- tenant/request/provider event ids;
- sense raw token, signature base64, email completa, IP o payload DocuSeal complet;
- errors esperables amb codi estable, no stack sorollós.

Alertes:

- apply/webhook terminal fallit;
- artifact pending massa temps;
- cua email envellida;
- pics de token denied/rate limit;
- inconsistència request terminal vs target status.

## 9.6 Reconciliació

Job idempotent detecta:

- request accepted però target no projectat;
- session/submission completed amb request open;
- result PDF pendent;
- delivery queued sense email log;
- token active d'una request terminal;
- dues requests open (defensa tot i constraint/backfill).

No corregeix silenciosament outcomes contradictoris: registra i alerta.

## 9.7 Retenció

Definir abans de producció:

- request/snapshot/evidència: retenció del document comercial;
- tokens raw: mai persistits;
- token hashes expirats: purga després del període operatiu acordat;
- delivery logs: termini operatiu/DSAR;
- IP/UA: termini mínim justificat;
- signatures/justificants: política DMS/legal;
- email logs: política del sistema de correu.

Documentar a customer portal i registre de tractament.

## 9.8 UAT

Només fixtures 9xxx. No usar `A-2026-0002`. Si es toca exercici fiscal, reobrir-lo al final fins i tot si el smoke falla.

### Matriu mínima

1. Quote `signed_quote`, email nativa, accept.
2. Quote nativa, WhatsApp, decline.
3. Quote expirada.
4. Quote superseded mentre link obert.
5. `separate_agreement`: prepare des d'issued, signar acord, quote acceptada una vegada.
6. Agreement decline i nova versió.
7. DN presencial signat.
8. DN remot disputat i absent de «Per facturar».
9. Reenviar/revocar tokens.
10. Zero crèdits: nativa funciona.
11. DocuSeal completed/declined amb crèdit si fase 8.
12. Portal toggles off/on.
13. Portal named principal.
14. Portal shared mailbox amb nom/càrrec.
15. Factura parcial: total/pagat/pendent i orígens correctes.
16. Dues pestanyes/canals decideixen alhora.
17. Un sol document DMS amb V1/V2.
18. 320 px + keyboard + ca/es/en.

Evidència UAT:

- ids/números 9xxx;
- resultat esperat/real;
- captures només si aporten valor;
- DB assertions;
- cleanup/reobertura fiscal;
- deute residual explícit.

## 9.9 Rollout

### Etapa 0 — intern

- feature flag només tenant seed;
- nativa;
- sense portal/DocuSeal;
- monitoritzar una setmana o finestra equivalent de prova.

### Etapa 1 — pilot

- pocs tenants;
- core natiu;
- mail server;
- rollback per flag;
- suport amb query de reconciliació.

### Etapa 2 — portal read

- toggles opt-in;
- staff preview;
- revisar logs d'aïllament/latència.

### Etapa 3 — portal decide

- principals nominatius primer;
- shared mailbox després dels tests d'evidència.

### Etapa 4 — DocuSeal

- només tenants configurats;
- saldo/reconciliació monitoritzats.

### Retirada legacy

Només quan:

- cap request activa usa camí antic;
- hub llegeix nou domini;
- suites QT/CT/CF verdes;
- backfill actiu complet;
- rollback documentat;
- migració separada retira triggers/columnes legacy.

## 9.10 Verificació final

- `supabase db reset`;
- suites SQL comercials, signing, agreements, portal i email;
- types regenerats;
- lints/typecheck/tests apps afectades;
- advisors de seguretat/performance;
- E2E/UAT;
- [`CHECKLIST.md`](./CHECKLIST.md);
- STATUS/EXECUTION/custom-portal actualitzats.

## DoD

- [ ] Integritat concurrent demostrada.
- [ ] Escala EXPLAIN documentada.
- [ ] SLO o gate de buffers/plans superat.
- [ ] Observabilitat i reconciliació operatives.
- [ ] Retenció/legal documentades.
- [ ] UAT completa.
- [ ] Rollout/rollback provats.
- [ ] Legacy no retirat prematurament.
