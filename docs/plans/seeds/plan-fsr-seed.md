# Seed FSR (restaurant amb cambrers) + gap analysis de reserves, carta i web

Pla per a un seed d'un **Full Service Restaurant** (FSR): restaurant amb un sol local, cambrers, cuina i **reserves de taula**. A diferència del seed QSR (BurgerVista), aquí el nucli del negoci no és la velocitat sinó **la reserva, la taula i la carta**.

**Estat:** pla, pendent de confirmació abans d'implementar SQL  
**Relacionat:**
- [`plan-qsr-burgervista-seed.md`](plan-qsr-burgervista-seed.md) (mateix format, vertical diferent)
- [`docs/product-design/veriticals/FSR - Full Service Restaurant.md`](../../product-design/veriticals/FSR%20-%20Full%20Service%20Restaurant.md) — gap analysis de mancances del vertical.
- [`docs/plans/FSR/README.md`](../FSR/README.md) — **pla de producte/implementació tech-first** (Sala, KDS, Guest Table OS, reserves). Aquest document (`plan-fsr-seed.md`) és **només per al seed de dades**; no hi repetim el gap analysis ni el roadmap de producte.

---

## Conclusió d'entrada (llegeix això primer)

Abans de dissenyar cap dada, cal dir-ho clar: **les coses que un FSR real necessita (reserves amb calendari/capacitat, carta/menú del dia, publicar-los a la web, gestió de comandes de cuina) no existeixen avui com a producte.** El detall complet d'aquesta anàlisi viu a [`FSR - Full Service Restaurant.md`](../../product-design/veriticals/FSR%20-%20Full%20Service%20Restaurant.md); aquí només en resumim l'impacte sobre el seed.

Això vol dir que aquest seed, fet **només amb el que existeix avui**, quedarà curt de veritat per a un FSR. Igual que amb BurgerVista, el valor principal d'aquest lot és **demostrar el que ja hi ha** (personal, torns, calendari laboral, portal genèric) amb simulacions clarament etiquetades per a la resta (reserves, carta, web).

---

## Escenari de negoci

**Restaurant:** "Cal Ferran" — restaurant de cuina mediterrània, Barcelona, **1 sol local**.  
**Capacitat:** ~40 comensals / ~11 taules (2, 4 i 6 places).  
**Servei:** dinar (13:00–16:00) i sopar (20:00–23:30). Tancat dilluns.  
**Propietari:** Ferran (chef-propietari) — equivalent a "owner" del tenant.

### Equip (~12 persones)

| Rol | Nombre | Notes |
|-----|--------|-------|
| Propietari / xef | 1 | `owner` — gestiona tot |
| Maître / cap de sala | 1 | `manager` site — gestiona reserves i cambrers |
| Cambrers/es | 4 | 2 torn dinar, 2 torn sopar (alguns dobles) |
| Cuina (xef + ajudants) | 3 | Cap de cuina + 2 ajudants |
| Rentaplats / suport | 1 | |
| Recepció / hostess (opcional) | 1 | Gestiona telèfon + reserves walk-in |
| Administració (part-time) | 1 | Factures, proveïdors |

### Torns

Dinar, Sopar, i un torn partit per qui fa els dos serveis. Tancament setmanal (dilluns) com a `non_working`.

---

## Com afecta el gap al disseny del seed

Cada element del seed que toca reserves, carta o web es marca com **Simulat** (convenció amb dades existents, sense motor real). El detall del "per què" de cada gap i el disseny de producte recomanat estan a [`FSR - Full Service Restaurant.md`](../../product-design/veriticals/FSR%20-%20Full%20Service%20Restaurant.md):

