# 03 — Fases V1

Implementar **en ordre**. No saltar fases: cada una té dependències de model/nav/UI.

---

## Fase 0 — Nav, i18n i permisos de menú

**Objectiu:** l’usuari veu els noms correctes i l’entrada `/calendar` (encara que la pàgina sigui stub).

### Feina

1. Catalog [`navCatalog.ts`](../../../apps/tenant-portal/src/features/sidebar-nav/navCatalog.ts):
   - id `company_calendar` → `/calendar`
   - `labelKey: 'nav.company_calendar'`
   - icona `CalendarRange`
   - gate `canViewCalendar`
2. `NavGate` + [`useSidebarNav.ts`](../../../apps/tenant-portal/src/features/sidebar-nav/useSidebarNav.ts) / [`resolveNav.ts`](../../../apps/tenant-portal/src/features/sidebar-nav/resolveNav.ts):  
   `canViewCalendar = usePermission('calendar.view')`.
3. [`defaultNavLayout.ts`](../../../apps/tenant-portal/src/features/sidebar-nav/defaultNavLayout.ts): inserir després de `field_agenda`.
4. Rename:
   - `nav.attendance_calendar` → «El meu calendari»
   - `self_service.calendar` (attendance) → mateix
5. i18n ca/en/es: `common.json` (`nav.company_calendar`, rename), claus dashboard CTA a `common` o `calendar`.
6. Ruta stub a [`App.tsx`](../../../apps/tenant-portal/src/App.tsx): `/calendar` → placeholder o shell amb gate.
7. Tests [`resolveNav.test.ts`](../../../apps/tenant-portal/src/features/sidebar-nav/resolveNav.test.ts): gate, ordre, merge layout custom.

### DoD

- [ ] Sidebar Operativa: **Calendari** visible amb `calendar.view`.
- [ ] Jo: **El meu calendari**.
- [ ] FSM: Agenda i Calendari coexistixen amb labels diferents.
- [ ] Sense permís: entrada oculta.
- [ ] Layouts desats reben `company_calendar` després de `field_agenda`.

---

## Fase 1 — Model: projecció, colors, week start, delete RPC

**Objectiu:** dades i utilitats correctes abans de la pàgina rica.

### Feina

1. Helper projecció multiday/all-day + tests (DST, fi exclusiva).
2. `calendarDateUtils` / `CalendarGrid`: `weekStartsOn` opcional (default 1).
3. `CalendarGridEvent`: camp color resolt; FSM segueix amb `tone`.
4. Registrar `modules/manual.calendar.ts` + import a `index.ts`.
5. Migració + RPC delete manual + test SQL.
6. Adjust `groupEventsByDayKey` o substituir-lo pel projector als consumidors nous/widget.

### DoD

- [ ] Tests unitaris verds (multiday, all-day, week start, color).
- [ ] Test SQL delete: owner OK, manage OK, aliè KO, derivat KO.
- [ ] `manual` al registry.

---

## Fase 2 — Components compartits (detall + formulari)

**Objectiu:** una sola implementació de detall/create/edit/delete.

### Feina

1. Extreure `EventDetail` (Dialog/Drawer + `DefaultEventDetail` + DetailModal registry) des de `CalendarWidget`.
2. `CreateEventForm`:
   - selector Àmbit (Empresa / centre)
   - all-day amb inputs `date`
   - delete (si aplica) o botó al detall que crida RPC
3. Invalidació `['calendar_events']` en create/update/delete.
4. i18n: `calendar.entity.manual` = «Event»; claus àmbit/delete/confirm.

### DoD

- [ ] Widget i (futura) pàgina importen els mateixos mòduls.
- [ ] Crear amb `site=all` exigeix tria explícita d’àmbit.
- [ ] All-day no deixa `datetime-local` enganyós.
- [ ] Owner pot eliminar el seu manual.

---

## Fase 3 — `CompanyCalendarPage`

