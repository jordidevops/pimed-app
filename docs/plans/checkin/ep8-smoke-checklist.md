# EP8 — Smoke checklist: confirmació mensual L1 via portal públic

> **Àmbit:** portal empleat **sense compte** (`apps/public-portal`, `/e/{secret}`) · confirmació del registre (dies i hores correctes; no signatura electrònica L2).  
> **Relacionat:** [`plan-employee-portal.md`](./plan-employee-portal.md) §EP8 · [`plan-monthly-close-approval.md`](./plan-monthly-close-approval.md) §A6 · doc [`18-employee-portal-architecture.md`](../../product-design/18-employee-portal-architecture.md)

**Estat checklist:** pendent execució manual en local/staging (marca `[x]` quan passi).

### Quin portal en cada secció?

| Secció | On | Rol |
|--------|-----|-----|
| **1–2, 3.1–3.2, 5–6** | **public-portal** (`localhost:3002`) | Empleat sense compte (token `/e/…`) |
| **3.3–3.4, 4, 7** | **tenant-portal** | Gestor o empleat amb compte (validació creuada) |

La secció **2** comprova la **UI** de lectura del registre al public-portal; les dades venen de `GET /portal/api/monthly-report?year=&month=` (proxy Next → Edge `employee-portal`). Opcional: DevTools → Network → comprovar JSON 200 amb `summary`, `calendar_days`, `validation`.

---

## Prerequisits

| # | Requisit |
|---|----------|
| P1 | Supabase local en marxa (`supabase start`) + migracions aplicades (incl. `20260829000001_employee_portal_monthly.sql`, seed tokens `20260823000002`). |
| P2 | Edge Functions: `supabase functions serve` (employee-portal API). |
| P3 | **public-portal** dev: `npm run dev` al directori `apps/public-portal` (port **3002** per defecte). |
| P4 | **tenant-portal** dev (gestor) per validar estat després de confirmar. |
| P5 | Token dev Acme: secret `ep0-dev-acme-montserrat` → empleat seed **Montserrat Puig Ferrer** (`40000000-0000-0000-0000-000000000005`). |
| P6 | Per **confirmar** (§3): navegar al **mes anterior** (el mes en curs està bloquejat per `PERIOD_NOT_ENDED` fins al dia 1 del mes següent). |
| P7 | Seed d’horaris i fitxatges: cal `supabase/seeds/attendance_demo.sql` (veure `config.toml` → `[db.seed].sql_paths`). Després de `supabase db reset` s’aplica sol. Aplica també el **patró calendari laboral** (`seed_acme_labor_calendar_weekly_base`: dl–dv laboral per grup, ds–dg festiu). |
| P8 | Verificació ràpida SQL (opcional): `SELECT count(*) FROM data.employee_schedule_assignments WHERE tenant_id = '10000000-0000-0000-0000-000000000001';` → ha de ser > 0. Si és 0: `SELECT data.seed_acme_attendance_punches();` després d’executar `attendance_demo.sql`. |

**URLs locals (ajustar si el port difereix):**

- Portal bootstrap: `http://localhost:3002/e/ep0-dev-acme-montserrat`
- Health API: `http://localhost:3002/portal/api/health`
- Registre mensual: `http://localhost:3002/portal/monthly`

### Persones de prova (seed Acme)

Definides a [`supabase/seeds/attendance_demo.sql`](../../../supabase/seeds/attendance_demo.sql) + fitxatges a [`20260803000001_seed_acme_attendance_punches_fn.sql`](../../../supabase/migrations/20260803000001_seed_acme_attendance_punches_fn.sql).

| Empleat | ID | Horari seed | Grup calendari | Cas especial (fitxatges) | Token portal |
|--------|-----|-------------|----------------|---------------------------|--------------|
| **Montserrat Puig Ferrer** | `…005` | Taller matí 40h (Gràcia) | Taller Gràcia | Pausa oberta **ahir** | `ep0-dev-acme-montserrat` |
| Laia Torres Serra | `…008` | Oficina 37h (partida) | Oficina | Administratiu | `ep0-dev-acme-laia` |
| Marta Rovira Figueras | `…012` | Cap d’obra 40h | Taller Gràcia | Jornada continuada | `ep0-dev-acme-marta` |
| Albert Font Serra | `…021` | Taller matí | Taller Gràcia | `mobile_peripatetic` | — |

