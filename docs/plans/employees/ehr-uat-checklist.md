# EHR / Empleats — Checklist UAT + UX (post-EXECUTION)

> **Durable al repo** — es pot passar **per blocs**, no tot de cop.  
> **Pla mestre:** [`EXECUTION.md`](./EXECUTION.md)  
> **Smoke MVP-ELM (tancat):** [`ehr-smoke-checklist.md`](./ehr-smoke-checklist.md)  
> **Fixtures:** [`supabase/seeds/smoke_ehr_employees_fixtures.sql`](../../../supabase/seeds/smoke_ehr_employees_fixtures.sql) · [README](../../../supabase/seeds/README_smoke_ehr.md)

**Estat global:** ⬜ Pendent · 🔄 En curs · ✅ Tancat  

| Bloc | Estat | Data | Notes |
|------|-------|------|-------|
| S0 Fixtures | ⬜ | | |
| Smoke S1–S10 | ⬜ | | |
| UAT-DIR | ⬜ | | |
| UAT-ELM | ⬜ | | |
| UAT-EC | ⬜ | | |
| UAT-CR | ⬜ | | |
| UAT-EA | ⬜ | | |
| UAT-IMP | ⬜ | | |
| UAT-RPT | ⬜ | | |
| UAT-MT | ⬜ | | |
| Mapa UX | ⬜ | | |

---

## Prerequisits

| # | Requisit | OK |
|---|----------|----|
| P1 | Supabase local + migracions aplicades | [ x ] |
| P2 | Seed Acme/Beta (`seed.sql`) | [ x ] |
| P3 | tenant-portal (`npm run dev`, tipicament 5173 o 4173) | [ x ] |
| P4 | Executar fixtures (S0) | [ x ] |
| P5 | Logins: `alice@` / `charlie@` / `dave@acme-corp.com` — pwd `Test1234!` | [ x ] |

**IDs fixture:**

| Qui | UUID / codi |
|-----|-------------|
| QA Smoke Employee | `e1000000-…0001` · `QA-SMOKE-001` · email `qa-smoke@acme-corp.example` |
| QA Offboard Employee | `e1000000-…0002` · `QA-OFF-001` |
| QA Beta Employee | `e1000000-…0003` · `QA-BETA-001` |
| Alice seed | `40000000-…0001` (certs tech + medical) |
| Contract draft QA | `e1000000-…0011` · `QA-SMOKE-DRAFT-001` |

### S0 — Executar fixtures

1. Supabase Studio → **SQL Editor** (o `psql`).
2. Enganxar [`smoke_ehr_employees_fixtures.sql`](../../../supabase/seeds/smoke_ehr_employees_fixtures.sql) → Run.
3. Verificar taula final: `alice_certs=2`, `qa_smoke_employee=1`, `qa_draft_contract=1`, `offboard_checklist_open=1`, `acme_rules=2`.

| Pas | Esperat | OK | Notes |
|-----|---------|----|-------|
| S0 | Counts correctes | [ x ] | |

Cleanup (opcional): [`smoke_ehr_employees_fixtures_cleanup.sql`](../../../supabase/seeds/smoke_ehr_employees_fixtures_cleanup.sql).

---

## 1. Mapa de revisió UX (3 punts / pantalla)

Marca cada punt quan l’hagis revisat. Anota friccions a **Notes UX** al final.

### 1.1 Llista `/employees`
- [ x ] Càrrega / buit intel·ligible
- [ x ] CTA “Nou empleat” vs “Importar CSV” clars
- [ ] Feedback error permisos/xarxa accionable

### 1.2 Detall capçalera + badge `/employees/:id`
- [ ] Readiness badge llegible (ready/blocked + motiu)
- [ ] Jerarquia visual nom > lifecycle > badge > tabs
- [ ] 404 vs sense permís diferenciats

### 1.3 Lifecycle (Info)
- [ ] Transició + `effective_on` comprensible
- [ ] Confirmació destructiva (departure/offboarding)
- [ ] Historial sense reload; error en llenguatge humà

