# Gate Tall 2 → Tall 3 — estat d’execució

> **Propòsit:** què s’ha fet als talls de gate (permís financer, cost de materials, despeses `is_billable`/`paid_by`), què falta i **quan** obrir cada peça.
> **Font del requisit:** [`05-acceptance-and-gates.md`](./05-acceptance-and-gates.md) § Gate Tall 2 → Tall 3.
> **Ordre global:** [`EXECUTION.md`](./EXECUTION.md).  
> **Última actualització:** 2026-10-05.

## Criteri del gate (quatre ítems)

| Ítem | Requisit | Estat tècnic | Estat d’ús real |
|------|----------|--------------|-----------------|
| Qualitat de dades | Hores, materials, km i despeses registrats de manera fiable a feines reals | ✅ Infra + smoke E2E online | ⚠️ Smoke online 2 OS PASS (2026-10-05); multi-dia humà + offline mòbil real + km close-out encara deute |
| Materials | Cost i preu de venda separats i **realment omplerts** | ✅ Model + UI | ✅ Ompliment PVP+cost verificat a smoke UAT (`gate-tall2-tall3-uat.spec.ts`) |
| Despeses | Model ampliat amb `is_billable` i `paid_by` | ✅ Model + UI mínima | ✅ Flags omplerts a smoke UAT (imputable + paga empleat) |
| Permisos | Permís financer definit i provat | ✅ `commercial.costs.view` + tests SQL | ✅ |

El gate **no** es marca ✅ a EXECUTION fins que la qualitat de dades (UAT) i l’ompliment real de cost/PVP/despeses estiguin comprovats. **2026-10-05:** ompliment ✅; qualitat = smoke online ✅ amb deute multi-dia/offline/km → gate global segueix **⚠️**. Sense això, CF-20 donaria xifres falses.

---

## Fet (talls de producte, 2026-10-01)

### 1. Permís financer + cost privat de material

| Peça | Detall |
|------|--------|
| Clau | `commercial.costs.view` — owner (`*`); manager al base; member **no** (concedible via Permisos de rols) |
| Cost | Taula `data.project_material_costs` (no columna a `project_materials`); vista `api.project_material_costs` SELECT |
| PVP | Segueix a `project_materials.unit_price_cents` (llegible amb accés a l’OS) |
| RPC | `api.set_project_material_amounts(material_id, patch jsonb)` — claus presents canvien; `null` JSON esborra |
| Scope | `data.can_view_commercial_costs(tenant, site)` (mateix tall que preu: global owner/manager, seu owner/manager, o live permission) |
| UI | `ProjectMaterialsSection`: PVP amb `commercial.pricing.edit`; cost només amb `costs.view` |
| Migració | `supabase/migrations/20261213000001_commercial_costs_view_material_costs.sql` |
| Tests | `supabase/tests/commercial_costs_material_tests.sql` (`SET ROLE authenticated`) |
| Docs changelog | EXECUTION fila «Gate costs» |

**No inclòs aquí:** `catalog_item_financials` / `project_line_financials` (això és **CF-19**), omplir costos històrics, snapshot offline del cost.

### 2. Despeses mínimes `is_billable` + `paid_by`

| Peça | Detall |
|------|--------|
| Columnes | `project_expenses.is_billable` DEFAULT `false`; `paid_by` DEFAULT `'company'` CHECK (`company` \| `employee`) |
| Vista | `api.project_expenses` recreada amb les dues columnes |
| RPC | `api.add_project_expense(...)` SECURITY INVOKER (online; sense `client_op_id`) |
| UI | Pestanya **Despeses** a Fer (`WorkExtraFabs` + `ProjectExpensesSection`) |
| Migració | `supabase/migrations/20261215000001_project_expenses_billable_paid_by.sql` |
| Tests | `supabase/tests/project_expenses_billable_paid_by_tests.sql` |
| Docs changelog | EXECUTION fila «Gate despeses» |

**No inclòs aquí:** mòdul EXP (workflow, IVA, km, informes, reclassificació, portal empleat, offline, rebuts UI). Veure [`../expenses/README.md`](../expenses/README.md).

### 3. Fix relacionat Cobraments (mateix dia)

`list_delivery_collection_page` (SECURITY INVOKER) cridava `data.commercial_document_total_cents` sense `GRANT EXECUTE` a `authenticated` → 403 al primer load. Fix: `20261214000001_grant_document_total_cents_execute.sql`. `record_login` deferit un tick a `AuthContext` per evitar 403 amb rol `anon` en `SIGNED_IN`.

---

## Pendent — què, com i quan

### A. UAT de qualitat de dades (ítem 1 del gate)

**Estat 2026-10-05 — smoke online:** PASS a Volt Serveis (Alice owner), 2 OS, fitxatge iniciar/aturar, material + PVP/cost, despesa imputable + paga empleat, reload sense pèrdua. Artifact: `apps/tenant-portal/tests/gate-tall2-tall3-uat.spec.ts`. SQL: `commercial_costs_material_tests.sql` + `project_expenses_billable_paid_by_tests.sql` PASS.

