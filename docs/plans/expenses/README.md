# Despeses d’empleat — pla de producte

> **Estat:** pla de producte / arquitectura — **sense implementació** (revisió 2026-07-23b: retenció purge-on, OCR/SCC, k-anonymity, FX BCE).  
> **Objectiu:** controlar, assignar i reemborsar despeses de treballadors (ticket → revisió → pagament/agrupació), amb personalització per vertical i modes mixtos dins el mateix tenant.

| Document | Contingut |
|----------|-----------|
| [01-domain-and-modes.md](./01-domain-and-modes.md) | Model de dades, modes, IVA, km, multi-divisa, FSM línia/informe, D-INT-12 |
| [02-flows-and-surfaces.md](./02-flows-and-surfaces.md) | Fluxos, reclassificació auditada, permisos, portal, offline |
| [03-integrations-ai-comms.md](./03-integrations-ai-comms.md) | Export/nòmina, IA/OCR, aclariments MVP, límit amb comunicació |
| [04-compliance-retention-gdpr.md](./04-compliance-retention-gdpr.md) | Retenció fiscal, RGPD, IBAN/pagament, DPA export |
| [prompt-internal-comms.md](./prompt-internal-comms.md) | Prompt per planificar la comunicació interna en una altra conversa |

---

## Posicionament

**Què resol PiMed**

- Alta de despeses de treball (pagades per l’empresa o pel treballador a reemborsar).
- Associació opcional a projecte / work log / desplaçament.
- Revisió i aprovació administrativa.
- Agrupació per notificar l’empleat i preparar el hand-off a nòmina.
- Assistència IA (OCR/classificació) quan el tenant té IA configurada.

**Fora d’abast (gestoria / ERP / mòduls futurs improbables)**

- Motor de nòmina, asientos comptables, facturació avançada.
- Competir amb xats (Google Chat, Teams, WhatsApp) com a producte de missatgeria.

**Hand-off:** export de dades, webhooks, `tenant_integrations` i contracte estable de payload perquè el flux continuï amb apps externes o, algun dia, un mòdul intern.

---

## Decisions tancades

| ID | Decisió |
|----|---------|
| **EXP-1** | Una sola entitat de línia: evolució de `data.project_expenses` (D-INT-12 Opció A). No taula paral·lela `employee_expenses`. |
| **EXP-2** | Modes mixtos al mateix tenant: `line_first`, `report_first` o `both`, resolts per cascada arquetip → tenant → departament → empleat. |
| **EXP-3** | Agrupació via `expense_reports` (empleat o admin); cada línia conserva el seu `project_id`. |
| **EXP-4** | Aclariments MVP = entity timeline + notificació/email. Comunicació transversal = estudi a part (`prompt-internal-comms.md`). |
| **EXP-5** | Comptabilitat / nòmina motor fora d’abast; només export i preparació d’integració. |
| **EXP-6** | Per a field-service, `project_expenses` és el comprovant financer i `project_materials` és el consum operatiu. Una compra pot enllaçar tots dos, però no pot duplicar el cost ni ser dues fonts de veritat. |
| **EXP-7** | Els rebuts reutilitzen el flux DMS `request-upload` → `confirm-upload`, les quotes i la cua de destrucció existents; no hi ha pujades directes al bucket ni URLs de Storage persistides a la base de dades. |
| **EXP-8** | Les transicions de despesa, informe i batch només passen per RPCs transaccionals amb permisos explícits, idempotència i auditoria de canvi d’estat. |
| **EXP-9** | Després de `submitted`: **immutables** = import/IVA, moneda, `employee_id`, `occurred_at`, `line_kind`/km. **Reclassificables** (`expenses.reclassify`) = projecte/scope/`is_billable`/`paid_by`/categoria. **Rebuts:** set immutable excepte **append-only** via `expenses.append_receipt` mentre `needs_info` (auditat). Adjunts de timeline ≠ rebuts oficials. |
| **EXP-10** | Línia amb desglossament IVA (`tax_base_cents`, `tax_rate_bps`, `tax_amount_cents`, `amount_cents` = total). Categories poden marcar `tax_exempt` (p. ex. km). |
| **EXP-11** | Divisa base del tenant (default `EUR`). Totals en base; FX = BCE (EXP-17) snapshotat; sense rate no s’envia. |
| **EXP-12** | Tipus de línia `receipt` \| `mileage`. Kilometratge: `distance_km` × tarifa tenant (€/km Hisenda o pròpia) → import calculat; opcional enllaç a segment `TRAVEL`. |
| **EXP-13** | IBAN viu a **HR** (`employee_private_profiles`, xifrat + reveal auditat) — **no** es copia a línies/informes de despeses. Reemborsament V1: hand-off a gestoria/nòmina (PiMed **no** emet transferències). L’export de despeses pot incloure IBAN **opcionalment** (perfil d’export + `expenses.settle`) amb el mateix control de reveal/audit que HR; per defecte només `has_iban` / `iban_last4`. |
| **EXP-14** | Retenció: `expenses_retention_years` default **10**, rang **4–10**. Purge **actiu per defecte** (`expenses_retention_purge_enabled = true`). Desactivar el purge exigeix acció explícita + audit (minimització: el sostre és efectiu, no cosmétic). |
| **EXP-15** | RGPD: base legal, DPA gestoria, categories restringides, drets. OCR/IA: subencarregats + SCCs / acceptació transferència abans d’enviar rebuts fora EEE/adequació. |
| **EXP-16** | `admin_batch` V1 = **un sol `employee_id` per batch**. |
| **EXP-17** | FX: font per defecte **tipus de referència BCE** del dia de `occurred_at` (snapshot a `submitted`); es persisteix `fx_rate_source`, `fx_rate_date`. Sense taxa → no enviar. |
| **EXP-18** | `expenses.view_project_costs`: k-anonymity **≥ 5** empleats distintes a la cohort (servidor); per sota, només total agregat sense files per persona. |

