# 03 — Integracions, IA i comunicació

> Part del pla [Despeses d’empleat](./README.md). Sense implementació.

## 1. Límits amb gestoria i ERP

PiMed **no** substitueix:

- Motor de nòmina (PayFit, A3, Sage, …)
- Comptabilitat / facturació (Holded, Odoo, …)

Les gestories aconsellen PiMed als clients per operació diària (despeses, control horari, projectes); elles porten facturació i comptabilitat.

El mòdul de despeses ha de deixar el flux **continuable** mitjançant:

| Mecanisme | Ús |
|-----------|-----|
| Export CSV/JSON amb **perfils** | Mateix patró que export nòmina assistència |
| Webhooks outbound | Esdeveniments `expense.*` / `expense_report.*` |
| `tenant_integrations` + secrets Vault | Connectors futurs |
| `external_refs` a línies/informes | Idempotència i reconcilació |
| API / RPC estables | Integració mòdul intern futur sense reescriure el domini |

---

## 2. Export i hand-off a nòmina

### Contingut mínim del payload (contracte conceptual)

Per línia / per batch:

- `tenant_id`, `employee_id`, identificadors fiscals si disponibles (NIF via empleat)
- `amount_cents`, `currency`, `tax_base_cents`, `tax_rate_bps`, `tax_amount_cents`, `tax_exempt`
- `amount_base_cents`, `fx_rate_to_base`, `fx_rate_source`, `fx_rate_date`, `base_currency`
- `paid_by`, categoria, descripció, `line_kind` (+ `distance_km` / tarifa si mileage)
- Dates (despesa, aprovació, cua)
- `project_id` opcional, `is_billable`
- `report_id` / batch id, estat, `external_refs`
- `receipt_document_id`(s), hash/metadades i estat de disponibilitat; **mai** signed URL persistent
- **No** camp IBAN a la línia ni a `expense_reports`. Font: `data.employee_private_profiles` (xifrat).
- Payload per defecte: `has_iban`, `iban_last4` (suficient per validar que hi ha compte sense exposar el clar).
- Payload opcional (flag del perfil d’export + permís `expenses.settle`): IBAN en clar, desxifrat en el moment de l’export amb **el mateix audit de reveal** que la fitxa d’empleat (no cachejar el clar a cues ni a `external_refs`).
- El pagament el resol la gestoria/nòmina (o tresoreria externa); PiMed V1 **no** inicia SEPA/transferències.

El consumidor extern recupera el document per API autenticada sota demanda o enllaç de compartició amb expiració curta.

**Base legal de la cessió a gestoria:** tractament per compte del responsable (tenant) amb encarregat (gestoria) sota DPA; veure [04](./04-compliance-retention-gdpr.md).

**Còpies fora de PiMed:** un CSV/JSON descarregat o enviat per webhook **no** està subjecte al purge de PiMed. La UI d’export i la documentació del tenant recorden explícitament que cal alinear la retenció a la gestoria/nòmina amb la política del tenant (mateix problema operatiu que a ATS amb exports). PiMed no pot esborrar còpies externes.

### UI / backend

Reutilitzar l’experiència de **payroll export profiles** del control horari:

- [AttendancePayrollExportProfilesSection](../../../apps/tenant-portal/src/features/attendance/components/settings/AttendancePayrollExportProfilesSection.tsx)
- Spike A3/Sage: [spike-d3-a3-sage-payroll-export.md](../checkin/spike-d3-a3-sage-payroll-export.md)

Fase **EX4:** perfils d’export específics de despeses (o ampliació del connector amb `source_mode` despeses).

Confirmació de “ja reemborsat” pot ser:

1. Manual a PiMed després que la gestoria processi el fitxer, o
2. Callback/webhook d’un connector futur.

Sense (2), (1) és suficient per V1.

L’acció manual inclou actor, data, batch i una referència opcional de pagament a `external_refs`; és idempotent i no pot tornar a liquidar una línia tancada.

---

## 3. IA i OCR

Referències:

- [07-mobile-and-ai-leverage.md](../../product-design/07-mobile-and-ai-leverage.md) — `ocr.receipt`
- [06-integracions.md](../../product-design/06-integracions.md) — Mindee / Textract / DocAI
- Settings tenant AI existents (`tenant_ai_config`)

**Comportament**

- Si el tenant **no** té IA: flux manual (foto + camps).
- Si té IA: opcionalment preomplir total, base, IVA, data, comerciant, categoria; l’usuari confirma abans de `submitted`.
- L’IA **assisteix**; no aprova ni substitueix la revisió admin (excepte auto-aprovació futura sota llindar, fora del MVP).
- OCR sobre categories `restricted_health` no canvia l’ACL: el resultat queda subjecte als mateixos permisos que el rebut.

