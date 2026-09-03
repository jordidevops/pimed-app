# FSR — Roadmap d'implementació

> Part del pack [`README.md`](./README.md).

## Fases

### Fase 0 — Carta + taules

- Migracions `menu_items` + convenció assets `dining_table` (capacity validada).
- UI tenant-portal: CRUD carta (llenguatge xef) + taules.
- Permisos `dining.menu.*` / `dining.floor.*`.
- Seed Cal Ferran **només** passa a “real” quan això existeix; fins llavors `plan-fsr-seed.md` segueix simulat o es reescriu explícitament.

### Fase 1 — Sala mòbil + KDS (*wow staff*)

- `dining_sessions`, `dining_orders`, `dining_order_items`, `ops_devices`, `dining_service_events`.
- Stack BFF/Edge KDS complet (no “clonar una taula”).
- Mode **Sala** a employee portal (floor / taula / comanda / ready / crides) + gate `site_id`.
- Broadcast `dining:{site_id}` + poll fallback.

**Acceptació:** cambrer al mòbil envia 3 plats → KDS &lt;2s en LAN estable; `ready` arriba a Sala sense refrescar; funciona amb poll si Broadcast cau.

### Fase 2 — Guest Table OS + ETA (*wow client*)

- Guest BFF (patró inspect/station).
- QR sessió vs `asset_tag`.
- Timeline + ETA + carta visual + crida + toast `ready` ([05-guest-table-os-ux.md](./05-guest-table-os-ux.md)).
- ETA via RPC / `dining_sessions.eta_seconds` controlat.

**Acceptació:** test del Reel 5s; aïllament cross-table; ETA canvia amb la cua; sense pagament.

**= MVP tech-first honest.**

### Fase 3 — Reserves (*tanca deal clàssic*)

- `reservations` + `check_table_availability` + calendari de sala.
- `seated` → obre/lliga sessió.
- Recordatoris: motor de notificacions quan estigui disponible (no bloqueja).

### Fase 4B — Web pública mínima

- Widget reserva + bloc carta/horaris sobre portal **actual**.
- TCMS-2/Puck és millora paral·lela, **no** prerequisit.

### Fase 5 — Avançat

- Floor plan operatiu (UI locations + dades assets), waitlist, no-show, dipòsits, transfer/merge taula, refinament visual guest.

---

## Criteris d'acceptació agregats

**MVP tech-first (fi Fase 2)**

1. Sala al mòbil opera el servei (obrir taula, comanda, fire, served).
2. KDS en viu amb fallback poll.
3. Guest Table OS “top tech” (timeline + ETA + ready toast); no sembla backoffice.
4. Cobrament no passa per PiMed.

**MVP comercial FSR (fi Fase 3 + 4B)**

5. Reserves amb capacitat sense solapament.
6. Reserva online mínima + carta pública.
7. Pitch honest: HR existent + dining ops nou.

---

## Fora d'abast MVP

- Pagament / split / propines
- POS / TheFork / Covermanager
- App nativa cambrer
- ML ETA
- Matar el rol de cambrer
- Reutilitzar `attendance_devices` per KDS

---

## Estimació d'esforç (ordre de magnitud)

| Fase | Nota |
|------|------|
| 0 | Mitjà — schema + UI CRUD |
| 1 | **Gran** — devices BFF + Sala + KDS + Broadcast (setmanes, no un sprint cosmètic) |
| 2 | Mitjà–gran — guest BFF + UX visual |
| 3 | Mitjà — availability + calendari |
| 4B | Petit–mitjà si es queda en widgets |

---

## Dependències externes

- Employee portal i attendance-station com a **patrons**, no com a codi a forçar.
- Notificacions completes: útils per recordatoris reserva; no bloquejen Fase 1–2.
- TCMS-2: opcional; no bloqueja 4B.
