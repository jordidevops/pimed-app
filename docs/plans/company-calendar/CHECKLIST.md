# Checklist — Calendari d’empresa

> Marcar `[x]` només quan el **DoD** de la fase estigui complert.  
> Detall: [`03-phases-v1.md`](./03-phases-v1.md) · V2: [`04-backlog-v2.md`](./04-backlog-v2.md)  
> Ordre: [`EXECUTION.md`](./EXECUTION.md)

## V1

| Fase | Fitxer / secció | Estat | Data | Notes |
|------|-----------------|-------|------|-------|
| 0 Nav + i18n | [`03` Fase 0](./03-phases-v1.md#fase-0--nav-i18n-i-permisos-de-menú) | [x] | 2026-10-05 | Stub + tests resolveNav |
| 1 Model + delete RPC | [`03` Fase 1](./03-phases-v1.md#fase-1--model-projecció-colors-week-start-delete-rpc) | [x] | 2026-10-05 | Migració `20261219000003_*` |
| 2 Components compartits | [`03` Fase 2](./03-phases-v1.md#fase-2--components-compartits-detall--formulari) | [x] | 2026-10-05 | EventDetailSheet + CreateEventForm |
| 3 CompanyCalendarPage | [`03` Fase 3](./03-phases-v1.md#fase-3--companycalendarpage) | [x] | 2026-10-05 | URL state + list/day/week/month + filtres |
| 4 Widget + dashboard | [`03` Fase 4](./03-phases-v1.md#fase-4--widget-dashboard--wiring) | [x] | 2026-10-05 | Gate + CTAs + create via URL |
| 5 Hardening | [`03` Fase 5](./03-phases-v1.md#fase-5--hardening-i-tancament-v1) | [x] | 2026-10-05 | Criteris V1 |

### Gates V1

1. **Després de 0:** noms correctes; stub `/calendar` amb gate.  
2. **Després de 1:** multiday/colors/weekStart/delete SQL verds.  
3. **Després de 2:** formulari amb àmbit + all-day + delete manual.  
4. **Després de 3:** pàgina usable list/day/week/month + URL.  
5. **Després de 4:** widget preview + CTAs; e2e OK.  
6. **Després de 5:** tots els criteris d’acceptació V1 `[x]`.

### Criteris d’acceptació V1 (resum)

- [x] list/day/week/month + filtres + «Més 14 dies»
- [x] Sense infinite scroll de dies
- [x] Multiday/all-day + TZ
- [x] `week_starts_on`
- [x] Àmbit explícit en crear
- [x] Delete manuals owner/manage
- [x] Agenda ≠ Calendari ≠ El meu calendari
- [x] Gate `calendar.view` a nav/dashboard/pàgina
- [x] Widget sense UI mutadora duplicada

## V2 (només després de V1)

| Epic | Fitxer | Estat | Data | Notes |
|------|--------|-------|------|-------|
| V2.1 Cerca | [`04`](./04-backlog-v2.md#v21--cerca) | [x] | 2026-10-05 | q= + resultats + salt a day |
| V2.2 Els meus events | [`04`](./04-backlog-v2.md#v22--els-meus-events) | [x] | 2026-10-05 | mine=1 + contracte |
| V2.3 Time-grid | [`04`](./04-backlog-v2.md#v23--time-grid-graella-horària) | [x] | 2026-10-05 | Day/week 30min + all-day + click slot |
| V2.4 Drag-and-drop | [`04`](./04-backlog-v2.md#v24--drag-and-drop) | [ ] | | |
| V2.5 Integracions (iCal MVP) | [`06`](./06-ical-how-it-works.md) · [`07`](./07-ical-security.md) · [`08`](./08-ical-architecture-and-phases.md) | [ ] | | Pla documental fet; codi pendent (fases I1–I4) |
