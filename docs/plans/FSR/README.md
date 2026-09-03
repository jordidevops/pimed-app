# FSR tech-first — pla de producte i implementació

> **Estat:** pla de producte / arquitectura — **sense implementació de codi** (2026-07-23).  
> **Escenari:** Cal Ferran (1 local, ~40 comensals, ~11 taules, cambrers + cuina).  
> **Gap analysis origen:** [`docs/product-design/veriticals/FSR - Full Service Restaurant.md`](../../product-design/veriticals/FSR%20-%20Full%20Service%20Restaurant.md)  
> **Seed (dades demo):** [`docs/plans/seeds/plan-fsr-seed.md`](../seeds/plan-fsr-seed.md)

| Document | Contingut |
|----------|-----------|
| [01-domain-and-model.md](./01-domain-and-model.md) | Model de dades, estats, permisos, assets-as-tables |
| [02-flows-and-surfaces.md](./02-flows-and-surfaces.md) | Sala mòbil, Guest Table OS, KDS, tongades, QR |
| [03-implementation-roadmap.md](./03-implementation-roadmap.md) | Fases 0–5, criteris d'acceptació, fora d'abast |
| [04-security-and-realtime.md](./04-security-and-realtime.md) | ADR auth 3 superfícies + Broadcast + amenaces |
| [05-guest-table-os-ux.md](./05-guest-table-os-ux.md) | Barra visual guest, motion, tema, test del Reel |

---

## Respostes directes

| Pregunta | Resposta |
|----------|----------|
| Què el fa trencador? | El **bucle de transparència en viu** (sala ↔ cuina ↔ client) + **RRHH/torns al mateix producte**. Covermanager/TheFork fan reserves; Revo/Square fan TPV; el mid-market ES/CAT no uneix servei transparent + personal en una sola app. |
| Es veurà top tech pels clients? | **Només si el Guest Table OS és una superfície de disseny pròpia**, no un formulari. Timeline + ETA + carta visual + feedback quan el plat està llest. |
| Els cambrers tenen web al mòbil? | **Sí — nucli de Fase 1.** Mode **Sala** a l'employee portal: floor de taules, comanda tàctil, fire/tongades, alertes `ready`, crides. |

---

## Wedge trencador

Competitors cobreixen una peça. El wedge és **operar el servei amb transparència**, no només reservar o cobrar.

1. **Live service loop** — El client veu el mateix estat que cuina (preparant / llest / ETA).
2. **Cambrer amb superpoders al mòbil** — El telèfon és el centre de control de la sala (mode Sala).
3. **HR + dining al mateix tenant** — Torn, taula i comanda en una sola veritat.
4. **Carta viva** — 86/sold-out i menú del dia en temps real a guest + cambrer.
5. **Al·lèrgens first-class** — Snapshot per item, visible a KDS i guest.
6. **Sense matar l'hospitalitat** — QR complementa; el cambrer obre sessió, fa fire, serveix.

**No és trencador (no vendre-ho com a tal):** reserves online soles, KDS bàsic sense guest, “tenim una app”.

**Risc comercial:** el maître que només vol TheFork-killer pot dir no si les reserves arriben a Fase 3. Pitch en dos tracks:

| Track | Fases | Missatge |
|-------|-------|----------|
| *Wow servei* | 1–2 | Sala mòbil + KDS + Guest Table OS amb ETA |
| *Tanca deal clàssic* | 3–4 | Reserves amb capacitat + widget web |

---

## Decisions tancades

| ID | Decisió |
|----|---------|
| **FSR-1** | MVP guest = comanda per QR **sense pagament**; cobrament TPV extern. |
| **FSR-2** | Cambrer al centre; QR és complement, no kiosk QSR. |
| **FSR-3** | Auth: 3 superfícies BFF/Edge (guest / Sala / KDS). Cap SELECT anon directe sobre `dining_*`. |
| **FSR-4** | Realtime = **Broadcast** + poll fallback 5s. No publicar 3 taules calentes + trigger ETA. |
| **FSR-5** | Taules de sala = `data.assets` amb `metadata.kind='dining_table'` (no tercera entitat espacial). |
| **FSR-6** | Noms: `dining_sessions`, `dining_orders`, `dining_order_items`, `menu_items`, `reservations`, `ops_devices`. |
| **FSR-7** | MVP tech-first honest = **fi Fase 2**. Reserves = track comercial (Fase 3–4). |
| **FSR-8** | Fase 4 = **4B**: widgets reserva+carta sobre portal actual; TCMS-2/Puck no bloqueja. |
| **FSR-9** | `tenant_id` + `site_id` a totes les taules calentes; permisos `dining.*`. |
| **FSR-10** | `catalog_item_id?` opcional a `menu_items` (pont facturació futura). |

---

## Fora d'abast (MVP)

- Pagament Stripe / split bill / propines a l'app
- POS / TPV complet
- Integració TheFork / Resengo / Covermanager
- App nativa del cambrer
- ML d'ETA
- Substituir el rol de cambrer
- Reutilitzar `attendance_devices` per KDS (stack propi `ops_devices`)

---

## Ordre d'execució

1. Aquest pack documental (fet).
2. Actualitzar vertical FSR amb enllaç (fet / en paral·lel).
3. Codi: Fase 0 → 1 (Sala+KDS) → 2 (Guest) → 3 (reserves) → 4B (web).

Detall de fases: [03-implementation-roadmap.md](./03-implementation-roadmap.md).
