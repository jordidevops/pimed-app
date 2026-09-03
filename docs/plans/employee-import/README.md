# Import d'empleats des de sistemes externs

> Pla operatiu per importar i sincronitzar `data.employees` des de Holded, PayFit, A3, Sage, CSV i altres fonts.  
> **Estat:** MVP CSV ✅ (EI0–EI2); **EI3+ en cua** (2026-07-17).

| Document | Contingut |
|----------|-----------|
| [plan.md](./plan.md) | Pla complet per fases (EI0–EI6), model de dades, UI, API, criteris d'acceptació |

## Relacionat

| Document | Relació |
|----------|---------|
| [Holded_Payfit/estudi-integracio-holded-payfit.md](../Holded_Payfit/estudi-integracio-holded-payfit.md) | Estratègia producte Holded/PayFit; flux mensual export |
| [checkin/spike-d3-a3-sage-payroll-export.md](../checkin/spike-d3-a3-sage-payroll-export.md) | Export nòmina **sortida** (D3.1); requereix NIF alineat |
| [product-design/08-erp-crm-checklist.md](../../product-design/08-erp-crm-checklist.md) | Importació CSV com a imprescindible V1 |
| [product-design/06-integracions.md](../../product-design/06-integracions.md) | Patró Hub & Spoke (referència, no dependència) |

## Resum de fases

| ID | Entregable | Prioritat |
|----|------------|-----------|
| **EI0** | Contracte canònic + regles de match | P0 |
| **EI1** | Import CSV (UI + RPC) | P0 |
| **EI2** | `external_entity_mappings` | P0 |
| **EI3** | Framework connectors (credencials + sync run) | P1 |
| **EI4** | Connector Holded (employees inbound) | P1 |
| **EI5** | Connector PayFit (collaborators inbound) | P2 |
| **EI6** | Re-sync programat + auditoria | P2 |

**Fora d'abast d'aquest pla:** export de variables nòmina (D3.1 ✅), integració comptable Holded (`stripe_holded`), taxonomia absències PayFit.
