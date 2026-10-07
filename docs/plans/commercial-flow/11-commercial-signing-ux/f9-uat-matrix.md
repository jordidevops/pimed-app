# F9 UAT matrix (CF-28 §9.8)

> **Estat:** plantilla buida. **No executada.** No marcar Gate F UAT ✅ fins omplir evidència humana.  
> Fixtures: números **9xxx** només. No usar `A-2026-0002`. Si es toca exercici fiscal, reobrir al final.

| # | Escenari | Fixture 9xxx | Esperat | Real | Evidència / notes | Deute |
|---|----------|--------------|---------|------|-------------------|-------|
| 1 | Quote `signed_quote`, email nativa, accept | | | | | |
| 2 | Quote nativa, WhatsApp, decline | | | | | |
| 3 | Quote expirada | | | | | |
| 4 | Quote superseded mentre link obert | | | | | |
| 5 | `separate_agreement`: prepare + sign acord | | | | | |
| 6 | Agreement decline + nova versió | | | | | |
| 7 | DN presencial signat | | | | | |
| 8 | DN remot disputat; absent «Per facturar» | | | | | |
| 9 | Reenviar / revocar tokens | | | | | |
| 10 | Zero crèdits: nativa OK | | | | | |
| 11 | DocuSeal completed/declined + crèdit | | | | | |
| 12 | Portal toggles off/on | | | | | |
| 13 | Portal named principal | | | | | |
| 14 | Portal shared mailbox + nom/càrrec | | | | | |
| 15 | Factura parcial totals/orígens | | | | | |
| 16 | Dues pestanyes/canals decideixen alhora | | | | | |
| 17 | Un sol DMS V1/V2 | | | | | |
| 18 | 320px + keyboard + ca/es/en | | | | | |

## Cleanup checklist

- [ ] Cap exercici fiscal tancat residual
- [ ] Tokens/fixtures 9xxx documentats o purgats
- [ ] Deute residual llistat a README registre
