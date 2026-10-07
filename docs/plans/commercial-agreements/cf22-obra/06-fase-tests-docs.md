# Fase 6 — Proves, seeds, UAT i documentació

> **Ordre:** 6 · **Depèn de:** 1–4 (5 opcional)  
> **Índex:** [`README.md`](./README.md)

## Objectiu

Tancar CF-22 V1 amb proves verdes, UAT del criteri Tall 3 #5 (amb definicions O-D*), i STATUS/EXECUTION honestos.

## Suite SQL

- [ ] Afegir tests a `run_commercial_agreement_tests` (o suite dedicada `commercial_cf22_*` cridada des del runner).
- [ ] Cobrir: kind project; milestones replace/lock/status; progress RPC (DN/invoice/cancel).
- [ ] No trencar tests CF-21 (billing_periods intactes).

## Seeds (opcional però útil)

- [ ] Seed Riera/Volt: OS + quote `separate_agreement` + acord `project` + 2 fites planned + 0 DN (o 1 DN) — números 9xxx / no contaminar Avui.
- [ ] No deixar exercici fiscal tancat ni dades A-CF25-* cegues.

## UAT humana (oficina)

Checklist mínima:

1. Prepare `kind=project` des de quote acceptat.
2. Definir fites (suma ≤ contractat) → enviar firma → completar.
3. Registrar bestreta al quote (flux existent) → veure avanços al seguiment.
4. Emetre DN parcial → **executat** puja.
5. Facturar DN → **facturat** puja.
6. Ampliació acceptada → contractat puja; banner fase 5 si existeix (o deute documentat).

## Docs a actualitzar en tancar

- [ ] [`CHECKLIST.md`](./CHECKLIST.md) fases [x]
- [ ] [`README.md`](./README.md) registre
- [ ] [`../pla-pressupost-contracte-acords.md`](../pla-pressupost-contracte-acords.md) §11.3 + §12
- [ ] [`../../commercial-flow/STATUS.md`](../../commercial-flow/STATUS.md) CF-22
- [ ] [`../../commercial-flow/EXECUTION.md`](../../commercial-flow/EXECUTION.md)
- [ ] [`../../commercial-flow/05-acceptance-and-gates.md`](../../commercial-flow/05-acceptance-and-gates.md) #5 amb enllaç al pla
- [ ] Types regenerats si hi ha RPC nous

## DoD global V1

- [ ] Fases 1–4 + 6 [x]
- [ ] Fase 5 [x] o explícitament diferida al checklist
- [ ] SQL/TS verds
- [ ] UAT #5 amb O-D6/O-D7
- [ ] STATUS: CF-22 ✅ (o «V1 sense fase 5» honest)
