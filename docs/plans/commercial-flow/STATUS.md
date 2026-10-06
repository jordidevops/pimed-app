# Flux comercial — Estat d'implementació

> **Última actualització:** 2026-10-06
> **Propòsit:** seguir el desenvolupament dels epics CF i deixar constància honesta del que falta.
> **Pla:** [`README.md`](./README.md) · backlog [`04-phases-and-backlog.md`](./04-phases-and-backlog.md) · ordre [`EXECUTION.md`](./EXECUTION.md) · gate Tall 2→3 [`08-gate-tall2-tall3.md`](./08-gate-tall2-tall3.md)

## Novetat 2026-10-01 — Gate Tall 2 → Tall 3 (talls tècnics)

- **Permís** `commercial.costs.view` (manager per defecte; member concedible) + cost de material a `project_material_costs` separat del PVP.
- **Despeses:** `is_billable` + `paid_by` a `project_expenses` + pestanya Despeses a l’ordre.
- **Gate encara ⚠️:** falta UAT de registre fiable a feines reals i ompliment sistemàtic de cost/PVP/flags. Detall: [`08-gate-tall2-tall3.md`](./08-gate-tall2-tall3.md).
- **CF-19** ✅ i **CF-20** ✅ (2026-10-05). Següent: UAT gate residual ⚠️ i/o pista acords **CF-22**. EXP és pista separada.

## Novetat 2026-09-18 — Règim comercial OS + visita d’avaluació

- `projects.commercial_regime` (`consumer` | `contractual`): snapshot editable heretat del contacte.
- `projects.service_mode` (`execute` | `assessment`): avaluació tanca sense autorització; hand-off a oficina; albarà bloquejat fins a pressupost acceptat.
- Polítiques per règim a `tenants.settings.commercial.regimes` (Settings → Plantilles → Comercial).
- Gates SQL usen règim de l’OS + waiver (no només `contacts.is_consumer`).
- UI: selectors a capçalera OS, toggle `is_consumer` al fitxer de contacte.

## Llegenda

| Símbol | Significat |
|--------|------------|
| ✅ | Fet i usable |
| 🔄 | En curs |
| ❌ | No començat |
| ⚠️ | Parcial |
| 📦 | Diferit a un altre tall o pla |

---

## Resum

**Tall 1 espina comercial tancable** (tècnicament). **CF-13…CF-15, CF-17…CF-21, CF-26 i CF-27 tancats**. **CF-16** implementat (UAT offline pendent). Gate Tall 2→3: model + ompliment smoke ✅; UAT residual (km/offline/multi-dia) ⚠️ abans de confiar xifres CF-20. Pista acords: **CF-21** ✅ → següent **CF-22**. Deute: UAT Tall 1, Stripe/Holded 📦, signatura formal (DocuSeal/qualified) 📦, EXP 📦, CF-25-b 📦. Signatura nativa amb el dit a pressupost/albarà ✅ (2026-10-06).

## Tall 1 — Espina legal i de camp

| Epic | Nom | Estat | Notes |
|------|-----|-------|-------|
| CF-0 | Vocabulari i unitats | ✅ | |
| CF-1 | Guardrails de dades | ✅ | |
| CF-2 | Línies al mòbil / UX OS | ⚠️ | Tests tècnics verds; gate humà de simplicitat pendent |
| CF-3 | Servei habitual | ✅ | Apply + tab Catàleg |
| CF-4 | Documents comercials base | ⚠️ | Schema + panell per secció |
| CF-5 | Pressupost | ✅ | Emissió + mode client; acceptar/refusar via firma nativa (dit o `/sign`) |
| CF-6 | Renúncia al pressupost | ✅ | Encara `staff_ui` (no és pressupost/albarà) |
| CF-7 | Import autoritzat | ✅ | |
| CF-8 | Revisió de desviacions | ✅ | |
| CF-9 | Ampliació de pressupost | ✅ | |
| CF-10 | Albarà | ✅ | Emissió + conformitat via firma nativa (dit o `/sign`) |
| CF-11 | Compartició i PDF simple | ✅ | |
| CF-12 | Cobrament simple | ✅ | |
| CF-23 | Servei habitual + checklist | ✅ | Bridge + apply + default create |

## Tall 2 — Equip petit, historial i diners

