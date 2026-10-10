# Notes de correcció — pla `quote-first_vocabulary_plan_953744b4`

> **Data:** 2026-10-08.  
> **Font de veritat de producte:** [`06-sales-entry-modes-quote-first.md`](./06-sales-entry-modes-quote-first.md) + estudi `quote-first_options_study`.

El pla Cursor `953744b4` va formalitzar bé el **vocabulari tancat** de plantilles. Aquestes afirmacions seves queden **corregides** (guanya el codi / objectiu de producte actual):

| Afirmació 953744b4 | Correcció |
|--------------------|-----------|
| Pressupost sense OS **ni contacte** | `client_id` és **NOT NULL**. Orphan = sense projecte, amb contacte. |
| Mode tenant exclusiu `quote_first` \| `order_first` | **CTAs duals** al mateix tenant; preferència d’arquetip opcional, no interruptor. |
| Orphan com a «canvi central» per defecte | No és requisit; D1 obert (C prospect / B orphan / D híbrid). |
| Wizard sense contacte escrivint només `buyer_snapshot` | Vàlid com a idea futura de domini; **fora de V1** (trenca DDL). |

**Es conserva del 953744b4:**

- Vocabulari per família = contracte.
- Validació unknown fields (avís legacy / error noves).
- Capes contracte vs snapshot intern (`partyName` fallbacks ≠ contracte).
- Alinear portal amb SQL CF-28 (`client_accept` obligatori; `client_reject` no).
- `custom.*` i import Word assistit = diferits.