`source = ai_ocr` quan la línia neix del pipeline OCR (encara que l’usuari confirmi).

**Transferències internacionals / subencarregats (obligatori abans d’EX5):**

- Proveïdors típics (Mindee, AWS Textract, Google DocAI, LLMs) poden tractar dades fora de l’EEE.
- PiMed manté llista de subencarregats d’OCR/IA i DPA plataforma↔proveïdor (SCC o mesura d’adequació quan calgui).
- El tenant ha d’haver acceptat a settings AI/OCR la transferència internacional (checkbox Art. 13 / informació a l’empleat al portal: “el rebut es pot processar via proveïdor d’OCR/IA, eventualment fora UE”).
- **Sense acceptació del tenant → OCR bloquejat** (flux manual intacte). Mateix patró que recruitment per LLMs ([03-email-inbound-and-ai.md](../recruitment/03-email-inbound-and-ai.md)).

**Contracte operatiu d’OCR:** EX5 crea una cua PGMQ dedicada mitjançant RPC, amb `idempotency_key` per rebut, límit configurable per tenant/dia i worker `service_role`. El worker només pot llegir rebuts confirmats, desa un resultat normalitzat i no modifica import, categoria ni estat sense confirmació humana. Errors reintentables passen per QueueRunner/DLQ; no s’invoca OCR des de triggers.

---

## 4. Aclariments vs comunicació interna

| Necessitat | On es resol |
|------------|-------------|
| “Falta el NIF al ticket” lligat a una despesa | MVP despeses: timeline + notificació ([02 §5](./02-flows-and-surfaces.md)) |
| Xat general empresa ↔ empleats / entre usuaris | **Estudi a part** — [prompt-internal-comms.md](./prompt-internal-comms.md) |

Motius de separar-ho:

- Evitar construir un competitor de Chat/Teams/WhatsApp sense estratègia.
- Identitat dual: el mateix humà pot ser `profiles` (usuari app) i `employees` (portal); canals confusos si es barregen sense model.
- El portal empleat pot no tenir compte Auth; cal canal que arribi igualment (email / portal token).

Patró de referència extern: Odoo “Enviar mensaje” (persisteix a l’app + notificació email). A PiMed, el més proper avui és **entity timeline** (comentaris, @mentions, notificacions) — adequat per a entitats, no com a DM genèric.

---

## 5. Esdeveniments / automatitzacions (preparació)

Esdeveniments d’audit / webhook proposats:

| Event | Quan |
|-------|------|
| `EXPENSE_SUBMITTED` | Línia o informe enviat |
| `EXPENSE_APPROVED` / `REJECTED` / `NEEDS_INFO` | Revisió |
| `EXPENSE_BATCH_CREATED` | Admin batch |
| `EXPENSE_REIMBURSED` / `SETTLED` | Liquidació |
| `EXPENSE_OCR_SUGGESTED` | Resultat IA (opcional) |
| `EXPENSE_SUBMISSION_MODE_CHANGED` | Canvi de cascada tenant/departament/empleat; inclou nivell i valor anterior/nou, no reclassifica fluxos en curs |
| `EXPENSE_RECEIPT_APPENDED` | `append_receipt` en `needs_info` |
| `EXPENSE_RETENTION_PURGE_DISABLED` | Tenant desactiva el purge (minimització) |

Compatible amb el motor d’automatitzacions i entity timeline quan s’implementi EX0+.

---

## 6. Criteris d’acceptació del pla (documentació)

Aquest paquet de docs es considera tancat quan:

- [x] Modes mixtos + cascada documentats
- [x] Domini línia + informe / batch + FSM de rebuig parcial documentat
- [x] EXP-9: immutables vs reclassificació auditada (sense contradicció 01↔02)
- [x] IVA, multi-divisa, kilometratge, `cancelled` documentats
- [x] Fora d’abast motor nòmina + EXP-13 IBAN a HR (no a la línia; export opcional auditat)
- [x] Retenció amb purge **on per defecte** + sostre 10 anys efectiu ([04](./04-compliance-retention-gdpr.md))
- [x] OCR: SCCs / acceptació transferència; export: nota còpies externes
- [x] k-anonymity costos de projecte; batch un empleat; `append_receipt` vs timeline
- [x] Font FX = BCE (EXP-17)

Implementació = fases EX0–EX6 al [README](./README.md); no forma part d’aquest lliurable.
