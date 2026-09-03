# Field Service — Estat d'implementació

> **Última actualització:** 2026-07-25  
> **Propòsit:** seguir el desenvolupament dels epics FSM.  
> **Pla:** [`README.md`](./README.md) · backlog [`05-backlog-epics.md`](./05-backlog-epics.md)

## Llegenda

| Símbol | Significat |
|--------|------------|
| ✅ | Fet i usable |
| 🔄 | En curs |
| ❌ | No començat |
| 📦 | Diferit (V1.5 / V2 / altre pla) |
| ⚠️ | Parcial |

---

## Epics V1

| Epic | Nom | Estat | Notes / PR |
|------|-----|-------|------------|
| **FS-0** | Labels + vocabulari | ✅ | sector_labels + nav/status/calendar |
| **FS-1** | Client / site a ordre + Maps + llista | ✅ | `contact_site_id`, CRUD sites, form client/site obligatori, Maps |
| **FS-2** | Shell Avui + FAB | ✅ | Layout + Avui/Ordres/Agenda(14d)/Més + FAB |
| **FS-3** | Checklist + materials + close-out | ⚠️ | Close-out online; fotos offline amb drain; materials online-only (honest UX) |
| **FS-4** | PWA + offline Today | ⚠️ | PWA genèrica (`/dashboard`); Avui cache + worklog + foto drain; complete/materials no offline |
| **FS-5** | Onboarding + E2E + UAT | ⚠️ | Onboarding + widgets + E2E Volt real; UAT manual pendent |

## Gaps ([02](./02-gap-and-naming.md))

| Gap | Estat |
|-----|-------|
| G1 Avui + FAB | ✅ |
| G2 Client + site | ✅ |
| G3 Estats servei UI | ✅ |
| G4 Checklist | ✅ |
| G5 Materials UI | ⚠️ | UI online; no cua offline |
| G6 Labels sector | ✅ |
| G7 PWA / offline Today | ⚠️ | Lectura Avui + start/stop + foto drain; no close-out complet offline |
| G8 Close-out | ⚠️ | Flux usable online; stop/foto offline |
| G9 Bundles tecnic | 📦 V1.5 |
| G10 Dispatch / rutes | 📦 V1.5 / V2 |

## Gate V1 → V1.5

| Ítem | Estat |
|------|-------|
| Smoke E2E verd | ⚠️ | Spec contra **Volt Serveis** (sense mock); cal `db reset` amb seed actual |
| [`uat-tier-a-checklist.md`](./uat-tier-a-checklist.md) acceptat | ❌ |
| V1.5 obert | ❌ |

## Notes tècniques

- Seed: **Volt Serveis** (`10000000-…0003`, `archetype=field_service`) amb client/obra + WO d’avui. Acme sense sector (onboarding Bob) i amb contact sites CRM.
- Nav FS: shell Avui/Ordres **no** amaga la resta de mòduls del pla (empleats, catàleg, etc.).
- Offline honest: completar ordre i materials requereixen xarxa; fotos drenen via `usePendingPhotoDrain`.
- Llista: `p_open_only` / `p_created_by` al RPC; `count_projects` per widgets; enrich client/site a items.

## Changelog

| Data | Canvi |
|------|-------|
| 2026-07-25 | Seed Volt FS real + E2E sense mock; nav FS deixa mòduls del pla visibles |
| 2026-07-25 | Hotfix review: foto drain, gating, RPC sort/filtres, dates locals, PWA genèrica, STATUS honest |
| 2026-07-25 | Implementació inicial FS-0→FS-5 |
| 2026-07-22 | Creació del pla documental |