---

## Roadmap d’implementació (futur)

| Fase | Entregable | Notes |
|------|------------|-------|
| **EX0a** | Contracte de domini + field-service | Extendre `project_expenses` (IVA, mileage, cancelled); crear `expense_reports` + FSM informe; materials vs comprovant |
| **EX0b** | Storage, offline, RLS i FSM | Feature flag; permisos incl. `expenses.reclassify`; retenció ≥4 anys; idempotència offline multi-fitxer; auditoria |
| **EX0c** | Compliment | Settings retenció; text informatiu empleat; contracte export/DPA; vistes projecte sense sobreexposar PII |
| **EX1** | Cua admin + alta tenant UI | Aprovació; `needs_info`; reclassificació auditada |
| **EX2** | Portal empleat | Token→`employee_id` forçat; pujar ticket; km; cancel·lar draft |
| **EX3** | Mode `report_first` + batches admin | FSM parcial approve/reject; agrupació nòmina + notificació en divisa base |
| **EX4** | Export / webhooks despeses | Payload amb IVA + conversió; IBAN opcional des de HR (EXP-13), no desat a la línia |
| **EX5** | OCR / IA assist | Preomplir IVA/total; no bloqueja sense IA |
| **EX6** | Fonts inbound addicionals (diferida) | `public_form` i email amb antispam, atribució, quarantena PII |

### Gates obligatoris d’EX0

- Una despesa de `work_log_id` valida el mateix tenant, empleat i projecte; no pot creuar projectes, empleats o tenants.
- Una compra de material pot enllaçar una sola despesa financera mitjançant `project_material_id`; les vistes de cost no en dupliquen l’import.
- Les proves RLS/RPC cobreixen tenant creuat, empleat portal (token no pot suplantar `employee_id`), `expenses.review` / `expenses.reclassify`, transicions il·legals, doble inclusió en batch i idempotència de `client_op_id`.
- Les proves de Storage cobreixen quota, MIME/mida, upload pendent caducat, fallada parcial multi-fitxer (línia no passa a `submitted` fins que tots els rebuts requerits estan confirmats), retenció 4–10 amb purge **on** per defecte, i destrucció asíncrona idempotent.
- FSM informe: rebuig total, rebuig parcial de línies i `cancelled` de draft coberts per tests.
- Les cues i exports fan cursor pagination sobre els índexs d’EX0; no usen offset sobre tot l’històric.
- Export de prova inclou camps IVA i `amount_base_cents` / `fx_rate_source=ecb` (o `manual_admin` auditat) si la línia no és en divisa base.
- Batch admin: test que multi-empleat falla; `view_project_costs` amb cohort &lt; 5 no retorna files per persona.

---

## Relacionat

| Document | Relació |
|----------|---------|
| [prompts/shared/work-logs-time-attendance-integration.md](../../../prompts/shared/work-logs-time-attendance-integration.md) | D-INT-12 (despeses ↔ segments TRAVEL) |
| [prompts/projectes/plan.md](../../../prompts/projectes/plan.md) | Esquema proposat `project_expenses` |
| [product-design/03-sector-profiles.md](../../product-design/03-sector-profiles.md) | Arquetips / onboarding / addons |
| [product-design/07-mobile-and-ai-leverage.md](../../product-design/07-mobile-and-ai-leverage.md) | OCR ticket → expense |
| [product-design/06-integracions.md](../../product-design/06-integracions.md) | OCR providers, Hub & Spoke |
| [product-design/08-erp-crm-checklist.md](../../product-design/08-erp-crm-checklist.md) | Checklist despeses |
| [product-design/18-employee-portal-architecture.md](../../product-design/18-employee-portal-architecture.md) | Superfície portal empleat |
| [checkin/plan-effective-work-time.md](../checkin/plan-effective-work-time.md) | `expense_ref_id` als segments; dietes diferides aquí |
| [checkin/STATUS.md](../checkin/STATUS.md) | Estat control horari; enllaç a aquest pla |
| [employee-import/README.md](../employee-import/README.md) | Empleats com a eix; no despeses |
| [Holded_Payfit/](../Holded_Payfit/) | Connectors nòmina/comptabilitat (consumidors futurs) |
| [field-service/](../field-service/) | Ordres de camp; expenses `line_first` no bloqueja el MVP FSM, però EX0a/EX0b són gate abans d’integrar alta de despesa al close-out mòbil |
| [employees/](../employees/) / migració `employee_private_profiles` | IBAN + NSS xifrats (font de veritat per EXP-13) |
| [recruitment/01-domain-and-gdpr.md](../recruitment/01-domain-and-gdpr.md) | Patró de rigor RGPD/retenció a reutilitzar (no copiar cegament: candidats ≠ empleats) |
| [checkin/plan-attendance-legal-access.md](../checkin/plan-attendance-legal-access.md) | Patró retenció ≥4 anys + purge batched |
