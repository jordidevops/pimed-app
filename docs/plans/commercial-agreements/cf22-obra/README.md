# CF-22 — Obra i instal·lació

> **Estat:** 📄 especificat, **no implementat** (2026-10-06)  
> **Depèn de:** nucli CT ✅ · CF-9 ✅ · CF-17/CF-26 ✅ · **No** CF-21  
> **Flux:** [`../commercial-flow/EXECUTION.md`](../commercial-flow/EXECUTION.md) · [`../commercial-flow/STATUS.md`](../commercial-flow/STATUS.md)  
> **Pare:** [`../pla-pressupost-contracte-acords.md`](../pla-pressupost-contracte-acords.md) §11.3

## Objectiu

`kind='project'` + **fites** + **seguiment** contractat/executat/facturat/avanços. Mateix aggregate `commercial_agreements`. Sense taula `obra`.

## Què NO aporta

| Ja existeix | On |
|-------------|-----|
| Bestreta / avanços | `payments` + FIFO projecte (CF-17/CF-26) |
| Ordre de canvi | `quote_amendment` → `authorized_total` (CF-9) |
| Entregues parcials | DN progressius (CF-26) |
| Acord firmat | `kind=specific` + prepare |
| Label «Obra puntual» | Copy de `specific` al prepare — **conflicte** amb `project` |

Tall 3 #5 ja està **parcialment** cobert sense CF-22. Aquest epic afegeix fites + dashboard + kind. No desbloqueja bestretes.

## Criteri d’acceptació

[`../../commercial-flow/05-acceptance-and-gates.md`](../../commercial-flow/05-acceptance-and-gates.md) Tall 3 #5 amb definicions a [`00-decisions.md`](./00-decisions.md).

## Com implementar

1. Llegeix [`00-decisions.md`](./00-decisions.md). No reobris O-D* sense documentar.
2. **Una fase per sessió**, ordre de la taula.
3. Checkboxes a la fase + [`CHECKLIST.md`](./CHECKLIST.md).
4. Tancar fase → STATUS + EXECUTION + registre aquí.
5. **Prohibit** reusar `commercial_agreement_billing_periods` com a fites.

| Ordre | Fase | Fitxer | Notes |
|------:|------|--------|-------|
| 0 | Decisions | [`00-decisions.md`](./00-decisions.md) | Tancades amb el pla |
| 1 | kind=project | [`01-fase-kind-project.md`](./01-fase-kind-project.md) | Desbloqueig; sol no val |
| 2 | Schema fites | [`02-fase-milestones-schema.md`](./02-fase-milestones-schema.md) | Taula + RPC + tests |
| 3 | UI fites | [`03-fase-milestones-ui.md`](./03-fase-milestones-ui.md) | Detall acord |
| 4 | Seguiment | [`04-fase-tracking.md`](./04-fase-tracking.md) | Targeta OS/acord |
| 5 | Canvis | [`05-fase-change-orders.md`](./05-fase-change-orders.md) | **Opcional** |
| 6 | Proves/docs | [`06-fase-tests-docs.md`](./06-fase-tests-docs.md) | Suite + UAT |

**V1 tancable** = **1–4 + 6**. Fase 5 pot quedar diferida amb copy honest.

## Errors del primer esborrany (corregits)

1. Executat indefinible → **O-D7** (DN issued totals).
2. `%` i import dobles → **O-D11** (`amount_cents` font).
3. Permís `invoices.manage` → **owner/manager** (com prepare).
4. Tall `a` com a producte → només desbloqueig.
5. «Wire annex» màgic → fase 5 = enllaços + deute, no re-firma auto.
6. Backlog 04 «variants» → **fora** (O-D8).
7. N:M acord–OS ignorat → **O-D10** (seguiment per projecte).
8. Completar fita ≠ facturar → **O-D12**.
9. Copy «Obra puntual» = specific → reetiquetar a fase 1.

## Fora d’abast

Variants/opcions, retencions, IPC, Verifactu/SII, Holded API, billing_periods com a fites, taula `obra`, auto-fita des de DN, auto-re-firma en ampliació, numeració `C-*`.

## Fitxers calents

- Kind gate: `20261194000001_commercial_agreement_framework.sql`
- Prepare: `api.prepare_agreement_from_quote` (`20261206000001_…`)
- UI: `PrepareAgreementDialog.tsx`, `ProjectAgreementsSection.tsx`
- Avanços: `20261160000009_…`, `20261216000003_delivery_balances_fifo.sql`
- Immutable versions: `trg_commercial_agreement_versions_immutable`

## Registre

| Data | Què | Següent |
|------|-----|---------|
| 2026-10-06 | Pla `cf22-obra/` escrit | Fase 1 quan es prioritzí |