| Epic | Nom | Estat | Notes |
|------|-----|-------|-------|
| CF-13 | Separació tècnic i oficina | ✅ | Llindar + RPC + proposar/aprovar UI; UAT Tall 1 segueix deute |
| CF-14 | Historial al client | ✅ | Resum a Contacte + tab Pressupostos; estat i acció pendent |
| CF-15 | Secció Pressupostos | ✅ | `/quotes` + cerca RPC; crear i duplicar des de la secció |
| CF-16 | Offline d'actuals | ⚠️ | Ledger/RPC idempotent, outbox amb dependències, snapshots, actuals/materials/tancament local i estats honestos; UAT offline real pendent. L'albarà continua manual online |
| CF-17 | Cobraments avançats | ✅ | Parcials/saldo honest + ref. factura text; Stripe i Holded API 📦 |
| CF-18 | Render amb plantilles | ✅ | PDF de marca via camí propi (HTML snapshot + Gotenberg + DMS); TAP sense Gotenberg; signatura formal 📦. Follow-up: carpetes client visibles a `/documents`, dates al document, Descartar, bug «Cobrat». PDF comercial no esborrable al DMS + enllaç al pressupost/OT |
| CF-25 | Hub d'Albarans (CF-26) | ✅ | Hub `/sales/delivery-notes` + UAT oficina/camp (2026-10-03). Spec: [`07`](./07-collections-and-ar-hub.md). CF-25-b (acords) 📦 |
| CF-27 | Comercial `/sales` | ✅ | Factures natives, allocations, sèries/FY, gestoria, export ZIP client, fitxes/PDF, RBAC JWT claims. Log: [`IMPLEMENTATION-LOG`](./09-sales-comercial/IMPLEMENTATION-LOG.md). Opcional: sèries write UI, adaptadors ERP, worker storage. |
| — | Gate Tall 2 → Tall 3 | ⚠️ | Permís + cost material + despeses flags ✅; UAT ompliment ❌ — [`08-gate-tall2-tall3.md`](./08-gate-tall2-tall3.md) |

## Tall 3 — Costos i rendibilitat

| Epic | Nom | Estat | Notes |
|------|-----|-------|-------|
| CF-19 | Costos privats | ✅ | `catalog_item_financials` / `project_line_financials`; copy DEFINER apply/upsert; UI formulari + suggest PVP; SQL PASS; types regenerats |
| CF-20 | Rendibilitat | ✅ | Freeze laboral + summary ex-VAT (1A/2A; línies `h` excloses); hardening `20261224000001` (Madrid TZ, accepted docs, coverage missing freeze, immutable); UI Resultat brut; SQL PASS; confiar xifres quan UAT gate residual ✅ |

## Pista acords / contractual

| Epic | Nom | Estat | Notes |
|------|-----|-------|-------|
| CF-21 | Manteniment contractual | ✅ | a…h; verificat reset + suite SQL 2026-10-05. Holded 📦. Pla [acords](../commercial-agreements/pla-pressupost-contracte-acords.md) |
| CF-22 | Obra i instal·lació | ❌ | Depèn del nucli CT, no de CF-21 |

## Changelog