### 1.4 Tab Contractes
- [ ] Estats draft/sign/active/ended/blocked visibles
- [ ] Flux Crear → Doc → Firma → Activar amb CTA únic
- [ ] Gate signatura explica què cal fer

### 1.5 Tab Certificacions
- [ ] Tech vs medical etiquetat
- [ ] Caducitat / Afegir / Revocar clars
- [ ] Firma mèdica (CR-5) estat comprensible

### 1.6 Tab Equipament
- [ ] Assignar / retornar amb confirmació
- [ ] Documents reconeixement/retorn
- [ ] Alertes calibratge no bloquejen tota la UI

### 1.7 Tab Personal
- [ ] Copy de privacitat
- [ ] Desar / cancel·lar / validació camp a camp
- [ ] Self vs HR (disabled + tooltip)

### 1.8 Skills + catàleg
- [ ] Assignar nivell clar
- [ ] Cerca per skill (buit vs error)
- [ ] Nomenclatura consistent

### 1.9 Compliment `/employees?tab=compliance`
- [ ] Tipus vs regles distintes
- [ ] Impacte readiness abans de desar
- [ ] Dashboard incrustat no competeix amb CRUD

### 1.10 Tipus d’actius `/employees?tab=assets`
- [ ] CRUD clar
- [ ] Regla MISSING_ASSET explicada
- [ ] Buit / error RLS

### 1.11 Import CSV
- [ ] Plantilla → preview → resultat
- [ ] Errors de fila accionables
- [ ] Avis d’updates immediats

### 1.12 HR KPIs `/employees/hr`
- [ ] Loading per widget (no zeros engañosos)
- [ ] Cards accionables / deep-link
- [ ] Alertes contracte amb text

### 1.13 Organigrama `/employees/organization`
- [ ] Navegació arrels / subtree
- [ ] Click a node → detall
- [ ] Buit / cicles

### 1.14 Posicions `/employees/positions`
- [ ] CRUD + confirm delete
- [ ] Etiqueta consistent amb detall
- [ ] Permisos (member sense edició)

### 1.15 Offboarding checklist
- [ ] Visible només quan toca
- [ ] Waive amb confirmació
- [ ] Progrés pendents/fets

### 1.16 Work context (contractes / WFM)
- [ ] Context efectiu llegible
- [ ] Inspector bloqueig amb raó
- [ ] “Sense context” ≠ error genèric

---

## 2. Smoke (S1–S10) — ~30–40 min

| ID | Passos | Esperat | OK | Notes |
|----|--------|---------|----|-------|
| S1 | Alice → `/employees` | Llista; cerca `QA Smoke` el troba | [ ] | |
| S2 | Obrir Alice seed → tabs Info/Contracts/Certs/Equipment/Personal/Skills | Tabs OK; Certs tech+medical | [ ] | |
| S3 | `?tab=compliance` | Tipus/regles + summary; regles fixture | [ ] | |
| S4 | `?tab=assets` | Tipus d’actius | [ ] | |
| S5 | `/employees/hr` | KPIs sense error | [ ] | |
| S6 | `/organization` + `/positions` + `/skills` | Obren | [ ] | |
| S7 | Charlie → Alice → Certificacions | Només tech; **0 medical** | [ ] | |
| S8 | Dave → Empleats | Sense gestió compliance | [ ] | |
| S9 | Alice: crear empleat mínim → llista | Apareix | [ ] | |
| S10 | QA Smoke → Lifecycle + badge | Transició UI; blocked llegible | [ ] | |

---

## 3. UAT per blocs (fer a trossos)

### UAT-DIR Directory
| # | Passos | Esperat | OK | Notes |
|---|--------|---------|----|-------|
| D1 | Crear → editar posició/tags/manager → organigrama | Reflecteix manager | [ ] | |
| D2 | Tab Personal: editar adreça/document → refresh | Persisteix | [ ] | |
| D3 | Charlie: certs medical Alice | **No les veu** | [ ] | |