**Smoke §2–3 recomanat amb Montserrat + mes anterior.** Per provar bloqueigs, usar mes actual (§2.4) o empleats `006`/`007`.

**Millora seed pendent (no bloqueja smoke):** tokens addicionals per perfils `fixed_site` / `mobile_peripatetic`, `work_profile` explícit i escenaris de temps efectiu — track G / offboarding.

---

## 1. Sessió i navegació

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| 1.1 | `GET /portal/api/health` | `{ "status": "ok" }` (o equivalent) | [x] |
| 1.2 | Obrir `/e/ep0-dev-acme-montserrat` | Redirect a `/portal/punch` (o pantalla PIN si configurat); **cap secret** visible a la barra d’adreces després del redirect | [x] |
| 1.3 | Menú portal → **Registre** (`/portal/monthly`) | Carrega resum del mes (tabs Mes/Setmana si `iso_week`) sense error 401 | [x] |
| 1.4 | Navegar mes anterior/posterior | Fletxes ‹ › canvien el mes (l'any s'actualitza en creuar gener/desembre); query `?year=&month=` coherent | [x] |

---

## 2. Lectura del registre — **public-portal** (`/portal/monthly`)

> Dades via `GET /portal/api/monthly-report?year=YYYY&month=M` (sessió cookie després de `/e/{secret}`).

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| 2.1 | A **public-portal**: capçalera / sidebar | Nom empleat (Montserrat), navegació **per mes** (‹ ›; sense selector d'any independent), badge estat (`draft`, `employee_confirmed`, …) | [ ] |
| 2.2 | Resum numèric | Hores treballades / previstes / diferència coherents amb el detall per dia; columnes efectiu només si tenant té `attendance_effective_time_enabled` | [ ] |
| 2.3 | Detall per dia | Dies laborables amb entrades/sortides o tipus dia; disclaimer L1 (confirmació ≠ signatura electrònica) | [ ] |
| 2.4 | **Mes actual** (sense confirmar) | Secció «Confirmació del registre»: botó deshabilitat + motiu `PERIOD_NOT_ENDED` («el període encara no ha acabat») o `OPEN_TIME_ENTRY` (p. ex. jornada oberta ahir per Montserrat). **Últim dia del mes:** encara bloquejat fins al dia 1 del mes següent | [ ] |
| 2.5 | **Mes anterior** | Totals i dies coherents amb tenant-portal (mateix empleat, mateix mes) — comparació visual opcional | [ ] |

---

## 3. Confirmació L1 — **public-portal** + validació **tenant-portal**

| # | Pas | On | Resultat esperat | OK |
|---|-----|-----|------------------|-----|
| 3.1 | Mes **anterior** confirmable: obrir diàleg | public-portal | Checkbox «he revisat» abans d’acceptar | [ ] |
| 3.2 | Confirmar | public-portal | Èxit UI; estat «Confirmat» | [ ] |
| 3.3 | Fitxa empleat → registre mensual mateix mes | tenant-portal | `confirmed_at` visible; badge actualitzat | [ ] |
| 3.4 | Activitat empleat (opcional) | tenant-portal | `ATTENDANCE_PERIOD_EMPLOYEE_CONFIRMED` (rang dates) o sync `ATTENDANCE_MONTH_EMPLOYEE_CONFIRMED` | [ ] |
| 3.5 | `access_logs` (opcional SQL) | Supabase | Acció `period_confirm` o `monthly_confirm` amb `metadata.period_from`/`period_to` | [ ] |
| 3.6 | Reintent confirmar el mateix mes | public-portal | No error destructiu; botó deshabilitat «ja confirmat» | [ ] |

---

## 4. Gestor — enllaç WhatsApp (tenant-portal)

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| 4.1 | Com a gestor: registre mensual de l’empleat → **Enviar enllaç confirmació** | Obre WhatsApp amb text que menciona el mes (o copia missatge si no hi ha telèfon) | [ ] |
| 4.2 | Empleat sense telèfon a fitxa | Toast «copiat al porta-retalls» / avís afegir telèfon | [ ] |

*Nota:* el missatge WhatsApp **no inclou** l’URL del token per seguretat; l’empleat ha d’usar el seu enllaç personal ja conegut o el que el gestor li hagi enviat per un altre canal.

---

## 5. Signatura L2 (només si tenant exigeix signatura digital)

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| 5.1 | Tenant amb `attendance_monthly_require_digital_signature = true` | Portal mostra opció **Signar document** (flux DMS), **no** substitueix L1 | [ ] |
| 5.2 | Clic signar | Redirigeix al flux de signatura existent (DocuSeal / natiu), no un «clic = signat» | [ ] |

---

## 6. Seguretat i sessió

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| 6.1 | Revocar token des de tenant-portal (tab Accés Portal) amb sessió activa | Propera acció API → `/portal/expired` o equivalent | [ ] |
| 6.2 | Sessió caducada (esperar TTL o simular) | No es pot confirmar sense tornar a passar per `/e/{secret}` | [ ] |

---

## 7. Comparació amb app (A6 tenant-portal)

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| 7.1 | Empleat **amb compte**: `/attendance/record` vista Mes → confirmar | Mateix RPC/backend que portal; mateix estat `employee_confirmed` | [ ] |

---

## 8. Mode setmanal ISO (`attendance_employee_confirm_cycle = iso_week`)

> Prerequisit: tenant amb cicle setmanal a `/settings/attendance-control` → tancament mensual.

| # | Pas | On | Resultat esperat | OK |
|---|-----|-----|------------------|-----|
| 8.1 | Portal Registre | public-portal | Tabs **Mes** / **Setmana** visibles; vista Mes sense botó confirmar mes sencer | [ ] |
| 8.2 | Navegar setmanes ‹ › | public-portal | 7 dies de la setmana ISO; query `period_from`/`period_to` al network | [ ] |
| 8.3 | Setmana anterior confirmable | public-portal | Botó confirmar setmana + validació `period_validation` al JSON | [ ] |
| 8.4 | Confirmar 1 setmana | public-portal | `period_confirm` a access logs; indicador «X/Y setmanes» al mes | [ ] |
| 8.5 | Panell gestor | tenant-portal | `PeriodConfirmStatusPanel`: setmanes confirmades/pendents; tancament bloquejat si falta cobertura | [ ] |
| 8.6 | Tenant empleat (app) | tenant-portal | `PeriodWeeklyConfirmSection` a `/attendance/record` — mateixa API que portal | [ ] |

---

## Registre d’execució

| Data | Entorn | Executor | Resultat | Notes |
|------|--------|----------|----------|-------|
| | local / staging | | PASS / FAIL | |

---

## Si falla

| Símptoma | On mirar |
|----------|----------|
| 401 / `missing_session` | Cookie proxy Next.js; `POST /portal/api/session`; Edge `employee-portal` |
| 404 monthly-report | Esborrany mensual inexistent; RPC `upsert_attendance_monthly_report_draft` |
| Confirmació bloquejada | `validate_attendance_period_employee_confirm` → `PERIOD_NOT_ENDED`, `OPEN_TIME_ENTRY`, `NEEDS_REVIEW`, `MISSING_WORKDAY_RECORD` |
| Setmana ISO desalineada UI/SQL | Comparar dates `period_from`/`period_to` amb `data.list_calendar_month_iso_weeks` |
| Token invàlid | `employee_portal_tokens.token_hash` vs secret; seed `ep0-dev-acme-montserrat` |
| **Hores previstes = 0 / cap dia laborable** | `attendance_demo.sql` no aplicat o falta `seed_acme_labor_calendar_weekly_base()` → sense overrides de calendari laboral (només festius assignats). Solució: `supabase db reset`. |
| Calendari només festius / vacances, sense dies laborals | El calendari visual usa **overrides** (`labor_calendar_overrides`), no `work_schedules` sol. El seed ara omple dl–dv + cap de setmana. |
| Graella buida | Mateix que anterior; o mes sense fitxatges (navegar al mes anterior) |

**Fitxers clau:** `monthly-report-service.ts`, `PortalMonthlyPage.tsx`, `apps/public-portal/app/portal/api/[...path]/route.ts`, `MonthlyAttendanceReportPanel.tsx` (gestor).
