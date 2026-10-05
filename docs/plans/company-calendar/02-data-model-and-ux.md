# 02 — Model de dades i UX

## Font de dades

- Vista: `api.calendar_events` (security_invoker + RLS).
- Hook: [`useCalendarEvents`](../../../apps/tenant-portal/src/features/calendar/useCalendarEvents.ts).
- Registry: [`CalendarRegistry`](../../../apps/tenant-portal/src/features/calendar/CalendarRegistry.ts) — mòduls `task`, `project`, `shift_slot`; V1 afegeix `manual`.
- Permisos: `calendar.view` / `calendar.edit` / `calendar.manage`.
- Crear manuals: RPC `create_calendar_event_with_reminders`.
- Actualitzar manuals: RPC `update_calendar_event`.
- Eliminar manuals: **nova** RPC/migració V1 (avui DELETE RLS només `calendar.manage`).

## URL canònica (`/calendar`)

```
?view=list|day|week|month
&date=YYYY-MM-DD
&types=a,b          # opcional; buit = tots
&site=all|UUID
&span=14|28|42      # només list
&create=1           # obre formulari (opcional)
```

- Util propi: `features/calendar/companyCalendarUrlState.ts` (parse/serialize determinista + tests).
- **No** reutilitzar `agendaUrlState` de camp (domini diferent).

## Vistes

| View | UI | Rang |
|------|-----|------|
| `list` | Dies agrupats (només dies amb events; empty state si tot buit) | `span` dies des d’anchor |
| `day` | Llista d’un dia | 1 dia |
| `week` | `CalendarGrid` week | setmana segons `weekStartsOn` |
| `month` | `CalendarGrid` month | graella del mes |

Defaults:

- Mòbil → `list`.
- Desktop → `default_calendar_view` si és `day|week|month`; altrament `week`.
- Config no admet `list` avui: no forçar-lo al settings V1.

## Filtres

- **Tipus:** unió `CalendarRegistry.getAll()` ∪ `entity_type` presents a les dades; `types=` a URL; defecte «Tots».
- **Àmbit:** `site=UUID` → centre + globals (`site_id` null); `site=all` → tot el permès per RLS. Defecte = centre actiu si existeix, sinó `all`.
- Filtre de tipus al **client** després de la query de rang (V1). RLS = autoritat de visibilitat.

## Crear / editar / eliminar

- Formulari compartit (`CreateEventForm` millorat).
- Selector obligatori **Àmbit**: Empresa | centre autoritzat.
  - Preselecció = centre del filtre URL si és UUID.
  - En `site=all`: **no** preseleccionar Empresa silenciosament.
- All-day: inputs `date`; normalització local; render amb `event.all_day` (no inferir només per mitjanit).
- Timed: `datetime-local`.
- Detall: editar manuals; eliminar amb confirmació si owner o `calendar.manage`.
- Events derivats: només enllaç a entitat origen (no delete des del calendari).
- «Nou event» des del widget → `/calendar?create=1&date=...`.

## Projecció multiday (obligatori)

Helper únic (ex. `projectEventsOntoDays`):

| Cas | Dies visibles |
|-----|----------------|
| Puntual / `end_at` null | Dia d’inici |
| Timed multiday | Tots els dies locals solapats |
| All-day | Interval amb **fi exclusiva**, sense salts UTC |

Consumidors: widget, llista, `CalendarGrid`. Un sol agrupador.

## Colors

- Ampliar `CalendarGridEvent` amb color resolt (hex validat + fallback).
- Mantenir `tone` per Agenda FSM.
- Cards/dots del calendari d’empresa usen `resolvedColor` del registry/event.

## Setmana

- `useCalendarDisplaySettings().weekStartsOn`.
- `CalendarGrid` / `calendarDateUtils` accepten `weekStartsOn` (default 1 = dilluns) per no trencar FSM.

## Widget dashboard

Fitxers: [`DashboardPage.tsx`](../../../apps/tenant-portal/src/pages/DashboardPage.tsx), [`CalendarWidget.tsx`](../../../apps/tenant-portal/src/features/calendar/CalendarWidget.tsx).

1. Secció només amb `calendar.view`.
2. CTA primari **Veure calendari** → `/calendar`.
3. FSM: CTA secundari **Veure agenda de visites** → `/field/agenda` (ja existeix).
4. Preview: mes (o setmana mòbil) + llista del dia + detall compartit.
5. Sense filtres/switcher de vistes al widget.

## Delete manual (backend)

Migració + RPC (nom sugerit: `api.delete_manual_calendar_event(p_id uuid)`):

- Tenant actiu + membership.
- `entity_type = 'manual'` només.
- Actor = `owner_id` **o** `calendar.manage` al context del `site_id`.
- Test SQL: permès owner, permès manage, prohibit membre aliè, prohibit esborrar `task`/`project`/`shift_slot`.

## Tests mínims V1

- Unit: multiday, all-day + DST, weekStartsOn 0/1, color fallback, URL state, filtre site.
- SQL: delete manual.
- Nav: gate, ordre, merge layout custom.
- E2E existents del widget: actualitzar a preview + CTA (no trencar `calendar-widget.spec.ts` / reminders sense adaptar).
