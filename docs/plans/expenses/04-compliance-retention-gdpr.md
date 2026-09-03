# 04 — Compliment: retenció, RGPD i pagament

> Part del pla [Despeses d’empleat](./README.md). Sense implementació.  
> Patró de rigor: [recruitment/01-domain-and-gdpr.md](../recruitment/01-domain-and-gdpr.md), [recruitment/03-email-inbound-and-ai.md](../recruitment/03-email-inbound-and-ai.md) (transferències IA), [04-analytics-and-csv.md](../recruitment/04-analytics-and-csv.md) (k-anonymity).

## 1. Per què aquest document existeix

Les despeses no són un domini “net” de PII:

- Rebuts amb ubicacions i patrons de desplaçament.
- NIF i imports cedits a gestoria via export.
- Possible categoria especial (farmàcia, dieta mèdica).
- OCR/IA amb possibles transferències internacionals.

---

## 2. Retenció de rebuts i línies (EXP-14) — sostre efectiu

| Paràmetre | Valor |
|-----------|--------|
| `expenses_retention_years` | Default **10**, mínim **4**, màxim **10** |
| Origen del tall | `occurred_at` de la línia |
| `expenses_retention_purge_enabled` | Default **`true`** (purge actiu) |
| Desactivar purge | Només amb acció explícita + confirmació UI + fila d’audit (`EXPENSE_RETENTION_PURGE_DISABLED`); avís que implica retenció indefinida i trenca minimització |
| Mecanisme | Job batched + cua de destrucció DMS |
| Rebuig de despesa | **No** esborra el rebut confirmat |

**Per què no opt-in apagat (error ATS):** un terra de 4 anys sense purge per defecte deixa les dades per sempre. Aquí el **sostre de 10 anys és efectiu** perquè el purge corre tret que el tenant el desactivi conscientment.

Uploads pendents no confirmats: TTL curt, independent de la retenció fiscal.

---

## 3. RGPD (EXP-15)

### Rols

| Rol | Qui |
|-----|-----|
| Responsable | El **tenant** |
| Encarregat | PiMed (DPA plataforma–tenant) |
| Encarregat ulterior | Gestoria / nòmina (export); proveïdor OCR/IA (si actiu) |

### Bases legals (orientació de producte; no dictamen jurídic)

| Tractament | Base típica |
|------------|-------------|
| Gestió i aprovació de despeses | Contracte laboral / interès legítim de control de costos |
| Conservació de justificants | Obligació legal (fiscal) |
| Export a gestoria | Contractual + encàrrec de tractament |
| OCR/IA | Interès legítim o contractual + **informació Art. 13** + acceptació de transferència si cal; sense decisions automatitzades amb efectes jurídics sense humà |

### OCR / IA — transferències internacionals

- Llista de subencarregats OCR/IA a la documentació de privacitat de la plataforma; DPA PiMed↔proveïdor amb **SCC** (o adequació) quan el tractament surt de l’EEE.
- Settings tenant: checkbox d’acceptació de transferència internacional abans d’activar `ocr.receipt`.
- Text al portal empleat (primera alta / OCR): el rebut es pot processar amb proveïdor d’OCR/IA, eventualment fora de la UE.
- Sense acceptació → OCR **bloquejat** (alta manual OK). Detall operatiu: [03 §3](./03-integrations-ai-comms.md).

### Informació a l’empleat

- Text curt al portal: finalitat, conservació (default 10 anys, mínim 4), destinataris (admin interna, gestoria si s’exporta, OCR si actiu), drets.
- Categories `restricted_health`: avís addicional + ACL restringida.

### Drets d’interessat (MVP)

| Dret | Comportament V1 |
|------|-----------------|
| Accés / portabilitat | Export de línies pròpies + metadades de rebuts |
| Rectificació | `needs_info` + `append_receipt`, o `rejected` + línia nova |
| Supressió | No mentre hi hagi retenció fiscal; després del tall + purge, sí |
| Oposició | Limitada (obligació legal de conservació) |

### Categories restringides

- Flag `restricted_health`.
- Rebuts/OCR: només `expenses.review` + titular; exclòs de `view_project_costs`.

### Vista de costos de projecte (EXP-18)

- k-anonymity **≥ 5** al **servidor** (`project_costs_min_cohort`, default 5, mínim 3).
- Cohort = empleats distintes amb ≥1 despesa de projecte al filtre.
- Si cohort &lt; N: només total agregat; **cap** fila amb `Teammate`/inicials (evita reidentificació en equips de 2–3).
- Patró ATS: [recruitment/04-analytics-and-csv.md](../recruitment/04-analytics-and-csv.md).

---

## 4. Export CSV / webhook — còpies fora del purge

Un fitxer exportat o un payload de webhook **viu fora** del sistema de retenció de PiMed. El purge de PiMed **no** el pot esborrar.

**Nota operativa obligatòria (UI d’export + doc gestoria):**

> El tenant (responsable) ha d’assegurar, via DPA amb la gestoria/nòmina, que la retenció de les còpies externes s’alinea amb la política del tenant (o amb l’obligació legal aplicable). PiMed només conserva i purga el que hi ha a la plataforma.

Mateix forat conceptual que a ATS amb CSV; aquí queda **escrit** com a responsabilitat del tenant, no com a promesa tècnica de PiMed.

---

## 5. Pagament i IBAN (EXP-13) — actualitzat

**Font de veritat (ja implementada a HR):** IBAN (i NSS) a `data.employee_private_profiles` amb xifrat envelope per tenant, `iban_last4`, reveal auditat a Activitat. UI: fitxa privada d’empleat.

**Què canvia al mòdul de despeses**

| Abans (pla) | Ara |
|-------------|-----|
| “IBAN algun dia a employees” | IBAN **ja existeix** a HR |
| “Mai a l’export de despeses” | Export pot **referenciar** HR: default last4; clar opcional + audit |

**Què no canvia**

- PiMed **no** emet transferències en V1.
- La línia / informe **no** duplica ni desa l’IBAN (`external_refs` tampoc).
- Qui només té `expenses.review` **no** revela IBAN; cal `expenses.settle` (o el permís HR de reveal) per incloure’l en clar a un export.

**Operativa de reemborsament**

1. Aprovar / batch com fins ara.
2. Abans d’export: comprovar `has_iban`; si falta, avís (no bloqueja per defecte; setting futur `require_iban_for_reimbursement` opcional).
3. Gestoria/nòmina paga; confirmació → `reimbursed`.

**Futur (fora d’abast ara):** iniciació de transferència des de PiMed usant l’IBAN d’HR — pla de pagaments a part, no cal reobrir el domini de despeses.

---

## 6. Checklist EX0c

- [ ] `expenses_retention_years` default 10 (4–10) + `expenses_retention_purge_enabled` default **true**
- [ ] UI/audit per desactivar purge (no silenciós)
- [ ] Job de purge batched operatiu abans de prometre esborrat
- [ ] Text informatiu portal (retenció + OCR Art. 13)
- [ ] Acceptació transferència IA/OCR al tenant; OCR bloquejat sense ella
- [ ] Nota UI export sobre retenció a gestoria
- [ ] `view_project_costs` amb k-anonymity al servidor
- [ ] Categories `restricted_health` + tests RLS
- [ ] Payload export amb IVA, FX BCE; IBAN només via HR (default last4; clar opcional + audit settle)
