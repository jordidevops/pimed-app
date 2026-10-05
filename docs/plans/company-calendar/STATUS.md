# STATUS — Calendari d’empresa

> Actualitzar en cada PR / sessió d’implementació.  
> Última revisió documental: **2026-10-05**

| Fase / epic | Estat | Notes |
|-------------|-------|-------|
| Pla documental | fet | Directori `docs/plans/company-calendar/` |
| V1 Fase 0 Nav+i18n | fet | Stub `/calendar`; rename Jo; gate `canViewCalendar` |
| V1 Fase 1 Model+RPC | fet | Projector + colors + weekStartsOn + `delete_manual_calendar_event` |
| V1 Fase 2 Shared UI | fet | EventDetailSheet + CreateEventForm àmbit/all-day/delete |
| V1 Fase 3 Page | fet | CompanyCalendarPage + companyCalendarUrlState |
| V1 Fase 4 Widget | fet | Preview + CTAs dashboard + create → /calendar |
| V1 Fase 5 Hardening | fet | Checklist acceptació V1 |
| V2.1 Cerca | fet | q= + matching + resultats ±6 mesos |
| V2.2 Els meus | fet | mine=1 + contracte a 05-mine-events-contract.md |
| V2.3 Time-grid | fet | Day/week 30min + all-day row + click-to-create |
| V2.4 DnD | deprioritzat | No prerequisit d’iCal; valor baix ara |
| V2.5 Integracions iCal | pla documental | Docs 06–08; **codi no implementat** |

## Bloquejos actius

- Cap. Implementació iCal quan es prioritzin fases I1–I4 de [`08`](./08-ical-architecture-and-phases.md).

## Decisions post-pla

- (afegir aquí si producte canvia alguna cosa de `01` / `02`)