| Data | Canvi |
|------|-------|
| 2026-10-06 | Seeds hub durables: Volt `A-2026-9101` + Riera `A-2026-9102` (`commercial_hub_delivery_notes.sql` a `sql_paths`). `A-CF25-*` no es recreen. |
| 2026-10-06 | **CF-5/CF-10 polish signatura dit:** Pointer Events al pad; diàleg comercial sense PDF a sobre del canvas; confirm sense exigir hub id; hub 1-signant (migrations `20261226*`). Renúncia segueix `staff_ui`. |
| 2026-10-05 | **CF-20** tancat: `20261223000001` labor freeze + `get_project_profitability_summary` + UI; SQL `commercial_cf20_profitability_tests.sql`; types. UAT gate residual segueix ⚠️. |
| 2026-10-05 | **CF-20 hardening**: `20261224000001` (Madrid TZ, accepted docs real_basis, coverage missing freeze, immutable UPDATE, REVOKE helpers). |
| 2026-10-05 | **CF-19** follow-up: `20261222000001` copy a `copy_project_lines`/`apply_price_sheet`, harden DEFINER, upsert retry, UI dirty-check (no wipe), tests cross-tenant/member upsert + vitest €↔cents. |
| 2026-10-05 | **CF-19** tancat: migració `20261221000001`, financials privats, copy DEFINER, UI catàleg/línies, suggest PVP, SQL `commercial_cf19_financials_tests.sql`, types. Següent producte: **CF-20**. |
| 2026-10-05 | **Gate Tall 2→3** smoke UAT online (2 OS Volt) + SQL costs/despeses; ompliment ✅; gate global encara ⚠️ (km/offline/multi-dia). CF-19 obrible. |
| 2026-10-05 | **CF-21-h / CF-21** tancats: `db reset` + 19 SQL PASS + vitest smoke acords. Següent pista acords: CF-22; producte flux: gate Tall 2→3 / CF-19. |
| 2026-10-03 | **CF-27** tancat: migracions `000001`–`000009`, UAT oficina/gestoria/camp, `getSessionAppMetadata`, types regenerats, ZIP PizZip. Següent: UAT CF-26 o gate Tall 2→3 / CF-19. |
| 2026-10-02 | **CF-27** frontend wired: sales list RPCs, InvoicesPage, SalesAccountingPage export, Settings Comercial, detail collect/cancel/links. Docs 03–07 parcials. |
| 2026-10-02 | **CF-27** implementat al codi: migracions 000001–000006, `/sales`, allocations, export JSON, Settings Comercial, preset Gestoria. UAT/types pendents. |
| 2026-10-02 | Pla **CF-27** documentat a [`09-sales-comercial/`](./09-sales-comercial/README.md) (fases 0–7, gestoria/export, checklist). |
| 2026-10-02 | CF-26 correcció: 11 forats (rectify+preview, summary bestreta, FIFO clock, list scoped, CTA factura oficina-only, dates, comprovant, remediació legacy manual). Doc 07 amb fet/pendent |
| 2026-10-02 | CF-26: hub d'Albarans a `/delivery-notes` (tots els albarans, factura externa, rectificació FIFO). `/cobraments` redirigeix |
| 2026-10-01 | Gate Tall 2→3 talls: `commercial.costs.view` + cost material privat; despeses `is_billable`/`paid_by` + UI; doc [`08-gate-tall2-tall3.md`](./08-gate-tall2-tall3.md) |
| 2026-10-01 | CF-25 obert: hub oficina `/cobraments`, últim albarà, ledger únic; sense factura fiscal ni pestanya acords al v1 |
| 2026-10-01 | CF-25 tancat: `list_delivery_collection_page`, `CobramentsPage`, nav `isOffice`, ponts quotes/contacte/OS oficina, copy badge pressupost |
| 2026-09-10 | Pla documental |
| 2026-09-10 | CF-0…CF-4 schema + panell mínim |
| 2026-09-10 | CF-6/7/8/9: renúncia UI, desviacions close-out, ampliació |
| 2026-09-10 | CF-11: vista client, share sheet, print/HTML, RPC sent |
| 2026-09-10 | CF-12: CollectPaymentDialog + PaymentReceiptSheet |
| 2026-09-10 | CF-3: CRUD Serveis habituals al Catàleg |
| 2026-09-14 | Primera reestructuració OS per fases: implementada però no acceptada funcionalment |
| 2026-09-14 | Estabilització UX OS: workflow monotònic, tabs canònics, CTA en flux, reemissió immutable i Entregar ordenat; UAT humana pendent |
| 2026-09-14 | CF-23: `pricing_template_checklists` + apply + Visita estàndard en crear OS |
| 2026-09-14 | Gate Tall 1 → Tall 2: UAT diferida explícitament; s’obre CF-13 |
| 2026-09-14 | CF-13: llindar configurable, gate RPC d’acceptació, proposar vs aprovar a UI |
| 2026-09-14 | CF-14: historial comercial a la fitxa de contacte (resum + tab Pressupostos) |
| 2026-09-14 | CF-15: `/quotes` al sidebar, `search_commercial_documents`, filtres i accions reutilitzades |
| 2026-09-14 | CF-15 deute: crear (picker d’OS) i duplicar (reemissió) des de `/quotes` |
| 2026-09-15 | CF-16: actuals i tancament durable offline, coordinador multi-cua, idempotència backend i proves; albarà explícitament manual després del sync. UAT real pendent |
| 2026-09-15 | CF-17 obert per petició explícita: cobrament parcial honest; Stripe i connector Holded/Quipu diferits |
| 2026-09-16 | CF-17 tancat: parcials/bestretes/cap de saldo usables; Stripe i Holded 📦. S’obre CF-18 PDF de marca |
| 2026-09-16 | CF-18 tancat: HTML de marca, edge `render-commercial-document`, enllaç DMS i UI PDF/pendent; signatura formal 📦 |
| 2026-09-16 | Follow-up comercial: carpetes client al DMS, dates/events a la vista, audit de projecció a l’OS, Descartar pressupost emès, avís de preus i correcció de «Cobrat» |
| 2026-09-16 | PDF comercial protegit a l’esborrat DMS; enllaç de tornada al pressupost i a l’OT |
