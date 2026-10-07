# F9 Rollout / rollback (CF-28 §9.9)

> Documentació operativa. **No** flip de flags de producció des d’aquest PR.

## Etapes

| Etapa | Contingut | Rollback |
|-------|-----------|----------|
| 0 Intern | Flag `decision_requests_enabled` només tenant seed; nativa; sense portal/DocuSeal comercial | Apagar flag |
| 1 Pilot | Pocs tenants; core natiu + mail; query reconciliació admin | Flag off + suport amb Signing Ops / commercial reconcile |
| 2 Portal read | Toggles opt-in; staff preview; logs aïllament | Toggles off / kill-switch portal |
| 3 Portal decide | Principals nominatius → shared mailbox | Disable decide toggles; requests open segueixen resolubles per link |
| 4 DocuSeal | Només tenants configurats + crèdits; monitor artifact reconcile | Amagar selector; nativa intacta |

## Criteri retirada legacy

Només quan: cap request activa al camí antic; hub llegeix nou domini; suites QT/CT/CF verdes; backfill actiu complet; rollback documentat; **migració separada** retira triggers/columnes legacy.

**Aquest pla F9 no retira legacy.**

## Suport pilot (etapa 1)

- Admin `/dashboard/signing-ops`: errors, artifact reconcile, commercial reconcile, `already_decided` / `rate_limited` 24h.
- Edge `reconcile-commercial-decision-ops` (detect-only).
- Rate-limit `/sign`: edge `resolve-commercial-decision-token` + decide IP.