| Element del seed | Simulat amb | Gap de producte (detall al doc de vertical) |
|-------------------|-------------|----------------------------------------------|
| Reserves | `data.calendar_events` amb `entity_type='reservation'` + metadata | §1 Reserves amb calendari i capacitat |
| Taules amb capacitat | `data.locations` (type `room`) amb `metadata.capacity` | §1 (falta `capacity` real a `assets`) |
| Carta / menú del dia | `data.catalog_items` amb categoria `carta`/`menu_dia` | §2 Carta i menú del dia |
| Web amb carta i horaris | `public_page` amb HTML escrit a mà | §3 Publicació de la carta i horaris a la web |
| Reserva des de la web | No hi ha proxy net (a l'apartat de `public_leads`) | §4 Reserva online pública |
| Comandes de cuina (KDS) | Fora d'abast del seed (no hi ha `orders`) | §5 Gestió de cuina i comandes |
| Autoservei tipus QSR | Fora d'abast del seed | §6 Autoservei tipus QSR |

---

## Disseny del seed (el que SÍ es pot construir avui)

Donat el gap, el seed es limita al que la capa laboral/HR/portal pot demostrar de veritat, amb simulacions clarament etiquetades per a la resta.

### Fitxers previstos (mateix patró que BurgerVista)

`supabase/seeds/fsr_cal_ferran/`

| Fitxer | Contingut | Estat |
|--------|-----------|-------|
| `00_readme.sql` | Logins, gaps, com carregar | Real |
| `01_org_users.sql` | Tenant "Cal Ferran", 1 site, usuaris (propietari, maître, admin) | Real |
| `02_employees_roles.sql` | ~12 empleats: cuina, sala, rentaplats, recepció; `work_roles` FSR (`chef`, `sous_chef`, `waiter`, `host`, `dishwasher`) | Real |
| `03_calendars_pauses_holidays.sql` | Calendari 6 dies (tancat dilluns), pauses hospitality, festius CAT | Real |
| `04_locations_tables.sql` | Sala + **taules com a `locations` amb `metadata.capacity`** | **Simulat** (sense Assets natius amb capacitat) |
| `05_shifts_planning.sql` | Torns dinar/sopar, coverage per servei | Real |
| `06_absences.sql` | Vacances/absències | Real |
| `07_attendance_punches.sql` | Fitxatges YTD mostrejats | Real |
| `08_catalog_menu.sql` | `catalog_items` amb carta + "menú del dia" per dia de setmana (nom, no lògica) | **Simulat** |
| `09_reservations_demo.sql` | `calendar_events` amb `entity_type='reservation'` + metadata taula/comensals | **Simulat** |
| `10_templates_documents.sql` | Plantilla reserva d'esdeveniment (ja existent a plataforma), full de comanda proveïdors | Real (reaprofitat) |
| `11_public_site_menu.sql` | `public_sites` + 1 `public_page` amb carta en HTML manual | **Simulat, sense sync** |
| `seed.sql` | Monòlit | — |

### Namespace UUID

Prefix `b1…` (evitar col·lisió amb Acme `1…` i BurgerVista `a1…`).

---

## Decisions preses (defaults, sense bloquejar el pla)

- **1 sol local** (a diferència de BurgerVista amb 2): correspon a l'escenari FSR clàssic sol·licitat.
- **Capacitat ~40 comensals / 11 taules**: mida típica de restaurant de barri.
- **Reserves simulades a `calendar_events`**, no a una taula nova: aquest lot **no crea esquema de producte nou** (igual que BurgerVista, `config.toml` intacte, sense migracions).
- **Carta simulada a `catalog_items` + HTML estàtic al portal**: sense sincronització; el README ho marcarà com demo, no com a feature.
- **Sense dades de vendes/POS**: mateix criteri que BurgerVista.

## Camí de producte (fora d'aquest lot)

El backlog de producte complet viu a [`docs/plans/FSR/README.md`](../FSR/README.md) (implementació) i al gap analysis [`FSR - Full Service Restaurant.md`](../../product-design/veriticals/FSR%20-%20Full%20Service%20Restaurant.md), no en aquest pla de seed.

---

## Criteris d'acceptació del seed

- `seed.sql` executable al SQL Editor post-`db reset`; Acme i BurgerVista intactes.
- Es llegeix com un restaurant de cambrers (rols, torns dinar/sopar, taules, carta) en <5 min.
- Cada element simulat (taules, carta, reserves, web) ho diu explícitament al README amb la mateixa claredat que aquest document.
- No es crea cap taula, columna ni migració nova de producte.

## Fora d'abast d'aquest lot

- Migracions de producte (reservations, capacity, menu_items, bloc de menú al portal)
- Integració TheFork/Resengo/Covermanager
- Pagaments de senyal / dipòsits
- Substituir Acme o BurgerVista

---

## Checklist d'implementació (pendent de confirmació)

- [ ] Confirmar l'escenari (nom, capacitat, equip) amb l'usuari abans de generar SQL
- [ ] `00_readme.sql`
- [ ] `01_org_users.sql`
- [ ] `02_employees_roles.sql`
- [ ] `03_calendars_pauses_holidays.sql`
- [ ] `04_locations_tables.sql`
- [ ] `05_shifts_planning.sql`
- [ ] `06_absences.sql`
- [ ] `07_attendance_punches.sql`
- [ ] `08_catalog_menu.sql`
- [ ] `09_reservations_demo.sql`
- [ ] `10_templates_documents.sql`
- [ ] `11_public_site_menu.sql`
- [ ] `seed.sql` entrypoint monòlit
