# Guia pràctica — Seed BurgerVista (menjar ràpid)

Guia operativa per carregar, explorar i provar el dataset.  
Anàlisi de producte / gaps de compra: [`plan-qsr-burgervista-seed.md`](plan-qsr-burgervista-seed.md).  
SQL: [`supabase/seeds/qsr_burgervista/`](../../supabase/seeds/qsr_burgervista/).

---

## 1. Com carregar-lo

**Requisits**

- Supabase local en marxa (`supabase start`).
- Base ja inicialitzada amb `supabase db reset` (plans, Acme, migracions). Aquest seed **no** substitueix Acme; hi convive.

**No** està a `config.toml` → no es carrega sol amb el reset.

### Opció A — SQL Editor (recomanat)

1. Obre Studio: http://127.0.0.1:54323 → SQL Editor.
2. Enganxa el contingut de [`seed.sql`](../../supabase/seeds/qsr_burgervista/seed.sql) (monòlit ~90 KB).
3. Executa. Pot trigar ~15–30 s (fitxatges YTD).
4. Al final hauries de veure un `NOTICE`: `BurgerVista seed OK: sites=2, employees_local=20, delivery_zones=2`.

### Opció B — Mòduls en ordre

Executa un per un:

`00_readme.sql` → `01` … `12_recruitment.sql`  
(el `07` és el més lent: crea la funció i genera punches).

### Opció C — Docker / psql

```bash
docker cp supabase/seeds/qsr_burgervista/seed.sql supabase_db_<project>:/tmp/bv_seed.sql
docker exec -i supabase_db_<project> psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/bv_seed.sql
```

### Re-execució

Els INSERTs usen `ON CONFLICT DO NOTHING` / updates idempotents on és possible.  
El bloc de fitxatges (`07`) **esborra i regenera** punches/entries/summaries del tenant BurgerVista des de l’1 de gener fins avui. La resta es pot re-enganxar sense duplicar IDs fixes.

---

## 2. Què conté (resum)

| Bloc | Contingut |
|------|-----------|
| Org | Tenant **Gestió Ràpida BCN SL** (`burgervista-bcn`), pla Pro, arquetip hospitality |
| Locals | **Eixample** + **Diagonal** |
| Usuaris app | 7 comptes (CEO, 2 admins, 2 directors, 2 caps de torn) |
| Empleats | 10/local + 3 corporatius; rols: director, cap torn, cuina, mostrador, **expedició**, sala, floater, DT (només Diagonal) |
| Zones | Cuina, mostrador, sala, **expedició/domicili**, magatzem; Diagonal + **servei amb auto** (simulat) |
| Horaris | Grups calendari 7 dies; pauses hospitality; festius CAT 2026; overrides estudiants / caps tarda |
| Torns | Plantilles Obertura → Tancament; coverage pic sopar/domicili; slots ~2 setmanes; 1 opening obert |
| Absències | Entitlement 2026 + 5 absències mostra |
| Fitxatges | YTD mostrejat: **caps/directors 100%** dies laborables, **crew ~40%** + anomalies |
| Docs | 8 plantilles + documents generats + assignacions portal (protocol, formació) |
| Portals | 2 `public_sites` (un per local) + tokens portal empleat |
| Skills | Catàleg + assignacions empleat (11) |
| Reclutament | Flag ON, 3 ofertes en viu + 1 draft, 10 candidatures en etapes (12) |

**IDs clau (prefix `a1…`)**

| Entitat | UUID |
|---------|------|
| Tenant | `a1000000-0000-0000-0000-000000000001` |
| Site Eixample | `a3000000-0000-0000-0000-000000000001` |
| Site Diagonal | `a3000000-0000-0000-0000-000000000002` |

---

## 3. Amb quins usuaris entrar

**Password de tots:** `Test1234!`  
**PIN portal empleat (tokens seed):** `1234`

### Tenant-portal (app)

| Email | Persona | Accés |
|-------|---------|--------|
| `marc@burgervista.demo` | Marc Serra (CEO) | `owner` global — veu els 2 locals |
| `nuria@burgervista.demo` | Núria Vila | `manager` global — admin RRHH |
| `jordi@burgervista.demo` | Jordi Pujol | `member` global — admin operativa |
| `laura@burgervista.demo` | Laura Roca | `manager` **només Eixample** |
| `pau@burgervista.demo` | Pau Soler | `member` Eixample (cap torn matí) |
| `elena@burgervista.demo` | Elena Martí | `manager` **només Diagonal** |
| `toni@burgervista.demo` | Toni Costa | `member` Diagonal (cap torn matí) |

Acme segueix disponible (`alice@acme-corp.com`, etc.) al mateix reset.

### Portal empleat (tokens de prova)

Secrets en clar (hash SHA-256 a BD); PIN `1234`:

| Empleat | Token secret (dev) | Ús |
|---------|-------------------|-----|
| Laura (directora Eixample) | `ep0-dev-bv-laura` | Manager local |
| Pau (cap matí) | `ep0-dev-bv-pau` | Cap de torn |
| Irene (expedició Eixample) | `ep0-dev-bv-irene` | Canal domicili (capa laboral) |
| Elena (directora Diagonal) | `ep0-dev-bv-elena` | Manager Diagonal |
| Oriol (expedició Diagonal) | `ep0-dev-bv-oriol` | Expedició |
| Marc Vidal (cuina) | `ep0-dev-bv-marc-vidal` | Crew cuina |

