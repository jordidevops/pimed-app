# 01 — Producte i nomenclatura

## Decisions tancades

| Ruta | Feina | Label sidebar (ca) | On |
|------|--------|-------------------|-----|
| `/field/agenda` | Visites / OS | **Agenda** | Operativa · FSM |
| `/calendar` | Events empresa (`calendar_events`) | **Calendari** | Operativa · `calendar.view` |
| `/attendance/calendar` | Laboral personal | **El meu calendari** | Jo · attendance |
| `/attendance-mgmt/...` | Planificació RRHH | Sense rename V1 | Equip / mgr |

### Regles

- Subtítol pàgina empresa: **«Events de l’empresa»**.
- Icona nav empresa ≠ Agenda (`CalendarRange` vs `CalendarDays`).
- Visites FSM **no** es pinten a `/calendar`.
- FSM: «Agenda» = camp; «Calendari» = empresa.
- No-FSM: no hi ha Agenda de camp; «Calendari» = empresa; Jo = «El meu calendari».
- `manual` a UI: **«Event»** (no «Event personal») — és event d’empresa amb àmbit explícit.
- `calendar.view` és permís base dels rols actuals: tècnics FSM poden veure el Calendari; RLS limita quins events. **No** afegir gate `isOffice` contradictori.

## Crítica incorporada (no reobrir)

1. No vendre «Google Calendar» sense time-grid (això és V2).
2. Widget dashboard = preview obligatori, no mini-app paral·lela.
3. Quart «Calendari» (Control horari) existeix; V1 no el reanomena.
4. Mateixa regla `calendar.view` a nav, pàgina i secció dashboard.
5. Config `default_calendar_view` + `week_starts_on` s’han de respectar a V1.
6. Layouts desats: `mergeMissingDefaultNavItems` injecta `company_calendar`; cal test d’inserció després de `field_agenda`.

## Vista llista

| Idea | V1 |
|------|-----|
| Vista **Llista** (dies agrupats) | **Sí.** Default mòbil = `list`. |
| Scroll infinit de dies | **No.** |
| Extendre horitzó | **Sí:** «Més 14 dies» → `span` 14→28→42 a URL. |

Referència FSM: `rangeForView('list')` = 14 dies fixos ([`agendaRange.ts`](../../../apps/tenant-portal/src/features/field-service/utils/agendaRange.ts)); no hi ha infinite scroll.

## Fora d’abast V1

- Time-grid (hores)
- Drag-and-drop
- Sync / integracions externes (Google, Outlook, CalDAV…)
- Edició de recordatoris existents
- Pintar visites FSM dins `/calendar`
- Cerca textual
- Filtre «Els meus events»
