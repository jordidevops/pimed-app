# Field Service — Estat d'implementació

> **Última actualització:** 2026-10-04  
> **Propòsit:** seguir el desenvolupament dels epics FSM.  
> **Pla:** [`README.md`](./README.md) · backlog [`05-backlog-epics.md`](./05-backlog-epics.md) · UX [`04-ux-contract.md`](./04-ux-contract.md)

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
| **FS-2** | Shell Avui + FAB | ✅ | Layout + Avui/Ordres/Agenda/Més + FAB; sidebar ≥lg + alçada curta |
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

## Agenda de visites (2026-10)

| Ítem | Estat | Notes |
|------|-------|-------|
| `/field/agenda` Llista / Dia / Setmana / Mes | ✅ | Una sola superfície; vista per defecte mòbil=llista, desktop=setmana; clic al mes → Dia |
| Font de dades `api.list_field_visits` | ✅ | RLS invoker; no `calendar_events` (evita fuga de títols) |
| Filtres URL (scope, tipus, estat, tècnic) | ✅ | «Les meves / Totes» només managers; tècnic = membres actius del tenant |
| Safata sense planificar + crear des del dia | ✅ | Safata només managers; `initialPlannedStart`; `datetime-local` per OS/manteniment |
| Sidebar Agenda + Dispositiu + Horari | ✅ | Horari al clúster Camp d’Operativa; overlay amb un sol scroll en alçada curta |
| `/field/calendar` → week | ✅ | Redirect estable |
| Mes mòbil: només punts de color | ✅ | Tap → vista Dia; landscape cards compactes +N |
| Ordres: columna data + sort `planned_start` | ✅ | Default FS: data asc |
| `calendar_events` projectes sense fuga de títols | ✅ | `projects.view` + RLS `can_access_project`; migració `20261220000001` |

### Fora d'abast (tall actual / tall 2)

| Ítem | Notes |
|------|-------|
| Drag & drop reprogramar / assignar | Tall 2 |
| Vista carrils per tècnic + solapaments | Tall 2 |
| Reescriure calendari laboral `/attendance/calendar` | Fora d’abast |
| Graella horària tipus Google (slots per hora) | Quan la majoria de visites tinguin hora |

Pla de producte detallat (revisió): `~/.cursor/plans/field_calendar_nav_52a8a418.plan.md` (no és font de veritat del repo; aquest STATUS sí).

## Notes tècniques

- Seed: **Volt Serveis** (`10000000-…0003`, `archetype=field_service`) amb client/obra + WO d’avui. Acme sense sector (onboarding Bob) i amb contact sites CRM.
- Nav FS: shell Avui/Ordres **no** amaga la resta de mòduls del pla (empleats, catàleg, etc.).
- Offline honest: completar ordre i materials requereixen xarxa; fotos drenen via `usePendingPhotoDrain`.
- Llista: `p_open_only` / `p_created_by` al RPC; `count_projects` per widgets; enrich client/site a items.
- Agenda: migracions `20261219000001_list_field_visits` + cast fix; hook `useFieldVisits`; UI `CalendarGrid`.

## Changelog

| Data | Canvi |
|------|-------|
| 2026-10-04 | Review Agenda: mineOnly gate, RLS tests, dates locals, scope/safata managers, calendar_events access, E2E agenda |
| 2026-10-04 | Agenda unificada + nav camp; densitat mes mòbil; data/sort a Ordres; STATUS agenda |
| 2026-07-25 | Seed Volt FS real + E2E sense mock; nav FS deixa mòduls del pla visibles |
| 2026-07-25 | Hotfix review: foto drain, gating, RPC sort/filtres, dates locals, PWA genèrica, STATUS honest |
| 2026-07-25 | Implementació inicial FS-0→FS-5 |
| 2026-07-22 | Creació del pla documental |