La URL base local del portal sol estar a settings `employee_portal.dev_base_url` (p.ex. `http://localhost:3002`) — igual que Acme.

### Estacions de fitxatge

| Local | `device_public_id` | PIN estació |
|-------|-------------------|-------------|
| Eixample | `bv-eixample-station-01` | `4321` |
| Diagonal | `bv-diagonal-station-01` | `4321` |

Document IDs kiosk (exemples): `BV-E01`…`BV-E10`, `BV-D01`…`BV-D10`.

---

## 4. Quines proves fer (checklist demo)

### A. Impressió “és un restaurant” (< 5 min)

1. Login com **Marc** → veure 2 sites BurgerVista.
2. Empleats amb `job_title` / rols cuina, mostrador, **expedició** (no electricistes).
3. Locations: zona **Expedició / domicili** als dos locals; Diagonal té **Servei amb auto**.
4. Documents: plantilles uniforme, formació, checklists obertura/tancament/expedició.

### B. Multi-seu i permisos

5. Login **Laura** → només Eixample (no hauria de gestionar Diagonal com a manager de site).
6. Login **Elena** → només Diagonal.
7. Login **Núria** → vista corporativa (els dos locals).

### C. Planificació i domicili (capa laboral)

8. Torns: plantilles Obertura, Dinar, Sopar, Tancament.
9. Coverage / demanda al **sopar** amb rol expedició + cuina.
10. Slots published de la setmana actual / següent.
11. Opening obert: “Reforç expedició divendres (pic apps)”.
12. Recordar: **no hi ha comandes Glovo** — només personal i checklists.

### D. Control horari

13. Fitxatges des de gener 2026: directors/caps densos; crew més espars.
14. Algunes anomalies (pausa oberta, falta OUT) per provar revisió.
15. Pauses hospitality (dinar entre torns / descans breu).
16. Festius Catalunya 2026 assignats.
17. Estació o portal amb PIN `1234` / document_id `BV-…`.

### E. RRHH / paperassa

18. Absències: aprovades + una `requested` (vacances Oriol).
19. Documents generats (entregues uniforme, formacions).
20. Assignació protocol horari al portal dels empleats de local.

### F. Reclutament (12_recruitment.sql)

21. Login **Marc** o **Núria** → sidebar **Reclutament** → tab **Candidatures**: Kanban amb ~10 cards i chip d’oferta.
22. Filtrar per oferta / lloc de treball; arrossegar una card entre etapes.
23. Tab **Ofertes**: fila sencera clicable + badge “En viu”; obrir una oferta → tab Candidatures / Publicació.
24. Oferta esborrany “Suport floater” → tab Publicació mostra checklist de readiness.
25. **Configuració**: seccions + cercar un membre per recordatoris SLA.

### F. Què NO esperar (gaps conscients)

- % laboral / vendes / TPV  
- Integració Glovo / riders / comandes  
- Daypart com a dimensió nadiua d’informes  
- Tipatge real `drive_thru` (és `outdoor` + metadata)  
- Portal del franquiciador / xarxa de marca  

Detall: secció “Per què un client diria que no” al [pla](plan-qsr-burgervista-seed.md).

---

## 5. Fitxers SQL

| Fitxer | Contingut |
|--------|-----------|
| `seed.sql` | Monòlit (enganxar al SQL Editor) |
| `00_readme.sql` | Comentaris ràpids + enllaç a aquesta guia |
| `01_org_users.sql` | Tenant, sites, auth, members |
| `02_employees_roles.sql` | Empleats + work_roles |
| `03_calendars_pauses_holidays.sql` | Calendaris, pauses, festius |
| `04_locations_stations.sql` | Zones, estacions, ALA |
| `05_shifts_planning.sql` | Torns, coverage, slots, openings |
| `06_absences.sql` | Vacances / absències |
| `07_attendance_punches.sql` | Funció YTD + `SELECT` |
| `08_templates_qsr.sql` | Plantilles |
| `09_documents_generated.sql` | Documents + assignacions |
| `10_portals.sql` | Public sites + tokens |
| `11_skills.sql` | Catàleg skills QSR + assignacions empleats |

Funció regenerable: `SELECT data.seed_burgervista_attendance_punches();`

---

## 6. Smoke SQL ràpid (opcional)

```sql
SELECT count(*) AS sites FROM data.sites
WHERE tenant_id = 'a1000000-0000-0000-0000-000000000001';
-- esperat: 2

SELECT count(*) AS emps FROM data.employees
WHERE tenant_id = 'a1000000-0000-0000-0000-000000000001' AND site_id IS NOT NULL;
-- esperat: 20

SELECT count(*) AS delivery_zones FROM data.locations
WHERE tenant_id = 'a1000000-0000-0000-0000-000000000001'
  AND metadata->>'channel' = 'delivery';
-- esperat: 2

SELECT count(*) AS punches FROM data.time_punches
WHERE tenant_id = 'a1000000-0000-0000-0000-000000000001';
-- ordre de milers (YTD mostrejat)

SELECT count(*) AS skills FROM data.skills
WHERE tenant_id = 'a1000000-0000-0000-0000-000000000001';
-- esperat: 8

SELECT count(*) AS employee_skills FROM data.employee_skills
WHERE tenant_id = 'a1000000-0000-0000-0000-000000000001';
-- esperat: ≥ 20
```