**Deute residual (no bloqueja CF-19; sí abans de confiar en CF-20):** O5 km close-out; F1–F6 offline mòbil real; observació humana ≥2 dies.

**Guia humana pas a pas (replicar):** [`08b-gate-tall2-tall3-human-uat.md`](./08b-gate-tall2-tall3-human-uat.md) — comptes seed, O1–O7, F1–F6, Dia 2 i full de resultats.

**Què:** En feines reals (o staging amb dades de producció-like), comprovar que hores, materials, km i despeses es registren sense pèrdues ni duplicats; offline de materials/tancament (CF-16) en mòbil real.

**Com:** Seguir [`08b`](./08b-gate-tall2-tall3-human-uat.md). Smoke E2E només com a regressió. No és un epic de schema.

**Quan:** **Abans** d’obrir CF-20 (rendibilitat). CF-19 es pot obrir en parallel (ompliment cost/PVP/flags ja verificat al smoke).

#### Checklist UAT (copiar a un ticket / full)

**Preparació**

| # | Pas | Fet |
|---|-----|-----|
| P1 | Tenant de camp (p. ex. Volt / Acme staging), 1 owner/manager oficina + 1 member tècnic | [x] Volt Alice (smoke); humà tècnic+oficina ☐ |
| P2 | 2–3 OS reals o realistes (`work_order`, client + seu, estat executable) | [x] 2 OS smoke |
| P3 | Tècnic amb mòbil (Chrome/PWA); oficina amb escriptori | ☐ (smoke = Chromium desktop) |
| P4 | Anotar hora d’inici de cada sessió i IDs d’OS al full | [x] report Playwright |

**On es registra cada actual avui**

| Actual | On a la UI | Persistència | Nota UAT |
|--------|------------|--------------|----------|
| Hores | Fitxar / `WorkLogCard` (iniciar–aturar visita) | `work_logs` (+ cua CF-16 offline) | Durada = check-out − check-in |
| Km | Close-out / desviacions: línia amb `unit = km` (actuals) | `project_lines` via apply actuals | No és EXP mileage; sol ser «Desplaçament» |
| Materials | Fer → Materials | `project_materials` (+ cua offline CF-16) | Cost/PVP: oficina amb `costs.view` / `pricing.edit` |
| Despeses | Fer → Despeses | `project_expenses` via `add_project_expense` | **Només online** en aquest tall |

**Passada online (obligatòria) — 1 OS completa**

| # | Actor | Acció | Criteri d’èxit | 2026-10-05 |
|---|-------|-------|----------------|------------|
| O1 | Tècnic | Obrir OS → Fer → Iniciar feina / fitxar | Work log obert visible; timer avança | [x] smoke |
| O2 | Tècnic | Afegir ≥1 material (nom, qty, unitat) | Apareix a la llista; després de refresh segueix | [x] smoke |
| O3 | Tècnic | Afegir ≥1 despesa (import, descripció; provar billable + paid_by empleat) | Llista amb badges; refresh OK | [x] smoke |
| O4 | Tècnic | Aturar fitxatge / tancar interval | Hores acumulades coherents amb el rellotge | [x] smoke |
| O5 | Tècnic | Tancar visita (close-out): aplicar hores i **km** si el flux ho demana | Línies `h` / `km` actualitzades; sense error silenciós | ☐ |
| O6 | Oficina | Obrir la mateixa OS: materials (PVP + cost si manager), despeses, temps | Mateixes quantitats; cost només si té `costs.view` | [x] Alice owner |
| O7 | Qualsevol | Recarregar pàgina / altra pestanya | Cap pèrdua ni duplicat de material/despesa/work log | [x] smoke |

**Passada offline (recomanada; tanca també deute CF-16)** — veure també gate CF-16 a [`05-acceptance-and-gates.md`](./05-acceptance-and-gates.md)

| # | Acció | Criteri d’èxit | 2026-10-05 |
|---|-------|----------------|------------|
| F1 | Online: obrir OS; després mode avió / tallar xarxa | UI honest (pending / no promet sync impossible) | ☐ |
| F2 | Registrar material i/o actuals km/hores segons el que CF-16 cobreixi | Op local visible; no esborra al refresh soft | ☐ |
| F3 | Intentar despesa offline | Ha de **fallar clar** o no oferir-se (encara no hi ha cua); no inventar fila fantasma | ☐ |
| F4 | Tancar visita offline si el producte ho permet | Estat `local_pending` / similar; sense albarà creat | ☐ |
| F5 | Recuperar xarxa + Forçar sync / drain | Una sola aplicació per `client_op_id`; sense duplicats | ☐ |
| F6 | Dues pestanyes / reintent | Idempotència: mateix material no es crea dues vegades | ☐ |

**Fiabilitat = passar tot això en ≥2 OS i ≥2 dies** (no només un demo feliç). Smoke: **2 OS / 1 dia**.

