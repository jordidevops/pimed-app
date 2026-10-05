# 04 — Backlog V2 (després de V1 tancada)

No començar cap ítem V2 fins que [`CHECKLIST.md`](./CHECKLIST.md) V1 estigui 100% `[x]`.

Ordre suggerit dins V2 (dependències): **cerca / Els meus** → **time-grid** → **DnD** → **integracions**.

---

## V2.1 — Cerca

**Valor:** trobar un event per títol/client/metadata sense navegar el mes.

### Abast

- Camp de cerca a `/calendar` (debounce).
- Query: filtrar client-side sobre el rang carregat **o** RPC/search dedicat si el rang és insuficient.
- Resultats: llista + salt a `date` + obrir detall.
- URL: `?q=` opcional.

### No fer

- Cerca full-text cross-tenant.
- Reemplaçar filtres tipus/site.

### DoD

- [x] Cerca per títol (mínim) amb feedback empty.
- [x] Seleccionar resultat navega a la data correcta.
- [x] Tests unitaris del matching + smoke UI.

---

## V2.2 — «Els meus events»

**Valor:** veure només el que m’afecta (owner, assignee, o metadata de persona).

### Abast

- Toggle / chip «Els meus» a la pàgina (no al widget).
- Definició producte tancada abans de codi:
  - manuals on `owner_id = me`, **i/o**
  - tasques assignades a mi, **i/o**
  - shift_slots on soc a `metadata` / entity.
- URL: `?mine=1`.
- Compatible amb filtres tipus/site (AND).

### Depèn de

- Contracte clar per entity_type (què significa «meu» a project/task/shift).
- Possible índex/RPC si el filtre no es pot fer només al client.

### DoD

- [x] Documentada la regla «meu» per cada `entity_type` registrat.
- [x] Toggle persistent a URL.
- [x] Tests amb fixtures per owner vs aliè.

Contracte: [`05-mine-events-contract.md`](./05-mine-events-contract.md).

---

## V2.3 — Time-grid (graella horària)

**Valor:** dia/setmana amb eix d’hores (més a prop de Google Calendar).

### Abast

- Nova vista o mode `day`/`week` amb columnes temporals.
- All-day row a dalt.
- Events timed posicionats per `start_at`/`end_at`.
- Multiday: barra all-day o span visual.
- Reutilitzar projector; no reinventar solapaments de dies.

### No fer encara

- DnD (V2.4).
- Zoom minuts arbitrari (30/15) si complica: començar amb slots 30 min.

### DoD

- [x] Day + week timed llegibles a desktop.
- [x] Mòbil: degradació acceptable (llista o day timed simplificat).
- [x] Tests de layout (overlap stacking bàsic).

---

## V2.4 — Drag-and-drop

**Valor:** replanificar manuals (i potser tasques) arrossegant.

### Abast

- DnD només sobre events **editables** (`manual` + permís; tasques si RPC ho permet).
- Drop a dia (month/list) i a slot horari (si V2.3 fet).
- Confirmació o undo curt per canvis > X hores.
- Persistència via `update_calendar_event` / RPC de mòdul (mai update directe de derivats sense RPC).

### No fer

- DnD de visites FSM des de `/calendar`.
- Resize de durada a V2.4a si el risc és alt (pot ser V2.4b).

### DoD

- [ ] Moure manual actualitza `start_at`/`end_at` i invalida query.
- [ ] Events no editables no són draggables.
- [ ] Error de permís amb toast llegible.
- [ ] Tests d’integració del flux update.

---

## V2.5 — Integracions externes

**Valor:** veure events de `/calendar` a Google/Outlook/Thunderbird sense OAuth.

### MVP tancat: iCal subscribe read-only

Pla detallat (implementar més endavant):

| Doc | Contingut |
|-----|-----------|
| [`06-ical-how-it-works.md`](./06-ical-how-it-works.md) | Format ICS, subscribe vs import, UID, TZ, camps, finestra |
| [`07-ical-security.md`](./07-ical-security.md) | Token hash, opt-in tenant, AuthZ vs RLS, DoD proves |
| [`08-ical-architecture-and-phases.md`](./08-ical-architecture-and-phases.md) | Schema, RPCs, Edge, generador TS, fases I1–I4 |

### Candidats post-MVP

2. **Google Calendar** OAuth (push/pull).  
3. **Microsoft Outlook / Graph**.  
4. **CalDAV** genèric.

### DoD (MVP iCal — quan s’implementi)

- [ ] Tenant opt-in `calendar.ical_enabled`.  
- [ ] Feed autenticat per token (hash a BD); revocació + caducitat.  
- [ ] Contingut = mateix conjunt autoritzat que `/calendar` (finestra −180/+365).  
- [ ] Scope `mine` al servidor.  
- [ ] Edge `calendar-ical-feed` + tests ICS.  
- [ ] UI create/list/revoke + docs ajuda + runbook.

Google/Outlook OAuth queden com epics **després** que l’MVP iCal estigui estable.

---

## Fora de V2 (explícit)

- Fusionar `/field/agenda` dins `/calendar`.
- Reemplaçar Control horari / labor calendar.
- Notificacions push de calendari (canal separat).
- IA que crea events sense confirmació humana.
