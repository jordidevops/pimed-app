# MVP-ELM — Smoke checklist (Employees / HR Core)

> **Pla mestre:** [`EXECUTION.md`](./EXECUTION.md)  
> **Abast:** EHR-0 + ES-0..2 + CR-0..3 + CR-6  
> **Runbook:** [`DEV_RUNBOOK.md`](../../../DEV_RUNBOOK.md)  
> **UAT ampliat (post-EXECUTION):** [`ehr-uat-checklist.md`](./ehr-uat-checklist.md) + fixtures [`supabase/seeds/README_smoke_ehr.md`](../../../supabase/seeds/README_smoke_ehr.md)

**Estat (2026-07-20):** SQL ✅ · Owner UI ✅ · Charlie tech-only ✅ · Dave sense compliance ✅

### Incidència trobada i corregida durant smoke

| # | Problema | Fix |
|---|----------|-----|
| S1 | `session.user.app_metadata` sense `user_permissions` → `usePermission` sempre `false` | Fallback a rol de `TenantContext` |
| S2 | `data.get_role_permissions` SQL sense `employees.*` / `compliance.*` | `20261067000001` |
| S3 | Certificacions UI forçava context global (`null`) → site managers fora | `usePermission` sense `null` forçat |
| S4 | RLS certs només `global_role` → Charlie site-manager veia 0 files | `20261068000001` (site manager tech; medical només owner/site-owner) |

---

## Prerequisits

| # | Requisit |
|---|----------|
| P1 | Supabase local + migracions fins `20261066000001` |
| P2 | Seed Acme (`10000000-…0001`) |
| P3 | tenant-portal (`npm run dev`, port **5173**) |
| P4 | Logins seed — password `Test1234!` |

| Rol | Email | Expectativa compliance |
|-----|-------|------------------------|
| Owner | `alice@acme-corp.com` | Tech + medical |
| Manager | `charlie@acme-corp.com` | Només tech (sense medical) |
| Member | `dave@acme-corp.com` | Sense tabs compliance |

**Empleats seed útils:** Alice `40000000-…0001`, Charlie `40000000-…0002`.

**Tests SQL (abans del smoke UI):**

```powershell
cd C:\JordiDevops\pimed-app\supabase\tests
.\run_compliance_rls_cr6_tests.ps1
# opcional: runners ES/CR previs si hi ha regressió
```

---

## 1. SQL / RLS (automatitzat)

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| 1.1 | `run_compliance_rls_cr6_tests.ps1` | `10 PASS, 0 FAIL` | [x] |
| 1.2 | (opcional) suites ES-0 / CR-1 / CR-2 / ES-1 / CR-3 | Tots PASS | [ ] |

---

## 2. Owner (Alice) — catàleg i detall

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| 2.1 | Login Alice → `/employees` | Llista empleats visible | [x] *(sessió owner Acme; 51 empleats)* |
| 2.2 | Tab **Compliment** (`?tab=compliance`) | Tipus + regles; pot crear tipus/regla | [x] *(PRL_BASIC, MEDICAL_FIT, HEIGHT_WORK)* |
| 2.3 | Obrir Alice (`/employees/40000000-…0001`) | Capçalera amb **Readiness badge** | [x] *Readiness no configurat / Actiu* |
| 2.4 | Secció **Lifecycle** (tab Info) | Estat + accions de transició visibles | [x] *Cicle de vida + on_leave/departure* |
| 2.5 | Tab **Certificacions** | Veu tech **i** medical (si n’hi ha dades) | [x] *tab + Afegir; llista buida seed* |
| 2.6 | Transició lifecycle segura (ex. active → departure si aplicable) | Estat actualitzat; sense error RPC | [ ] *no executat (evitar canviar seed)* |

---

## 3. Manager (Charlie) — aïllament medical

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| 3.1 | Logout → login Charlie → mateix empleat | Accés a Empleats | [x] *site manager Gràcia; 29 empleats* |
| 3.2 | Tab Certificacions | Només files **tech**; **0** medical | [x] *HEIGHT_WORK sí; MEDICAL_FIT no* |
| 3.3 | Tab Compliment (llista) | Visible si té `compliance.requirements.manage` / certs | [x] *absència OK (permís global; Charlie site-only)* |

---

## 4. Member (Dave) — sense compliance

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| 4.1 | Login Dave → `/employees` | Segons permisos base (view o denegat) | [x] *llista 29; sense Import/Nou* |
| 4.2 | Sense tab Compliment / sense certificacions mèdiques | No veu dades medical | [x] *sense Compliment; «No tens permís» a certs* |

---

## 5. Gate dispatch (ES-1) — smoke ràpid

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| 5.1 | Flag `employee_readiness_gate_enabled` = **off** (defecte) | `start_work_log` no bloqueja per readiness | [ ] |
| 5.2 | (Opcional) activar flag + empleat no ready | RPC retorna error de guarda | [ ] |

> 5.1/5.2 es poden validar per SQL/RPC; no cal UI de fitxatge si no és accessible.

---

## 6. Critèris de tancament smoke

- [x] 2.x Owner UI OK (sense 2.6 mutació)
- [x] 3.x Charlie sense medical
- [x] 4.x Dave sense compliance
- [x] Cap error de consola bloquejant a `/employees` ni detall *(post-fix S1–S4)*
- [x] Actualitzar `EXECUTION.md` §18 + log

**Fora d’abast MVP-ELM:** Directory EHR-1..3, contractes, actius, CR-2b/c, portal `get_own_certifications` UI (RPC cobert per CR-6 SQL).
**Opcional diferit:** §5 gate ES-1; §2.6 transició lifecycle real.
