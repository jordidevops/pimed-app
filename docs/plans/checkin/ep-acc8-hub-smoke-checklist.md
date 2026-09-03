# EP-ACC-8 / EP-ACC-9 — Smoke checklist: hub «Accés al portal» + Identity Gate

> **Àmbit:** tenant-portal (`/employees?tab=portal_hub`) + public-portal (`/e/{secret}`)  
> **Pla:** [`plan-employees-portal-access-tab.md`](./plan-employees-portal-access-tab.md) §8 · §13  
> **Relacionat:** [`plan-employee-portal-access-v2.md`](./plan-employee-portal-access-v2.md) · [`plan-employee-portal-token-batch.md`](./plan-employee-portal-token-batch.md)

**Estat checklist (2026-07-13):** SQL automatitzat ✅ · revisió codi ✅ · E2E manual parcial (marca `[x]` quan passi al navegador).

### Quin portal en cada secció?

| Secció | On | Rol |
|--------|-----|-----|
| **1–4** | **tenant-portal** | Manager (`attendance.manage`) |
| **5–6** | **public-portal** | Empleat sense compte (token `/e/…`) |

---

## Prerequisits

| # | Requisit |
|---|----------|
| P1 | Supabase local (`supabase start`) + migracions aplicades (incl. `20260930100001` overview, `20260930100003` pin status, `20260929100001` identity gate). |
| P2 | Edge Functions: `supabase functions serve --env-file supabase/functions/.env.local` |
| P3 | **tenant-portal** dev (port habitual Vite). |
| P4 | **public-portal** dev (`apps/public-portal`, port **3002**). |
| P5 | Usuari manager amb `attendance.manage` al tenant de prova. |
| P6 | Almenys un empleat amb `document_id` (DNI/NIE) per provar identitat + batch. |

**Tests SQL (automatitzats — executar abans del smoke manual):**

```powershell
.\supabase\tests\run_employee_portal_access_overview_tests.ps1   # H-T1…H-T9
.\supabase\tests\run_employee_portal_token_batch_tests.ps1     # B-T1…B-T13
.\supabase\tests\run_employee_portal_identity_gate_tests.ps1   # I-T1…I-T8
```

| Suite | Resultat 2026-07-13 |
|-------|---------------------|
| H-T (hub overview) | ✅ 10/10 |
| B-T (batch backend) | ✅ 15/15 |
| I-T (identity gate) | ✅ 32/32 |

---

## 1. Separació HR vs hub (EP-ACC-8b)

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| 1.1 | Obrir `/employees` (sense `?tab=`) | Pestanya **Empleats** activa; només llista HR + «Nou empleat» | [x] codi |
| 1.2 | Comprovar header llista HR | **Sense** «Generar enllaços», **sense** «Lots recents», **sense** banner batch | [x] codi |
| 1.3 | Comprovar files HR | **Sense** checkboxes de selecció batch | [x] codi |
| 1.4 | Clic pestanya **Accés al portal** | URL `?tab=portal_hub`; carrega taula overview | [x] codi |

---

## 2. Taula hub i filtres (EP-ACC-8c)

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| 2.1 | KPI sota el títol | Comptadors actius / sense enllaç / mai oberts / sense DNI | [x] codi |
| 2.2 | Clic KPI «sense enllaç» | Aplica filtre `no_personal_link` | [x] codi |
| 2.3 | Filtre **Mai obert** | Només empleats amb token actiu i `first_accessed_at IS NULL` (H-T2) | [x] SQL |
| 2.4 | Filtre **PIN pendent** | Només tokens amb `pin_required` i sense `pin_hash` (H-T9) | [x] SQL |
| 2.5 | Columna PIN — empleat amb PIN configurat | Mostra **Configurat** (no «No requerit» després del setup) | [x] codi + migració `20260930100003` |
| 2.6 | Ordenació últim accés / data creació | Canvia ordre server-side (`p_sort`, `p_sort_dir`) | [x] codi |
| 2.7 | Paginació | `limit`/`offset` + total coherent (H-T4) | [x] SQL |
| 2.8 | Enllaç nom empleat | Obre `/employees/:id?tab=portal_access` | [x] codi |
| 2.9 | Manager només site A | No veu empleats site B (H-T3, H-T7) | [x] SQL |

---

## 3. Bulk i importacions al hub (EP-ACC-8d)

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| 3.1 | Seleccionar 2–3 empleats (amb DNI) → **Generar accés** | Obre `PortalTokenBatchDialog`; genera lot | [ ] manual |
| 3.2 | Resultats: CSV / copiar línies / QR | Export funcional; «Copiar» amb format `Nom · DNI · URL` | [x] codi |
| 3.3 | Tancar modal resultats | Banner «Recuperar lot» visible **només** a pestanya portal | [x] codi |
| 3.4 | **Importacions recents** | Obre lots dins la finestra 1h (no al header HR) | [x] codi |
| 3.5 | Empleat sense DNI al bulk | Fila `skipped` / `employee_missing_document_id` (B-T13, I-T8) | [x] SQL |
| 3.6 | 6è lot en 1h | `batch_rate_limited` (B-T11) | [x] SQL |
| 3.7 | Checkbox desactivada sense DNI | No seleccionable per bulk al hub | [x] codi |

---

## 4. Fitxa empleat (no regressió)

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| 4.1 | `/employees/:id?tab=portal_access` | Pestanya «Accés Portal» amb detall tokens, logs, correu, PIN | [x] codi |
| 4.2 | Crear enllaç 1-a-1 sense DNI | Error `employee_missing_document_id` (I-T8a) | [x] SQL |

---

## 5. Identity Gate — primer accés (EP-ACC-9)

> Empleat amb `document_id` a RRHH i token personal nou (sense `identity_verified_at`).

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| 5.1 | Obrir `/e/{secret}` token nou personal | Pantalla **Identifica't** (DNI); sense nom ni dades | [x] codi |
| 5.2 | DNI incorrecte | Missatge genèric; sense sessió (I-T2) | [x] SQL |
| 5.3 | DNI correcte | Pantalla confirmació «Ets {nom}?» | [x] codi + I-T1 |
| 5.4 | «No sóc aquesta persona» | Sortida segura; log `identity_rejected` (I-T3) | [x] SQL |
| 5.5 | «Confirmo» + `pin_must_set` | Continua a `PinSetupGate` (I-T1) | [x] SQL |
| 5.6 | Segon accés mateix token | Salta DNI; va directe a PIN o sessió (I-T4) | [x] SQL |
| 5.7 | Empleat sense `document_id` a BD | `identity_not_configured`; sense dades (I-T6) | [x] SQL |
| 5.8 | Token `shared_device` (taulell) | Exempt Identity Gate (I-T5) | [x] SQL |
| 5.9 | `POST /session` o `/pin/setup` sense identitat | `403 identity_required` (I-T1b) | [x] SQL |

---

## 6. Signatura final

| Àrea | Estat |
|------|-------|
| RPC overview + permisos site | ✅ H-T1…H-T9 |
| Batch backend intacte | ✅ B-T1…B-T13 |
| Identity Gate SQL + Edge | ✅ I-T1…I-T8 |
| UI hub reubicada | ✅ revisió codi |
| E2E manual bulk + navegació | ⏳ §3.1 (opcional abans prod) |

**Validat per:** agent + suites SQL locals (2026-07-13).  
**Pendent abans producció:** smoke manual §3.1 (generar lot des del hub) i verificació visual PIN «Configurat» amb empleat real (Albert Font Serra o equivalent).