**Registre del resultat**

| Data | Tenant | Actor | Resultat | Bugs |
|------|--------|-------|----------|------|
| 2026-10-05 | Volt Serveis | Alice (E2E Chromium) | Online O1–O4, O6–O7 PASS ×2 OS; O5/F*/multi-dia pendent | Cap |

Quan el deute residual passi: actualitzar la fila «Qualitat de dades» a aquest fitxer i a [`05-acceptance-and-gates.md`](./05-acceptance-and-gates.md) i marcar el gate ✅ a EXECUTION.

**Què no cal per aquesta UAT**

- Mòdul EXP (IVA, informes, reemborsament).
- CF-19/CF-20 (marges / resultat brut).
- Omplir costos històrics de materials antics (opcional; no bloqueja el checklist si les OS de prova tenen cost/PVP).

### B. CF-19 — Costos privats de catàleg / línies

**Estat:** ✅ (2026-10-05)

**Què:** `catalog_item_financials` i `project_line_financials`; marge objectiu com a suggeriment de PVP; mai columnes de cost a vistes obertes (CF-D7). Reutilitza `commercial.costs.view`.

**Fet:** migració `20261221000001`; helper DEFINER `copy_catalog_cost_to_line` des d’apply/upsert; RPCs patch INVOKER; UI formulari catàleg (cost+marge+suggest PVP) i línia (cost amb `costs.view`+seu); SQL `commercial_cf19_financials_tests.sql`; types regenerats. El tall de materials del gate **no** substitueix CF-19.

### C. CF-20 — Resultat brut

**Estat:** ✅ (2026-10-05) — codi; confiar xifres quan UAT residual ✅

**Què:** Resultat brut estimat/real; cost laboral congelat; agregació materials (cost vs PVP) + despeses (regla 2A).

**Fet:** `20261223000001` — `work_log_labor_costs` + freeze a `stop_work_log` + backfill; RPC `get_project_profitability_summary` (ingressos ex-VAT; cost línies exclou `unit=h`; despeses company / employee no-billable); UI card gated; SQL tests. Hardening `20261224000001` (Madrid TZ, accepted docs, coverage missing freeze, immutable). El deute residual de qualitat (km/offline/multi-dia) segueix abans de confiar les xifres en producció.

### D. Mòdul EXP (despeses d’empleat)

**Què:** EX0a… — `expense_scope`, `employee_id`, IVA, mileage, FSM `draft`→`submitted`→…, `expenses.reclassify`, informes, portal, OCR, retenció. Pla: [`../expenses/README.md`](../expenses/README.md).

**Com:** Evolucionar la **mateixa** taula `project_expenses` (EXP-1). Les columnes `is_billable`/`paid_by` ja existeixen amb el vocabulari EXP; no cal migrar noms. Afegir offline amb `client_op_id` quan EX0b.

**Quan:** **Fora del camí crític del Tall 3 comercial.** Obrir quan es vulgui reemborsament / cua admin / portal empleat. No és prerequisit de CF-19; pot enriquir CF-20 més endavant (filtrar per `is_billable`, excloure `paid_by` mal etiquetat, etc.).

### E. Deute menor del tall despeses

| Ítem | Quan |
|------|------|
| Offline queue de despeses (com materials) | Amb EX0b / CF-16 ampliació |
| Adjunt de rebut a la UI (`receipt_document_id`) | EX0 / EX1 |
| Regenerar `database.types.ts` (ara `as never` al client) | Quan es regenerin types del monorepo |
| Edició inline de `is_billable`/`paid_by` després de crear | Opcional; avui només a l’alta (UPDATE via vista/RLS possible) |

---

## Ordre recomanat d’ara endavant

```text
1. UAT gate residual (O5 km + offline mòbil + multi-dia)   ← per confiar xifres CF-20
2. CF-19 costos de catàleg/línia                            ← ✅
3. CF-20 resultat brut                                      ← ✅
4. EXP EX0… / CF-22                                         ← pistes separades
```

## Fitxers clau

| Àrea | Camí |
|------|------|
| Permís TS | `apps/tenant-portal/src/lib/permissions.ts` |
| Materials UI | `apps/tenant-portal/src/features/field-service/components/ProjectMaterialsSection.tsx` |
| Despeses UI | `apps/tenant-portal/src/features/field-service/components/ProjectExpensesSection.tsx` |
| Migració costs | `supabase/migrations/20261213000001_commercial_costs_view_material_costs.sql` |
| Migració despeses | `supabase/migrations/20261215000001_project_expenses_billable_paid_by.sql` |
| Smoke UAT E2E | `apps/tenant-portal/tests/gate-tall2-tall3-uat.spec.ts` |
| Guia UAT humana | [`08b-gate-tall2-tall3-human-uat.md`](./08b-gate-tall2-tall3-human-uat.md) |
| Pla EXP (futur) | `docs/plans/expenses/` |
