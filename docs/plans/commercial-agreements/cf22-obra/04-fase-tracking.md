# Fase 4 — Seguiment contractat / executat / facturat

> **Ordre:** 4 · **Depèn de:** fases 1–2 (3 recomanada) · **Bloqueja:** criteri Tall 3 #5 tancable  
> **Índex:** [`README.md`](./README.md) · O-D5, O-D6, O-D7, O-D10

## Objectiu

Una lectura **honesta** i única del progrés econòmic de l’obra a l’OS (i resum a l’acord), reutilitzant saldos existents.

## Definicions (no reinventar)

Veure O-D6 / O-D7 / O-D10 a [`00-decisions.md`](./00-decisions.md).

- **Contractat** = `authorized_total` del projecte.
- **Executat** = Σ DN `issued` d’aquest projecte.
- **Facturat** = Σ factures natives `issued` enllaçades (via `invoice_delivery_notes` actius) + política clara per refs externes si encara s’usen en el tenant.
- **Avançat / bestreta** = reutilitzar el càlcul FIFO / advances del hub (no una tercera fórmula). Si cal, exposar els mateixos cèntims que ja veu el hub DN.

## RPC

`api.get_project_obra_progress(p_project_id)` (nom orientatiu) → jsonb:

```json
{
  "contracted_cents": 0,
  "executed_cents": 0,
  "invoiced_cents": 0,
  "advance_cents": 0,
  "remaining_to_execute_cents": 0,
  "remaining_to_invoice_cents": 0,
  "agreement_id": null,
  "agreement_kind": null
}
```

- `agreement_id`: acord `project` actiu enllaçat si n’hi ha un de preferent; si N, el més recent actiu o null + llista a fase posterior. **V1:** si hi ha >1 acord project enllaçat, retornar el `active` més recent i un flag `multiple_agreements: true`.
- Sense costos CF-20 en aquest RPC.

`api.get_agreement_obra_progress(p_agreement_id)` = suma dels projectes enllaçats + llista per projecte.

## UI

- Targeta a fitxa **OS** (secció comercial / avançat): 4 números + enllaç a hub DN i a l’acord.
- Resum a **detall d’acord** `project`: rollup + taula per OS.
- No duplicar el panell de cobrament; enllaçar.

## Checklist

- [ ] RPC project + agreement.
- [ ] Tests SQL: DN issued compta; draft no; invoice cancelled no; multi-project suma.
- [ ] Targeta OS + resum acord.
- [ ] Copy: «Executat = albarans emesos» (evitar «treball fet» ambigu).
- [ ] Avanços: mateixos cèntims que hub o documentar desviació si n’hi ha.

## DoD

- [ ] UAT Gina/Riera (o seed): contractat visible; després DN executat puja; després factura facturat puja.
- [ ] Definitions O-D6/O-D7 no contradites a UI.

## Fora d’aquesta fase

Rendibilitat CF-20 a la mateixa targeta; forecasting de fites vs executat (nice-to-have posterior: % fites completed vs executat).
