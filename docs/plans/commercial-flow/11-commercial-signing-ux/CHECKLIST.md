# Checklist mestre — CF-28 Firma comercial i portal

> Marcar `[x]` només amb el DoD de la fase complet.  
> Índex: [`README.md`](./README.md) · decisions: [`00-decisions.md`](./00-decisions.md)

| Fase | Fitxer | Estat | Gate |
|------|--------|-------|------|
| 0 Decisions | [`00-decisions.md`](./00-decisions.md) | [x] | Contracte 2026-10-06 |
| 1 Correccions honestes | [`01-fase-quick-fixes.md`](./01-fase-quick-fixes.md) | [x] | Native sense crèdits; UI no menteix |
| 2 Domini decisió | [`02-fase-decision-domain.md`](./02-fase-decision-domain.md) | [x] | Apply atòmic + strangler |
| 3 Enviar | [`03-fase-send-ux.md`](./03-fase-send-ux.md) | [x] | Send + agreement + pendent + Més; smoke 3 targets; adjunt PDF diferit |
| 4 `/sign` comercial | [`04-fase-public-sign.md`](./04-fase-public-sign.md) | [~] | Resolve + process + justificant + i18n OK; UAT visual a11y residual |
| 5 Un DMS | [`05-fase-one-dms.md`](./05-fase-one-dms.md) | [~] | Fixes resend/field-map/refús/revert; falta UAT V1/V2 + regressió DMS |
| 6 Portal lectura | [`06-fase-portal-read.md`](./06-fase-portal-read.md) | [x] | CP-Da + review fixes (`00014`); PDF BFF; EXPLAIN formal a F9 |
| 7 Portal decisió | [`07-fase-portal-decide.md`](./07-fase-portal-decide.md) | [x] | CP-Db + review `00018` (mode/apply/UI honesta); UAT concurrència a F9 |
| 8 DocuSeal | [`08-fase-docuseal.md`](./08-fase-docuseal.md) | [x] | Tall 1–4 ✅ Gate E; UAT residual F9 |
| 9 Escala/UAT/rollout | [`09-fase-tests-scale-rollout.md`](./09-fase-tests-scale-rollout.md) | [ ] | Tancament |

## Gate A — UI honesta

- [x] Nativa no depèn de crèdits.
- [x] Draft sense retry PDF impossible.
- [x] Refús quote d'oficina sense pad.
- [x] Estat local refresca.
- [x] Share antic diu «Només entregar».

## Gate B — Domini segur

- [x] Requests/deliveries/tokens/events.
- [x] Token només hashat.
- [~] Apply first-wins amb prova concurrent. *(seqüencial ✅; dual-conn F9 `commercial_decision_concurrency_f9.mjs`)*
- [x] Declined ≠ cancelled.
- [x] Agreement decline.
- [x] `separate_agreement` sense doble firma.
- [x] DN disputat no facturable.
- [x] Feature flag/legacy path verd.

## Gate C — Core natiu

- [x] Correu server + template ca/es/en.
- [x] WhatsApp/copy honestos.
- [ ] `/sign` snapshot responsive.
- [ ] Acceptació amb pad.
- [ ] Refús sense pad.
- [ ] Justificant.
- [~] Un sol document DMS (implementat; UAT 9xxx pendent).
- [ ] Estat remot sense reload manual.

## Gate D — Portal

- [x] Toggles opt-in.
- [x] Quotes/acords (llista + detall/PDF).
- [x] Albarans (llista + detall/PDF).
- [x] Factures + pagat/pendent/orígens (llista + detall).
- [x] Scope tenant/compte (proves SQL allowlist).
- [x] Staff preview.
- [ ] Pendents i decisió.
- [ ] Named/shared mailbox auditats.
- [x] Legal/projecció/retenció actualitzats.

## Gate E — DocuSeal

> **2026-10-07:** Tall 1–4 fets (pont+CTA + selector + portal + switch + reconcile). CS-D58–D60. UAT residual F9.

- [x] Provider/credits gated. *(Send: només si `canSignWithDocuseal`)*
- [x] Consum idempotent. *(external_id request+attempt)*
- [x] Completed/declined → apply únic.
- [~] Webhook dedupe/out-of-order. *(infra existent + apply idempotent; UAT F9)*
- [x] PDF al mateix DMS.
- [x] Reconciliació d'artefacte. *(metadata/events + cron Edge + banner tenant)*
- [x] Selector només quan usable (no exposat sense signing/crèdits).
- [x] Contracte CS-D58–D60 (zero slug/embed/URL al tenant).

## Gate F — Escala i operació

> **2026-10-07:** Hotspots DocuSeal mitigats (poll backoff + reconcile `00012`); EXPLAIN mini+medium. **Gate F global OBERT** (SLO staging, full §9.2, UAT 9xxx).

- [~] Dataset sintètic. *(generator mini/medium/full; medium aplicat local; no CI; full staging-only)*
- [~] EXPLAIN queries crítiques. *(`f9-explain-notes.md` mini+medium; full/SLO residual)*
- [ ] SLO o buffers/plans gate. *(pendent staging)*
- [~] Cues/dead-letter. *(Signing Ops PGMQ + PDF DLQ)*
- [~] Mètriques/alertes. *(«Cal atenció» in-app a Signing Ops; PagerDuty diferit → [`signing-ops-futur.md`](./signing-ops-futur.md))*
- [x] Job reconciliació artefacte. *(F8 + throughput `00012` cron `*/2`×50, concurrency 5)*
- [~] Job inconsistències comercials. *(F9 `reconcile-commercial-decision-ops`, detect-only)*
- [~] Retenció. *(§2ter projection-and-retention.md)*
- [ ] UAT 9xxx. *(plantilla `f9-uat-matrix.md` buida)*
- [ ] `db reset` + suites + types + lints.
- [~] Rate-limit `/sign`. *(edge resolve + decide IP; poll backoff UI; webhook sense throttle producte)*
- [x] Throughput poll DocuSeal. *(backoff 2→30s + visibility pause; no 40×3s)*
- [~] Rollout docs. *(`f9-rollout.md`; sense flip prod)*

## Definició de complet global

CF-28 només pot marcar-se ✅ quan:

1. Gate A–D i F complets.
2. Gate E complet **o** DocuSeal queda explícitament 📦 sense exposar selector comercial.
3. No hi ha doble apply ni doble document DMS en flux nou.
4. El portal mai exposa drafts/costos/notes internes.
5. STATUS/EXECUTION i CP-D reflecteixen l'estat real.

## Pendent explícit que no bloqueja core natiu

- Portal CP-Da/Db.
- DocuSeal comercial.
- OTP/SMS.
- Multi-signatura.
- Pagament online.
- Recordatoris automàtics.
