# Posicionament facturació — Opció A

> **Estat:** actiu (2026-10-06) · **Pla d’execució P0:** higiene nativa + copy honest  
> **Relacionat:** [`09-sales-comercial/`](./09-sales-comercial/README.md) (CF-27), [`07b-albara-out-of-scope.md`](./07b-albara-out-of-scope.md) (S-D12)

## Decisió

**Ara (opció A):** PiMed és operacions de camp + cobraments (AR) + export a gestoria/ERP.  
Emet **factura interna** (sèrie PiMed, PDF, enllaç a albarans, cobrament, revisió gestoria, ZIP).  
**No** emet factura fiscal homologada, **no** Verifactu, **no** enviament AEAT.

**Futur (opció C):** homologació fiscal pròpia / Verifactu com a producte posterior.  
Sense data. Sense schema fiscal anticipat en aquest cicle. Quan arribi C caldrà **més** bloqueig de sèries i traçabilitat, no menys.

**No escollida ara (opció B):** partner fiscal certificat com a camí principal (es pot reconsiderar abans de C).

## Glossari (copy i suport)

| Terme | Significat |
|-------|------------|
| **Factura (PiMed)** | Document `commercial_documents` amb `doc_type = invoice`. Número de sèrie assignat per PiMed. Serveix per AR, PDF, gestoria i traçabilitat OS→albarà→factura→cobrament. |
| **Número PiMed** | `doc_number` de la factura interna (sèrie/exercici del tenant). |
| **Ref. ERP / gestoria** | Número al programa fiscal o ERP del client (`commercial_document_external_refs`). **No** substitueix ni redefineix el número PiMed. |
| **Factura fiscal / Verifactu** | Document amb efectes davant AEAT. **Fora d’abast** a l’opció A. |
| **Anul·lar** | Cancel·lar la factura interna a PiMed. **No** és una factura rectificativa AEAT. |
| **Pendent / parcial / cobrat** | Estat de **tesoreria** derivat dels cobraments, no estat fiscal. |

## Regles dures

1. **Ref ERP ≠ número de sèrie PiMed.** En emetre, la sèrie l’assigna PiMed; la ref ERP és un camp opcional a `commercial_document_external_refs`.
2. Cap CTA ni PDF promet “factura legal”, “AEAT” o “Verifactu”.
3. Font de “aquest albarà està facturat” = link actiu a `invoice_delivery_notes`, no un text a l’albarà.
4. Cancel·lar ≠ rectificativa (S-D12).

## Acords (nota temporal)

Els **períodes d’acord** (`commercial_agreement_billing_periods`) encara es marquen facturats amb una **referència externa** (sense crear `invoice` nativa al hub). Això és coherent amb A fins que una fase posterior (P1/P2) enllaci període → factura PiMed. El copy dels acords ha de dir “aquí només ref ERP”; el hub `/sales` sí emet document PiMed des d’albarans.

## Criteri d’acceptació de copy

Cada pantalla de `/sales/*`, modal d’emissió, fitxa de factura, comprovant de cobrament i plantilla PDF d’invoice ha de deixar clar:

- què **sí** és el document (facturació interna PiMed / AR / gestoria),
- què **no** és (Verifactu / AEAT),
- on va el número de l’ERP (camp separat).