**Objectiu:** pàgina completa V1.

### Feina

1. `CompanyCalendarPage.tsx` + `companyCalendarUrlState.ts` (+ tests).
2. Vistes `list|day|week|month`.
3. Llista: 14 dies, «Més 14 dies» → `span` 28/42; només dies amb events (o empty state).
4. Week/month via `CalendarGrid` + mapper amb colors + projecció.
5. Filtres tipus + site a UI i URL.
6. `useCalendarEvents` amb rang segons vista; filtre tipus client.
7. `weekStartsOn` + default view des de settings.
8. Gate UI: sense `calendar.view` → empty/redirect.
9. `?create=1` obre formulari.
10. PageShell / tabs coherents amb Agenda FSM sense copiar còpia de camp.

### DoD

- [x] Totes les vistes navegables i URL compartible.
- [x] Multiday i colors correctes.
- [x] Filtres persistents a URL.
- [x] Acceptació producte de [`01`](./01-product-and-naming.md) + [`02`](./02-data-model-and-ux.md).

---

## Fase 4 — Widget dashboard + wiring

**Objectiu:** dashboard coherent amb la pàgina.

### Feina

1. Aprimar `CalendarWidget` a preview (usa projector + detall compartit).
2. `DashboardPage`: gate `calendar.view`; CTA «Veure calendari»; mantenir CTA Agenda FSM.
3. «Nou event» del widget → `/calendar?create=1&date=...`.
4. Actualitzar e2e `calendar-widget.spec.ts` / `calendar-reminders.spec.ts` si cal.

### DoD

- [x] Sense `calendar.view`: secció oculta.
- [x] Dos CTAs FSM amb copy diferent.
- [x] Cap lògica duplicada de modal/form al widget.
- [x] E2E verds o actualitzats.

---

## Fase 5 — Hardening i tancament V1

**Objectiu:** no deixar forats.

### Feina

1. Revisar criteris d’acceptació (llista a baix).
2. Smoke manual: FSM + no-FSM, viewer/member/manager.
3. Actualitzar [`STATUS.md`](./STATUS.md) i [`CHECKLIST.md`](./CHECKLIST.md).
4. Nota curta a help si cal (opcional): diferència Agenda vs Calendari vs El meu calendari.

### Criteris d’acceptació V1 (tots obligatoris)

- [x] `/calendar` amb list/day/week/month + filtres tipus; llista + «Més 14 dies».
- [x] Sense scroll infinit de dies.
- [x] Multiday/all-day correctes + zona horària.
- [x] Setmana respecta `week_starts_on`.
- [x] Crear en vista global no crea event Empresa accidental.
- [x] Manuals: owner/manager editen/eliminen; derivats no s’eliminen des del calendari.
- [x] FSM: Agenda ≠ Calendari al sidebar; dashboard amb dos CTAs.
- [x] Jo: «El meu calendari».
- [x] Sense `calendar.view`: ni nav, ni dashboard, ni contingut útil a `/calendar`.
- [x] Widget = preview compartit.

### Fitxers principals (mapa)

| Àrea | Fitxers |
|------|---------|
| Pàgina | `CompanyCalendarPage.tsx`, `companyCalendarUrlState.ts`, projector/mapper |
| Registry | `modules/manual.calendar.ts`, `index.ts` |
| UI compartida | detall extret, `CreateEventForm.tsx` |
| Grid/utils | `CalendarGrid.tsx`, `calendarDateUtils.ts` |
| Hook | `useCalendarEvents.ts` |
| Backend | migració delete + `supabase/tests/...` |
| Nav | `navCatalog`, `defaultNavLayout`, `resolveNav`, `useSidebarNav` |
| App | `App.tsx`, `DashboardPage.tsx`, `CalendarWidget.tsx` |
| i18n | `locales/{ca,en,es}/common.json`, `calendar.json`, attendance self_service |
| Tests | unit + SQL + resolveNav + e2e widget |
