# Flux comercial — Estat d'implementació

> **Última actualització:** 2026-09-16
> **Propòsit:** seguir el desenvolupament dels epics CF i deixar constància honesta del que falta.
> **Pla:** [`README.md`](./README.md) · backlog [`04-phases-and-backlog.md`](./04-phases-and-backlog.md) · ordre [`EXECUTION.md`](./EXECUTION.md)

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

**Tall 1 espina comercial tancable** (tècnicament). **CF-13…CF-15, CF-17 i CF-18 tancats**, **CF-16 implementat (UAT offline pendent)**. Deute: UAT Tall 1, regenerar `database.types.ts`, polish de signatura amb el dit, Stripe/Holded 📦, signatura formal comercial 📦.

## Tall 1 — Espina legal i de camp

| Epic | Nom | Estat | Notes |
|------|-----|-------|-------|
| CF-0 | Vocabulari i unitats | ✅ | |
| CF-1 | Guardrails de dades | ✅ | |
| CF-2 | Línies al mòbil / UX OS | ⚠️ | Tests tècnics verds; gate humà de simplicitat pendent |
| CF-3 | Servei habitual | ✅ | Apply + tab Catàleg |
| CF-4 | Documents comercials base | ⚠️ | Schema + panell per secció |
| CF-5 | Pressupost | ⚠️ | Mode client; falta signatura dit |
| CF-6 | Renúncia al pressupost | ✅ | |
| CF-7 | Import autoritzat | ✅ | |
| CF-8 | Revisió de desviacions | ✅ | |
| CF-9 | Ampliació de pressupost | ✅ | |
| CF-10 | Albarà | ⚠️ | Emissió; falta signatura |
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

## Changelog

| Data | Canvi |
|------|-------|
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