### UAT-ELM Lifecycle
| # | Passos | Esperat | OK | Notes |
|---|--------|---------|----|-------|
| L1 | QA Smoke onboarding → active (avui) | Estat + historial | [ ] | |
| L2 | Transició futura `effective_on` demà | No canvia estat actual encara | [ ] | |
| L3 | Transició invàlida (si UI ho permet) | Error comprensible | [ ] | |

### UAT-EC Contractes
| # | Passos | Esperat | OK | Notes |
|---|--------|---------|----|-------|
| C1 | Obrir draft `QA-SMOKE-DRAFT-001` | Pending sign visible | [ ] | |
| C2 | Intentar activar sense signar | Bloqueig + missatge | [ ] | |
| C3 | Contracte `signature_requirement=none` → activar (o completar firma) | `active` / ELM si aplica | [ ] | |
| C4 | Renovació / renew | Nou draft coherent | [ ] | |
| C5 | Beta no veu contracte Acme; veu `QA-BETA` | Aïllament | [ ] | |

### UAT-CR Compliance / readiness
| # | Passos | Esperat | OK | Notes |
|---|--------|---------|----|-------|
| R1 | QA Smoke badge | **Blocked** + raó | [ ] | |
| R2 | Afegir cert que compleixi regla → refresh | Menys bloquejos / ready | [ ] | |
| R3 | Dashboard blocked list | Inclou QA Smoke | [ ] | |
| R4 | Charlie no crea/veu medical | OK | [ ] | |

### UAT-EA Actius
| # | Passos | Esperat | OK | Notes |
|---|--------|---------|----|-------|
| A1 | QA Smoke: assignació fixture → retornar | OK | [ ] | |
| A2 | Readiness / MISSING_ASSET si aplica | Reflecteix | [ ] | |
| A3 | QA Offboard: checklist → waive ítem | Visible + waive | [ ] | |

### UAT-IMP Import
| # | Passos | Esperat | OK | Notes |
|---|--------|---------|----|-------|
| I1 | [`smoke_ehr_import_sample.csv`](../../../supabase/seeds/smoke_ehr_import_sample.csv) → preview → import | Create + update | [ ] | |
| I2 | CSV invàlid | Error de fila, diàleg viu | [ ] | |

### UAT-RPT Reporting
| # | Passos | Esperat | OK | Notes |
|---|--------|---------|----|-------|
| P1 | `/employees/hr` filtrar site + deep-link | Nombres / navegació OK | [ ] | |
| P2 | Dave reporting (si aplica) | Forbidden o buit | [ ] | |

### UAT-MT Multi-tenant
| # | Passos | Esperat | OK | Notes |
|---|--------|---------|----|-------|
| M1 | Anotar IDs Acme QA | — | [ ] | |
| M2 | Beta: cerca email/codi Acme | **0 resultats** | [ ] | |
| M3 | Beta: `/employees/{id_acme_qa}` | 404/forbidden; sense dades Acme | [ ] | |
| M4 | Beta: `QA Beta Employee` visible | Només a Beta | [ ] | |

> Login Beta: Alice multi-tenant (`alice@acme-corp.com` canvia a **Beta Startup**) o `frank@beta-startup.com`.

---

## Notes UX / KO (omplir mentre proves)

| Data | Pantalla | Severitat (P0/P1/P2) | Descripció | Captura / URL |
|------|----------|----------------------|------------|---------------|
| | | | | |

---

## Playwright (automatitzat — agent)

Specs a `apps/tenant-portal/tests/employees/`:

- `employees-smoke.spec.ts`
- `employees-rbac.spec.ts`
- `employees-multitenant.spec.ts`
- `employees-directory.spec.ts` / lifecycle / contracts (progressiu)

Requisit: fixtures aplicats + auth setup Playwright (`playwright/.auth/*`).
