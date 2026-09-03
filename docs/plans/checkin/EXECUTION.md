# Pla mestre d'execució — Control horari, estacions i torns

> **Rol:** única font de veritat de l'ordre d'implementació i del treball pendent  
> **Creat:** 2026-07-15  
> **Fase activa:** *(cap — roadmap EX-00…EX-09 tancat)*  
> **Paquet actiu:** —  
> **Cua diferida:** EI3+ Holded/PayFit / forecast (`docs/plans/employee-import/plan.md`); **AP-06** check-in contextual (backlog — veure [`analisi-producte-control-horari.md`](./analisi-producte-control-horari.md) §AP-06)  
> **EX-02:** ✅ tancat (02.1–02.7)  
> **EX-03:** ✅ tancat (03.1–03.7) — font única d'horari + ST-19 schema + dual-run  
> **EX-04:** ✅ tancat (04.1–04.7) — publicació, portal, ST-18c/d, pauses estació  
> **EX-05:** ✅ tancat (05.1–05.6) — offline ST-9 V2 (batch, outbox, timestamps, skew, E2E, FF-04)  
> **EX-06:** ✅ tancat (06.1–06.5) — rols, demanda, buckets, capes, dashboard gaps  
> **EX-07:** ✅ tancat (07.1–07.6) — disponibilitat, vacants, eligibility, portal, swaps, push  
> **EX-08:** ✅ tancat (08.1–08.4) — regles, anomalies, heurístiques, import CSV; EI3+ en cua  
> **EX-08.1:** ✅ Motor de regles laborals (descans / jornada / dies consecutius)  
> **EX-08.2:** ✅ Automatitzacions d’anomalies (AP-08)  
> **EX-08.3:** ✅ Heurístiques fatiga/equitat (AP-09)  
> **EX-08.4:** ✅ Import CSV + mappings externs (AP-12 / EI0+EI2+EI1)  
> **EX-09:** ✅ tancat (09.1–09.3) — retenció ≥4 anys batched + enllaç inspecció ([`plan-attendance-legal-access.md`](./plan-attendance-legal-access.md))  
> **EX-07.1:** ✅ Disponibilitat recurrent i excepcions  
> **EX-07.2:** ✅ `shift_openings` + claims (sense placeholder employee)  
> **EX-07.3:** ✅ Eligibility + accept → `shift_slot` published  
> **EX-07.4:** ✅ Portal vacants (list/claim/withdraw)  
> **EX-07.5:** ✅ Swap / give-away / call-off end-to-end  
> **EX-07.6:** ✅ Notificacions push + escalat urgent  
> **EX-06.1:** ✅ Rols, assignacions i qualificacions mínimes  
> **EX-06.2:** ✅ Demanda recurrent/extraordinària i CRUD  
> **EX-06.3:** ✅ Cobertura per buckets de 15/30 min  
> **EX-06.4:** ✅ Capes planificat / confirmat / real / qualificat  
> **EX-06.5:** ✅ Dashboard operatiu i alertes de gap  
> **EX-04.1:** ✅ Lots/revisions `shift_publications` + `publication_id`  
> **EX-04.2:** ✅ CRUD `work_shifts`, multi-slot/dia i anomalies a la UI  
> **EX-04.3:** ✅ Preflight, diff i períodes tancats  
> **EX-04.4:** ✅ Calendari `shift_slot` + portal «Els meus torns»  
> **EX-04.5:** ✅ ST-18c ubicació planificada vs estació (warn/block)  
> **EX-04.6:** ✅ ST-18d punch sense assignació (allow/warn + anomaly)  
> **EX-04.7:** ✅ ST-16 pauses contextuals a l'estació  
> **EX-05.1:** ✅ Batch client + `client_op_id` UUID v7 estable  
> **EX-05.2:** ✅ Outbox kiosk IndexedDB (ST-9 V2 foundation)  
> **EX-05.3:** ✅ `occurred_at`/`received_at`, àncora temporal i monotònic  
> **EX-05.4:** ✅ `CLOCK_SKEW`, `OFFLINE_DELAY`, `max_age` i quarantena  
> **EX-05.5:** ✅ E2E mode avió, retry, duplicat, clock change i torn nocturn  
> **EX-05.6:** ✅ FF-04 feature flag + runbook  
> **EX-03.1:** ✅ ADR + tests de caracterització  
> **EX-03.2:** ✅ Opció B (`work_schedules` congelat) — superseded per EX-03.2-bis  
> **EX-03.2-bis:** ✅ Base recurrent setmanal grup+empleat, `work_schedules` eliminat ([ADR-0003](./adr-0003-weekly-recurring-base.md))  
> **EX-03.3:** ✅ `resolve_employee_work_plan` canònic + adaptador `resolve_work_day` + slots published  
> **EX-03.4:** ✅ ST-19 schema location/snapshots + herència + exposició al resolver  
> **EX-03.5:** ✅ Recompute idempotent en publish/cancel de slots  
> **EX-03.6:** ✅ Dashboard «programat avui» → resolver canònic (absències/slots)  
> **EX-03.7:** ✅ FF-03 dual-run (shadow) + backfill draft/unlocked  
> **Estat funcional actual:** [`STATUS.md`](./STATUS.md)

## 1. Per què existeix aquest document

Hi ha diversos plans funcionals, revisions i implementacions parcials. Cap d'ells, per separat, pot indicar:

- què s'ha de fer primer;
- quines dependències estan resoltes;
- què bloqueja producció;
- com es demostra que una fase està acabada;
- què queda després d'una sessió o canvi d'agent.

Aquest document no substitueix les especificacions. Les ordena, n'extreu paquets executables i conserva l'evidència d'execució.

## 2. Jerarquia documental

| Nivell | Document | Responsabilitat |
|---|---|---|
| 1 | Codi, migracions i tests | Comportament real desplegable |
| 2 | [`STATUS.md`](./STATUS.md) | Inventari del que existeix avui |
| 3 | **`EXECUTION.md`** | Ordre, fase activa, dependències, DoR/DoD i evidència |
| 4 | Plans funcionals | Especificació del comportament objectiu |
| 5 | Revisions i anàlisis | Evidència immutable i riscos detectats |
| 6 | Xat/canvas | Context auxiliar; mai font exclusiva |

Si hi ha contradicció:

1. verificar codi/migració/test efectiu;
2. corregir `STATUS.md`;
3. decidir l'acció a `EXECUTION.md`;
4. actualitzar el pla funcional afectat;
5. no reescriure retrospectivament la revisió original.

## 3. Documents persistits

### Especificacions

- [`plan-attendance-stations.md`](./plan-attendance-stations.md)
- [`estudi-station-punch-ux-v2.md`](./estudi-station-punch-ux-v2.md)
- [`plan-shift-planner-v2.md`](./plan-shift-planner-v2.md)
- [`adr-0001-work-plan-source-of-truth.md`](./adr-0001-work-plan-source-of-truth.md) — cascada congelada (EX-03.1 / SP-0)
- [`adr-0002-work-schedules-option-b.md`](./adr-0002-work-schedules-option-b.md) — congelar plantilles setmanals (EX-03.2, superseded)
- [`adr-0003-weekly-recurring-base.md`](./adr-0003-weekly-recurring-base.md) — base recurrent setmanal grup+empleat, elimina `work_schedules` (EX-03.2-bis)
- [`plan-effective-work-time.md`](./plan-effective-work-time.md)
- [`plan-monthly-close-approval.md`](./plan-monthly-close-approval.md)
- [`plan-employee-portal.md`](./plan-employee-portal.md)

### Revisions i anàlisis — snapshots 2026-07-15

- [`revisio-critica-estacions-fitxatge.md`](./revisio-critica-estacions-fitxatge.md)
- [`revisio-exhaustiva-estacions-vs-codi.md`](./revisio-exhaustiva-estacions-vs-codi.md)
- [`analisi-producte-control-horari.md`](./analisi-producte-control-horari.md)

### Smoke / QA manual

- [`ex-smoke-checklist.md`](./ex-smoke-checklist.md) — guia sistemàtica frontend EX-02…EX-05 (fitxatges, horaris, calendaris, estacions)
- Fixtures SQL: [`supabase/seeds/smoke_ex_attendance_fixtures.sql`](../../../supabase/seeds/smoke_ex_attendance_fixtures.sql) (Editor SQL, no migració)

## 4. Convenció d'estats

| Estat | Significat |
|---|---|
| ✅ | Implementat i verificat amb evidència |
| 🟡 | Paquet actiu |
| ⬜ | Pendent, preparat quan es compleixin dependències |
| ⛔ | Bloquejat per una dependència o decisió |
| 🧊 | Diferit deliberadament |
| ❌ | Rebutjat / no es farà |

«Codi escrit» no és ✅. Cal complir la Definition of Done del paquet.

## 5. Regles d'execució

1. Només hi ha **una fase de release activa**. Dins seu es poden paral·lelitzar tasques independents.
2. Cap agent comença pel document històric: comença per aquest fitxer i el paquet actiu.
3. Cada paquet té abast, no-objectius, dependències, criteris d'acceptació i rollback.
4. Qualsevol canvi de schema es fa amb migració additiva, RLS, índexs, generated types i tests.
5. Les decisions sensibles es validen al servidor; la UI no és una frontera de seguretat.
6. Les fases noves no creen una altra font de veritat per a horaris, identitat o ubicacions.
7. El mateix canvi que completa un paquet actualitza:
   - estat del paquet;
   - `STATUS.md`;
   - pla funcional afectat;
   - evidència i decisions.
8. No marcar una fase com a completada amb tests preexistents que no cobreixen el contracte nou.
9. Les incidències P0/P1 trobades durant una fase s'afegeixen al paquet abans de tancar-lo.
10. No implementar innovacions `AP-*` fins que el paquet que les conté estigui actiu.

## 6. Definition of Ready

Un paquet pot passar a 🟡 quan:

- [ ] l'abast i els no-objectius són explícits;
- [ ] les dependències estan ✅;
- [ ] s'han identificat migracions/RPC/UI/worker afectats;
- [ ] existeixen criteris d'acceptació;
- [ ] hi ha pla de migració i rollback;
- [ ] els tests de caracterització actuals s'han executat;
- [ ] no hi ha una decisió funcional oberta bloquejant.

## 7. Definition of Done

Un paquet només passa a ✅ quan:

- [ ] migració aplicable sobre BD existent i sobre una BD neta;
- [ ] integritat tenant/site i RLS verificades;
- [ ] RPCs idempotents i errors amb contracte estable;
- [ ] generated types actualitzats a tots els consumidors;
- [ ] UI cobreix loading, empty, error, retry i permisos;
- [ ] tests SQL/unitaris/integració/E2E definits pel paquet passen;
- [ ] timezone, torn nocturn i concurrència provats quan apliquen;
- [ ] observabilitat i auditoria disponibles;
- [ ] rollback o feature flag provat;
- [ ] `STATUS.md`, aquest document i especificacions actualitzats;
- [ ] evidència registrada al log d'execució.

## 8. Roadmap executable

### EX-00 — Consolidació i baseline

**Estat:** ✅  
**Objectiu:** eliminar dependència del xat i congelar un punt de partida verificable.

| Paquet | Estat | Entregable |
|---|---|---|
| EX-00.1 | ✅ | Persistir les tres revisions/anàlisis |
| EX-00.2 | ✅ | Crear el pla mestre i jerarquia documental |
| EX-00.3 | ✅ | Enllaçar plans i `STATUS.md` al pla mestre |
| EX-00.4 | ✅ | Baseline executat: suites SQL, RPC efectius, drift migracions i failures registrats |
| EX-00.5 | ✅ | Matriu Production Gates validada (§15) |

**Exit criteria:**

- revisions consultables sense el xat;
- tests baseline amb resultats registrats;
- cap document declara producció si falta un gate;
- primer paquet EX-01 preparat amb DoR complet.

### EX-01 — Production Gates d'estació

**Estat:** ✅  
**Depèn de:** EX-00 ✅  
**Objectiu:** eliminar vulnerabilitats i errors operatius abans de desplegar kiosk compartit.

| Paquet | Estat | Scope |
|---|---|---|
| EX-01.1 | ✅ | QR atòmic: token vinculat i consumit dins el punch |
| EX-01.2 | ✅ | Secret kiosk: proxy/cookie HttpOnly, CSP, rotació i revocació |
| EX-01.3 | ✅ | Timezone per site + contracte d'errors 4xx |
| EX-01.4 | ✅ | Rate limit d'emissió/resolve, lockout i mètriques |
| EX-01.5 | ✅ | ST-13 CI + E2E de seguretat i integritat |
| EX-01.6 | ✅ | ST-12 salut mínima: heartbeat, cua i estació morta |

**Exit criteria:** cap `source=qr` falsificable, cap token consumit prematurament, secrets protegits i suite gate en CI.

### EX-02 — Identitat, sessió i privacitat kiosk

**Estat:** ✅  
**Depèn de:** EX-01 ✅  
**Objectiu:** resoldre suplantació i exposició de dades sense biometria.

| Paquet | Estat | Scope |
|---|---|---|
| EX-02.1 | ✅ | ST-10 V1 `punch_only_at_stations` tenant + UX portal |
| EX-02.1b | ✅ | ST-10b cascada: empleat → grup calendari → site → tenant (decisió #22) |
| EX-02.2 | ✅ | ST-18 màquina d'estats i configuració segura |
| EX-02.3 | ✅ | ST-18a document-first, normalització i anti-enumeració |
| EX-02.4 | ✅ | Challenge/PIN específic d'estació |
| EX-02.5 | ✅ | ST-18b QR separat del punch mòbil |
| EX-02.6 | ✅ | ST-18e historial read-only, PIN obligatori i màxim 90 dies |
| EX-02.7 | ✅ | Presets segurs i accessibilitat/auto-blank |

**Exit criteria:** cap punch manual sense la política d'identitat configurada; historial sempre reautenticat; sessió no filtra dades al següent empleat.

### EX-03 — Font única d'horari i ST-19

**Estat:** ✅  
**Depèn de:** EX-00; es pot preparar en paral·lel amb EX-01/02, però no publicar abans dels gates  
**Objectiu:** integrar calendari, horari recurrent, torn publicat, absència i ubicació.

| Paquet | Estat | Scope |
|---|---|---|
| EX-03.1 | ✅ | SP-0 tests de caracterització i ADR de cascada |
| EX-03.2 | ✅ (superseded) | Decisió B: congelar `work_schedules` + conversió one-way |
| EX-03.2-bis | ✅ | Base recurrent setmanal grup+empleat; elimina `work_schedules`/`employee_schedule_assignments` ([ADR-0003](./adr-0003-weekly-recurring-base.md)) |
| EX-03.3 | ✅ | `resolve_employee_work_plan` canònic + adaptador `resolve_work_day` + slots published |
| EX-03.4 | ✅ | ST-19 schema: location, snapshots i integritat |
| EX-03.5 | ✅ | Recompute idempotent en canvis de slots |
| EX-03.6 | ✅ | Migrar dashboard, portal, recordatoris, estació i export al resolver |
| EX-03.7 | ✅ | Dual-run/feature flag i backfill |

**Exit criteria:** tots els consumidors retornen el mateix horari; draft no afecta; holiday/vacation requereix override `work`; nocturns i multi-slot provats.

### EX-04 — Publicació robusta i UX integrada

**Estat:** ✅  
**Depèn de:** EX-03  
**Objectiu:** fer usable i auditable la planificació real.

| Paquet | Estat | Scope |
|---|---|---|
| EX-04.1 | ✅ | Lots/revisions de publicació i snapshots immutables |
| EX-04.2 | ✅ | CRUD `work_shifts`, múltiples slots/dia i anomalies visibles |
| EX-04.3 | ✅ | Preflight, diff post-publicació i períodes tancats |
| EX-04.4 | ✅ | `shift_slot` al calendari general i portal «Els meus torns» |
| EX-04.5 | ✅ | ST-18c ubicació planificada vs estació |
| EX-04.6 | ✅ | ST-18d punch no assignat: warn/block + anomaly snapshot |
| EX-04.7 | ✅ | ST-16 pauses contextuals a l'estació |

**Exit criteria:** preparar, validar, publicar, corregir i auditar una setmana; portal i estació mostren la revisió correcta.

### EX-05 — Offline de producció

**Estat:** ✅  
**Depèn de:** EX-01, EX-02 i contracte temporal EX-03  
**Objectiu:** entrega diferida fiable de punches ja identificats.

| Paquet | Scope |
|---|---|
| EX-05.1 | ✅ Batch client unificat i `client_op_id` estable |
| EX-05.2 | ✅ Outbox kiosk IndexedDB |
| EX-05.3 | ✅ `occurred_at`/`received_at`, àncora temporal i monotònic |
| EX-05.4 | ✅ `CLOCK_SKEW`, `OFFLINE_DELAY`, `max_age` i quarantena |
| EX-05.5 | ✅ E2E mode avió, retry, duplicat, clock change i torn nocturn |
| EX-05.6 | ✅ Feature flag i runbook |

**No-objectiu:** cachejar tota la plantilla o permetre identificació completa offline.

**Exit criteria:** cap duplicat, hora reconstruïble/auditable, operacions dubtoses en quarantena i rollback operatiu.

### EX-06 — Cobertura per franja, ubicació i rol

**Estat:** ✅  
**Depèn de:** EX-03 i EX-04  
**Objectiu:** detectar i resoldre mancances reals, incloses puntes de feina.

| Paquet | Scope |
|---|---|
| EX-06.1 | ✅ Rols, assignacions i qualificacions mínimes |
| EX-06.2 | ✅ Demanda recurrent/extraordinària i CRUD |
| EX-06.3 | ✅ Cobertura per buckets de 15/30 min |
| EX-06.4 | ✅ Planificat/confirmat/real/qualificat |
| EX-06.5 | ✅ Dashboard operatiu i alertes de gap |

### EX-07 — Vacants, disponibilitat i swaps

**Estat:** ✅  
**Depèn de:** EX-06  
**Objectiu:** cobrir torns de forma segura amb autoservei.

| Paquet | Scope |
|---|---|
| EX-07.1 | ✅ Disponibilitat recurrent i excepcions |
| EX-07.2 | ✅ `shift_openings` + claims, sense placeholder employee |
| EX-07.3 | ✅ Eligibility i claim transaccional |
| EX-07.4 | ✅ Portal vacants |
| EX-07.5 | ✅ Swap/give-away/call-off end-to-end |
| EX-07.6 | ✅ Notificacions i escalat urgent |

### EX-08 — Compliance, automatització i integracions

**Estat:** ✅ tancat (08.1–08.4)  
**Depèn de:** EX-06/07 segons funcionalitat  
**Objectiu:** avançar quan el domini base ja produeix dades fiables.

| Subpaquet | Estat |
|---|---|
| EX-08.1 | ✅ Motor de regles laborals |
| EX-08.2 | ✅ Automatitzacions d’anomalies (AP-08) |
| EX-08.3 | ✅ Heurístiques fatiga/equitat (AP-09) |
| EX-08.4 | ✅ Import CSV + `external_entity_mappings` (AP-12) |
| EI3+ / forecast | 🧊 En cua — connectors Holded/PayFit i forecast deferits deliberadament |

**Inclòs al tancament:** regles laborals; anomalies; heurístiques; import CSV + mappings.  
**Fora del tancament (cua):** framework connectors (EI3), Holded (EI4), PayFit (EI5), re-sync (EI6), forecast/auto-scheduler.

### EX-08.1 — Motor de regles laborals

**Estat:** ✅  
**Abast:** `data.labor_rules` (tenant/site); defaults de producte 11h/12h/6d (warn); `evaluate_labor_rules_for_window`; wire a `preflight_publish_shifts` i `evaluate_opening_claim_eligibility`; UI Control horari.  
**No-objectius:** norma legal dura; fatiga/equitat avançada; automatitzacions d’anomalies.  
**Migració:** `20261046000001_labor_rules_ex081.sql`  
**Tests:** `attendance_labor_rules_ex081_tests.sql` **5/5**  
**Evidència:** list/upsert RPCs; issues `MIN_REST_BETWEEN_SHIFTS` / `MAX_DAILY_HOURS` / `MAX_CONSECUTIVE_WORK_DAYS`.

### EX-08.2 — Automatitzacions d’anomalies (AP-08)

**Estat:** ✅  
**Abast:** in-app via `enqueue_notification`; dedup `attendance_anomaly_automation_fired`; quiet hours EX-07.6; settings `attendance_anomaly_automations`; wire `PAUSE_NOT_CLOSED` / scan `PUNCH_OUT_MISSING` / `SHIFT_COVERAGE_GAP`; overtime = G5 `ATTENDANCE_OVERTIME_THRESHOLD`; cron 15m.  
**No-objectius:** email/SMS nous; ML; blueprints automation plens; Work Status push (canal separat).  
**Migració:** `20261047000001_anomaly_automations_ex082.sql`  
**Tests:** `attendance_anomaly_automations_ex082_tests.sql` **5/5**  
**UI:** Control horari → Automatitzacions d’anomalies.

### EX-08.3 — Heurístiques fatiga / equitat (AP-09)

**Estat:** ✅  
**Abast:** `api.get_site_planning_heuristics` — fatiga (consecutius/descans), equitat (hores/caps/nits vs mitjana), patrons absència/retard per DOW, risc de gap demà + suggeriments de reforç; disclaimer anti-scoring.  
**No-objectius:** ML; ranking per sancionar; auto-scheduler; forecast POS.  
**Migració:** `20261048000001_planning_heuristics_ex083.sql`  
**Tests:** `attendance_planning_heuristics_ex083_tests.sql` **5/5**  
**UI:** Planificació → pestanya Heurístiques.

### EX-08.4 — Import CSV + mappings (AP-12 / EI0+EI2+EI1)

**Estat:** ✅  
**Abast:** `data.external_entity_mappings` + `api.import_employees_bulk` (match mapping→NIF→email→create, dry_run); UI Empleats → Importar CSV + enllaços externs a fitxa; help `docs/help/empleats/import-csv.md`.  
**Migració:** `20261049000001_employee_import_csv_ex084.sql`  
**Tests:** `employee_import_csv_ex084_tests.sql` **5/5**  
**Fora d’abast:** EI3+ connectors Holded/PayFit.

## 9. Traçabilitat de findings

| Findings | Paquet de resolució |
|---|---|
| RC-04/05, RX-C2/C3 | EX-01.1 |
| RC-09, RX-B5 | EX-01.2 |
| RC-10/16 | EX-01.3 |
| RC-13, RX-A2 | EX-01.4 |
| RC-03, RX-C1 | EX-02.2/02.3/02.4 |
| RC-02, RX-A7 | EX-02.3/02.6 |
| RX-A4 | EX-02.1 |
| RX-A3/A5 | EX-02.3/02.4 |
| RC-01/11, RX-A6 | EX-03.3/03.4 i EX-04.5 |
| RC-06/07, RX-C4/C5, RX-M6 | EX-05 |
| RC-12/14/15/17/18, RX-C6/B1/B2/B3/M10 | EX-00 |
| AP-04 | EX-06 |
| AP-05/10 | EX-01.6 i EX-08 |
| AP-08 | EX-08 |
| AP-09 | EX-08 |
| AP-12 | EX-08 |

## 10. Plantilla obligatòria de paquet

Cada implementació ha de començar afegint o completant aquest bloc sota el paquet actiu:

```markdown
### EX-XX.Y — Nom

**Estat:** 🟡
**Responsable:** agent/equip
**Abast:**
**No-objectius:**
**Dependències verificades:**
**Fitxers/RPCs afectats:**
**Migració i rollback:**
**Criteris d'acceptació:**
**Tests obligatoris:**
**Observabilitat/auditoria:**
**Evidència de tancament:**
```

## 11. Protocol de continuïtat entre sessions

En començar una sessió:

1. llegir capçalera, fase i paquet actius;
2. revisar l'última entrada del log;
3. verificar `git status` i no assumir que canvis locals estan acabats;
4. llegir només els plans i findings enllaçats pel paquet;
5. executar o confirmar el baseline rellevant;
6. continuar el paquet, no crear un roadmap nou.

En acabar:

1. registrar què s'ha implementat i què no;
2. incloure migracions, tests i resultats;
3. actualitzar l'estat sense ocultar warnings;
4. deixar el següent pas concret;
5. si no compleix DoD, mantenir 🟡.

## 12. Log d'execució

| Data | Paquet | Resultat | Evidència / següent pas |
|---|---|---|---|
| 2026-07-15 | EX-00.1 | ✅ Tres artefactes del xat persistits | Revisions i anàlisi a `docs/plans/checkin/` |
| 2026-07-15 | EX-00.2 | ✅ Pla mestre creat | Aquest document |
| 2026-07-15 | EX-00.3 | ✅ Documents principals enllaçats | `STATUS.md` i capçaleres dels plans |
| 2026-07-15 | EX-00.4 | ✅ Baseline executat | Veure §14; drift migracions 20261014000002–14; 13 suites parcials |
| 2026-07-15 | EX-00.5 | ✅ Matriu §15 validada | Gates PG vs FF vs DM; EX-00 tancat |
| 2026-07-15 | EX-01.1 | ✅ QR atòmic implementat | Migracions 150002/150003; ST-T8/T8a/T8b PASS (15/15) |
| 2026-07-15 | EX-01.2 | ✅ Secret kiosk HttpOnly | Cookie proxy `/api/station`; CSP `/station`; migració localStorage |
| 2026-07-15 | EX-01.5 | ✅ CI + E2E estacions | Workflow `attendance-station-tests.yml`; SQL 18/18; E2E bash QR+4xx+cookie |
| 2026-07-15 | EX-01.4 | ✅ Rate limit QR issue/resolve | Migracions 150005/150006; ST-T15/T16 PASS (18/18) |
| 2026-07-15 | EX-01.3 | ✅ Timezone site + errors 4xx | Migració 150004; ST-T14 PASS (16/16); bootstrap `site_timezone` |
| 2026-07-15 | EX-01.6 | ✅ Heartbeat + salut flota ST-12 | Migració 150007; `POST /heartbeat`; ST-T17 PASS (19/19); badge connexió tenant |
| 2026-07-15 | EX-02.1 | ✅ ST-10 punch_only_at_stations | Migració 150008; enforcement RPC; UX portal + config tenant; ST-T18 PASS (20/20) |
| 2026-07-15 | EX-02.1b | 🟡 Decisió #22 (cascada ST-10b) | Estudi: tenant-only insuficient; grup calendari = knob massiu + override empleat. Spec a `plan-attendance-stations.md` §ST-10b |
| 2026-07-15 | EX-02.1b | ✅ Cascada ST-10b implementada | Migració 150009; `resolve_punch_only_at_stations`; UI Grups + fitxa empleat; ST-T18/T18b PASS (21/21) |
| 2026-07-15 | EX-02.2 | ✅ ST-18 core FSM + config | Migració 150010; bootstrap ST-18; kiosk waiting/session/flash; admin config; ST-T19 PASS (22/22) |
| 2026-07-15 | EX-02.3 | ✅ ST-18a document resolve | Migració 150011; `resolve-employee-document`; teclat DNI; rate limit; default `document_entry`; ST-T20 PASS (23/23) |
| 2026-07-15 | EX-02.4 | ✅ Station employee PIN challenge | Migracions 150012/150013; `verify-employee-pin`; lockout device+employee; UI `portal_pin`; ST-T21 PASS (24/24) |
| 2026-07-15 | EX-02.5 | ✅ ST-18b QR portal separat | Ruta `/portal/station-qr`; nav «QR estació»; QR fora de `/portal/punch`; CTA quan `punch_only_at_stations` |
| 2026-07-16 | EX-02.6 | ✅ ST-18e historial sessió | Migració 150014; `POST employee-history` + PIN; default `session_allow_history=false`; ST-T22 |
| 2026-07-16 | EX-02.7 | ✅ Presets + auto-blank + masking | Migració 150015; presets estricte/rapid/qr; `waiting_idle`/`mask_names`; ST-T23; EX-02 tancat |
| 2026-07-16 | EX-03.1 | ✅ SP-0 ADR + caracterització | [`adr-0001-work-plan-source-of-truth.md`](./adr-0001-work-plan-source-of-truth.md); `attendance_calendar_tests.sql` **15/15 PASS**; BL-03/BL-04 tancats |
| 2026-07-16 | EX-03.2 | ✅ Opció B work_schedules (superseded) | [`adr-0002-work-schedules-option-b.md`](./adr-0002-work-schedules-option-b.md); migració `20261016000001`; REVOKE writes; `convert_*` helper; seed punches→labor; UI schedules retirada; tests EX-03.2 **4/4** |
| 2026-07-16 | EX-03.2-bis | ✅ Base recurrent setmanal (grup+empleat), elimina `work_schedules` | [`adr-0003-weekly-recurring-base.md`](./adr-0003-weekly-recurring-base.md); migracions `20261017000001` (taules + resolver) i `20261017000002` (drop `work_schedules`/`employee_schedule_assignments`); seed Acme actualitzat; `attendance_weekly_recurring_base_adr0003_tests.sql` **9/9 PASS**; `attendance_calendar_tests.sql` **15/15 PASS**; UI `WeeklyRecurringBaseEditor` (Grups + fitxa empleat) |
| 2026-07-16 | EX-03.3 | ✅ resolve_employee_work_plan canònic | Migració `20261018000001`; `data.resolve_employee_work_plan` + helper slots; `api.resolve_work_day` com a adaptador; slots published substitueixen intervals (no converteixen holiday/vacation/leave); tests `attendance_resolve_work_plan_ex033_tests.sql` **7/7 PASS**; calendar **15/15 PASS** |
| 2026-07-16 | EX-03.4 | ✅ ST-19 schema location/snapshots | Migracions `20261018000002` + `20261018000003` (drop overload `assign_shift_slot`); `work_shifts.default_location_id`; `shift_slots.location_id` + snapshots; integritat tenant/site; freeze published; herència default; resolver `scheduled_location_*`; tests `attendance_st19_shift_location_ex034_tests.sql` **7/7 PASS**; regressió calendar **15/15**, EX-03.3 **7/7**, ADR-0003 **9/9** |
| 2026-07-16 | EX-03.5 | ✅ Recompute en canvis de slots | Migració `20261019000001`; `data.enqueue_attendance_day_recompute` + trigger `trg_shift_slots_attendance_recompute` (publish/cancel; draft ignorat); worker existent sense canvis; tests `attendance_shift_recompute_ex035_tests.sql` **5/5 PASS**; regressió calendar **15/15**, EX-03.3 **7/7**, EX-03.4 **7/7** |
| 2026-07-17 | EX-03.6 | ✅ Dashboard → resolver canònic | Migració `20261020000001`; `api.get_today_dashboard_rows` usa `data.resolve_employee_work_plan` (absència/festiu no surten; slots published sí); `p_work_date` opcional; fix `COALESCE` permís NULL; portal/export/recordatoris ja eren canònics; planner UI manté labor-only; tests `attendance_today_dashboard_ex036_tests.sql` **5/5 PASS** |
| 2026-07-17 | EX-03.7 | ✅ Dual-run FF-03 + backfill | Migració `20261021000001`; flag `work_plan_resolver_v2` (default ON); `compare_work_plan_resolver` (shadow canònic vs labor-only); `backfill_attendance_work_plan` (draft/unlocked, enqueue|sync); hot path sense branques V1; tests `attendance_work_plan_ex037_tests.sql` **9/9 PASS**; **EX-03 tancat** |
| 2026-07-17 | EX-04.1 | ✅ Lots/revisions de publicació | Migracions `20261022000001` + `20261022000002` (swap reassign bypass); `data.shift_publications` + `shift_slots.publication_id`; `publish_shifts` versiona/supersede; `list`/`get_shift_publication`; freeze + hash; tests `attendance_shift_publications_ex041_tests.sql` **9/9**; `attendance_shifts_tests.sql` **23/23** |
| 2026-07-17 | EX-04.2 | ✅ CRUD + multi-slot + anomalies | Migració `20261023000001`; `api.create/update/deactivate_work_shift`; UI `ShiftsPage` multi-slot + diàleg plantilles; toast anomalies `SHIFT_OVERLAP`/`WEEKLY_HOURS_EXCEEDED`; tests `attendance_work_shifts_ex042_tests.sql` **6/6** |
| 2026-07-17 | EX-04.3 | ✅ Preflight + diff + períodes tancats | Migracions `20261024000001` + `20261024000002` (fix format); `preflight_publish_shifts`; `publish_shifts(..., warnings_accepted)` + gate; `diff_shift_publications`; bloqueig `payroll_locked`/`MONTH_CLOSED` a assign/delete/publish; UI diàleg preflight; tests `attendance_shift_preflight_ex043_tests.sql` **7/7**; regressió shifts **23/23**, EX-04.1 **9/9** |
| 2026-07-17 | EX-04.4 | ✅ Calendari + portal meus torns | `shifts.calendar` registry + i18n/deep-link; migració `20261025000001` `employee_portal_get_my_shifts`; Edge `/shifts` + proxy; `PortalMyShiftsPage`; push → `/portal/shifts`; `getMyShiftSlots` published-only; tests `attendance_portal_my_shifts_ex044_tests.sql` **3/3** |
| 2026-07-17 | EX-04.5 | ✅ ST-18c ubicació planificada vs estació | Migracions `20261026000001` + `20261026000002` (append-only anomalies); compare a `record_station_time_punch` (warn/`WRONG_SCHEDULED_LOCATION` / block); hint `station_employee_location_hint`; station-api + banner sessió; toggles admin; tests `attendance_st18c_wrong_scheduled_location_ex045_tests.sql` **6/6** |
| 2026-07-17 | EX-04.6 | ✅ ST-18d punch sense assignació | Migració `20261027000001`; `allow_unassigned_punch`/`warn_unassigned_punch` honorats al punch; anomalia `OUTSIDE_ASSIGNMENT`; hint + banner; toggles admin; ST-T12 strict explícit; tests `attendance_st18d_unassigned_punch_ex046_tests.sql` **5/5** |
| 2026-07-17 | EX-04.7 | ✅ ST-16 pauses a estació | Migració `20261028000001`; `break_start`/`break_end` al kiosk; `station_allows_punch_type`; `list_attendance_station_pause_configs`; UI botons pausa; station-api `/pause-configs`; tests `attendance_st16_station_pauses_ex047_tests.sql` **6/6**; **EX-04 tancat** |
| 2026-07-17 | EX-05.1 | ✅ Batch client + client_op_id estable | UUID v7; drain tenant via `sync_time_punches`; portal `POST /punch/sync`; grants `20261029000001`; vitest syncBatch **5/5**; regressió T5 batch **PASS** |
| 2026-07-17 | EX-05.2 | ✅ Outbox kiosk IndexedDB | Dexie `attendance_station_outbox`; `useStationSync`; enqueue offline/`Failed to fetch`; `client_op_id` al POST; banner pendents; vitest stationOutbox **3/3** |
| 2026-07-17 | EX-05.3 | ✅ occurred_at/received_at + monotònic | Migració `20261031000001`; `p_occurred_at` offline; online=`now()`; `received_at` a INSERT; àncora heartbeat IndexedDB; drain envia `occurred_at`; tests `attendance_station_offline_occurred_at_ex053_tests.sql` **4/4** |
| 2026-07-17 | EX-05.4 | ✅ CLOCK_SKEW/OFFLINE_DELAY/max_age | Migració `20261032000001`; settings delay/max_age; anomalies acceptades; `station_punch_too_old` → quarantena; vitest **4/4**; SQL **4/4** |
| 2026-07-17 | EX-05.5 | ✅ E2E offline ST-9 V2 | SQL `attendance_station_offline_e2e_ex055_tests.sql` **6/6**; HTTP `e2e_attendance_station_offline_ex055` **6/6**; CI workflow ampliat |
| 2026-07-17 | EX-05.6 | ✅ FF-04 + runbook | Flag `station_offline_deferred_punch` (default OFF); gate RPC + bootstrap; Acme override local; runbook `docs/runbooks/station-offline-deferred-punch-runbook.md`; tests **4/4**; **EX-05 tancat** |
| 2026-07-17 | EX-06.1 | ✅ Rols / quals | Taules `work_roles`, `employee_role_assignments`, `employee_qualifications`, `role_qualification_requirements`; FKs `default_role_id` / `role_id` + snapshot; helpers + CRUD RPCs; UI Planificació + fitxa empleat + plantilla torn; seed Acme; tests **5/5** |
| 2026-07-17 | EX-06.2 | ✅ Demanda cobertura | Taula `coverage_demands` (recurrent/extraordinària + rol/ubicació/franja); CRUD RPCs; `get_coverage_for_period` suma legacy SCR + demands; UI pestanya Demanda; seed Acme; tests **5/5** |
| 2026-07-17 | EX-06.3 | ✅ Buckets 15/30 | `api.get_coverage_buckets` (demanda vs slots, filtre rol/ubicació, overnight); UI heatmap a Demanda; tests **5/5** |
| 2026-07-17 | EX-06.4 | ✅ Capes cobertura | `employee_confirmed_at` + setting `require_shift_confirmation`; `confirm_shift_slot`; `coverage_presence_intervals`; buckets amb planned/confirmed/present/qualified; UI selector de capa; tests **5/5** |
| 2026-07-17 | EX-06.5 | ✅ Dashboard gaps | `get_coverage_operational_snapshot` (ara + horitzó, missing_now, alertes); widget Tauler «Cobertura ara»; deep-link `?tab=demand`; tests **5/5**; **EX-06 tancat** |
| 2026-07-17 | EX-07.1 | ✅ Disponibilitat | Taules `employee_availability_rules` / `_exceptions`; resolve + `list_site_availability`; CRUD RPCs + `editable_until`; UI fitxa empleat; tests **5/5** |
| 2026-07-17 | EX-07.2 | ✅ Openings + claims | Taules `shift_openings` / `shift_opening_claims`; publish/claim/reject/cancel; UI Planificació → Vacants; **sense** `employee_id` NULL ni slot en claim; tests **5/5** |
| 2026-07-17 | EX-07.3 | ✅ Eligibility + accept | Migració `20261041000001`; `evaluate_*` + `accept_shift_opening_claim` → slot published; `first_eligible` auto-accept; UI Acceptar a Vacants; tests **5/5** |
| 2026-07-17 | EX-07.4 | ✅ Portal vacants | Migració `20261043000001`; RPCs portal list/claim/withdraw; edge `/openings`; UI `/portal/openings`; tests **5/5** |
| 2026-07-17 | EX-07.5 | ✅ Swap/give-away/call-off | Migració `20261044000001`; `kind` + eligibility; call_off → vacant; UI Planificació → Intercanvis + `/portal/swaps`; tests **5/5** |
| 2026-07-17 | EX-07.6 | ✅ Push + escalat | Migració `20261045000001`; `planning_push` queue task; triggers openings/claims/swaps; `escalate_urgent_shift_openings` + cron 15m; tests **5/5**; **EX-07 tancat** |
| 2026-07-17 | EX-08.1 | ✅ Regles laborals | Migració `20261046000001`; `labor_rules` + evaluate; preflight/eligibility; UI Control horari; tests **5/5** |
| 2026-07-17 | EX-08.2 | ✅ Anomaly automations | Migració `20261047000001`; emit+dedup+quiet hours; pause/punch-out/coverage scans; UI toggles; tests **5/5** |
| 2026-07-17 | EX-08.3 | ✅ Heurístiques AP-09 | Migració `20261048000001`; fatiga/equitat/gap/patrons; UI Planificació → Heurístiques; tests **5/5** |
| 2026-07-17 | EX-08.4 | ✅ Import CSV AP-12 | Migració `20261049000001`; `external_entity_mappings` + `import_employees_bulk`; UI Importar CSV + enllaços; tests **5/5** |
| 2026-07-17 | EX-08 | ✅ **Fase tancada** | 08.1–08.4 ✅; EI3+ Holded/PayFit / forecast **en cua** (`employee-import/plan.md`) |
| 2026-07-18 | ST-11 | ✅ Hardening QR | Migració `20261050000001`; entropia 32B/min43 + RL dins `resolve_attendance_identity_token`; Edge `p_client_key`; tests **7/7** |
| 2026-07-18 | ST-6c+/14/2a+/15 | ✅ Paquet estacions | Migració `20261051000001` (`summarize_location_work` + update/bulk assign); enllaços UI; dates+massiu; QR aparellament; tests **7/7** |
| 2026-07-18 | AP-05/10 | ✅ Flota estacions | Migració `20261052000001`; heartbeat outbox; `fleet_health` enriquit; bulk status/lockdown/revoke; widget Tauler; tests **6/6** |
| 2026-07-19 | EX-09.1 | ✅ Retenció batched | Migració `20261053000001`; settings opt-in ≥4a; purge GUC; cron diari; UI Control horari; tests `attendance_retention_purge_ex091_tests.sql` |
| 2026-07-19 | EX-09.2 | ✅ Enllaç inspecció | Migracions `202610540–560`; RPCs create/list/revoke/resolve; Edge `inspect-api` + email; `/inspect/[id]` cookie HttpOnly; UI Control horari; tests `attendance_inspection_access_ex092_tests.sql` |
| 2026-07-19 | EX-09.3 | ✅ Docs | EXECUTION/STATUS/plan.md + smoke; pla [`plan-attendance-legal-access.md`](./plan-attendance-legal-access.md) |
| 2026-07-20 | G2a.2 | ✅ flex_midday | Migració `20261058000001`; validació consolidació + UI política; tests T8–T10 |
| 2026-07-20 | Fase 6 | ✅ Triggers restants | Migració `20261059000001`; `PUNCH_IN_UNUSUAL_HOUR` / `ABSENCE_REQUEST_PENDING` / `MONTH_CLOSED_REPORT`; UI toggles; tests `attendance_fase6_triggers_tests.sql` **6/6** |

## 13. Següent pas exacte

1. **Sense paquet EX actiu.** Roadmap EX-00…EX-09 tancat. AP-05/10 flota ✅.
2. **Cua diferida (quan hi hagi client pilot / prioritat):** EI3 framework + EI4 Holded (+ EI5 PayFit, EI6 re-sync) — veure [`../employee-import/plan.md`](../employee-import/plan.md).
3. **AP-06 check-in contextual:** backlog de producte — deps ST-19 + Work Status ✅; cal **especificació d'implementació** abans de codificar. Detall: [`analisi-producte-control-horari.md`](./analisi-producte-control-horari.md) §AP-06.
4. Altres cues producte: forecast/auto-scheduler (DM-02), etc. — només amb decisió explícita de nova fase.

## 14.1 Reparació drift migracions (2026-07-15)

**Causa:** migracions `20261014000002`–`14` aplicades al schema fora del tracker (`schema_migrations` només tenia `00001`). `migration up` fallava a `00002` per `CREATE POLICY` no idempotent.

**Accions executades:**

1. `DROP POLICY IF EXISTS` afegit a `20261014000002` i `20261014000007` (idempotent en `db reset`).
2. `DROP FUNCTION` de l'overload 15-param de `record_time_punch` afegit a `20261014000003`.
3. `DROP FUNCTION` de l'overload 8-param de `log_employee_portal_access_event` afegit a `20260920000001`.
4. Nova migració `20261015000001_fix_rpc_overload_drift.sql` — neteja overloads en BD existents.
5. `supabase migration repair --local --status applied` per `20261014000002`…`14`.
6. `supabase migration up --local` — aplica `20261015000001`.

**Estat post-repair:**

| Comprovació | Abans | Després |
|---|---|---|
| Migracions ST registrades | 1/14 | 15/15 (+ cleanup) |
| `migration list` pending | 13 × `remote=""` | 0 pending |
| `record_time_punch` overloads | 2 | 1 (18 params) |
| `log_employee_portal_access_event` overloads | 2 | 1 (9 params) |
| `attendance_station_tests.sql` | 11/13 | **13/13 PASS** |
| `attendance_tests.sql` | 7/12 (5 broken) | **10/12** (2 errors aïllament T1→T2/T4) |

**Failures restants no causats per drift** (baseline conegut):

- Calendar T1/T2/T5 — resolver no usa `work_schedules` (EX-03)
- Calendar T7 — tipus `personal` obsolet al fixture
- Portal tests — `token_id` NULL en partició `employee_portal_access_logs_2026_07` (schema/test, no overload)

## 14. Baseline EX-00.4 — evidència (2026-07-15)

**Entorn:** Docker `supabase_db_cavalle-app` healthy; 416 migracions registrades; **13 migracions ST pendents al tracker** (`20261014000002`–`20261014000014`, `remote=""`).

**Drift detectat:** `npx supabase migration up --local` falla a `20261014000002` (`station_register_rate_limits` policy ja existeix). Alguns objectes de ST-4…ST-7 ja són presents (`validate_station_geo_probe`, `display_title`, `attendance_location_assignments`, `station_kiosk_next_punch`) però el tracker no reflecteix les migracions. **Cal alinear tracker + schema abans de mesurar de nou.**

### RPC crítics — definició efectiva al repo (última migració)

| RPC | Migració canònica al repo | Notes baseline |
|---|---|---|
| `api.resolve_work_day` | `20260914000006_absence_counts_as_worked_minutes.sql` | Usa `resolve_labor_calendar_for_employee`; **no consulta `work_schedules` ni `shift_slots`** |
| `api.record_station_time_punch` | `20261014000013_station_location_assignments_st2a.sql` | 7 params; geo via `p_device_geo`; zone filter ST-2a |
| `api.resolve_attendance_identity_token` | `20261014000007_attendance_identity_tokens_st4.sql` | **Marca `used_at` al resolve**, abans del punch (RC-04/05) |
| `api.record_time_punch` | `20261014000004` + `20261014000003` | **2 overloads coexistents** → crides amb defaults ambigues |

### Resultats suites SQL (estat actual de la BD)

| Suite | Pass | Fail | Error | Notes |
|---|---:|---:|---:|---|
| `attendance_shifts_tests.sql` | 23 | 0 | 0 | ✅ Referència estable Phase 2 |
| `attendance_station_tests.sql` | 11 | 2 | 0 | ST-T9/T10 geo + day state |
| `attendance_calendar_tests.sql` | 8 | 4 | 0 | T1/T2/T5 esperen `work_schedules`; T7 tipus `personal` obsolet |
| `attendance_tests.sql` | 7 | 2 | 3 | `record_time_punch` overload duplicat |
| `employee_portal_tests.sql` | — | — | — | Avortat: `log_employee_portal_access_event` overload duplicat |
| `e2e_attendance_stations_joint.ps1` | — | — | — | No executat (requereix `station-api` + proxy `:3002`) |

### Failures classificats

| ID | Origen | Classificació | Paquet resolució |
|---|---|---|---|
| BL-01 | `record_time_punch` ×2 overloads | Bug schema (migració additiva sense DROP) | EX-00 cleanup o pre-EX-01 |
| BL-02 | `log_employee_portal_access_event` ×2 overloads | Bug schema | EX-00 cleanup |
| BL-03 | Calendar T1/T2/T5 `day_type=unknown` | Test desalineat amb resolver real (`work_schedules` desconnectat) | ✅ EX-03.1 — suite alineada; desconnexió caracteritzada a T0 |
| BL-04 | Calendar T7 `invalid_absence_type: personal` | Fixture de test obsoleta | ✅ EX-03.1 — tipus `personal_days` |
| BL-05 | ST-T9 `station_punch_blocked: state unknown` | Interacció day-state + geo; possible drift migracions | EX-01 després d'alinear BD |
| BL-06 | ST-T10 `missing geo test device` | Depèn de ST-T9 dins la mateixa transacció | Idem BL-05 |
| BL-07 | Migracions 20261014000002–14 pendents / drift | Entorn local no reproduïble | ✅ Reparada 2026-07-15 (§14.1) |

### Cobertura absent (no és failure, és gap)

- QR atòmic vinculat al punch (RC-04/05)
- Secret kiosk HttpOnly / CSP (RC-09)
- Timezone site a totes les RPC estació (RC-10)
- ST-18a identitat manual com a gate (RC-03)
- E2E seguretat estació en CI (EX-01.5)
- `resolve_employee_work_plan` / integració `shift_slots` (EX-03)

## 15. Matriu Production Gates vs feature flags (EX-00.5 draft)

**Regla:** cap fila marcada **Gate** pot declarar-se «apta per producció» sense ✅ verificat. Els **Feature flags** permeten rollout; no substitueixen un gate de seguretat.

| ID | Element | Tipus | Estat avui | Gate producció? | Paquet | Evidència requerida |
|---|---|---|---|---|---|---|
| PG-01 | QR consumit al resolve, no al punch | Gate seguretat | ✅ EX-01.1 | **Sí** — kiosk QR | EX-01.1 | ST-T8a resolve cancel·lat; ST-T8 consumeix al punch |
| PG-02 | `source=qr` exigeix token vàlid al punch | Gate seguretat | ✅ EX-01.1 | **Sí** | EX-01.1 | ST-T8b `identity_token_required` |
| PG-03 | Secret estació fora de `localStorage` | Gate seguretat | ✅ EX-01.2 | **Sí** | EX-01.2 | Cookie HttpOnly Path=/api/station; revocació neteja sessió |
| PG-04 | Timezone per site (no hardcoded Madrid) | Gate operatiu | ✅ EX-01.3 | **Sí** | EX-01.3 | ST-T14 Atlantic/Canary vs Madrid |
| PG-05 | Rate limit emissió/resolve QR + lockout | Gate seguretat | ✅ EX-01.4 | **Sí** | EX-01.4 | ST-T15 issue 10/15min; ST-T16 resolve 30/15min; `station_rate_limit_events` |
| PG-06 | Contracte errors 4xx estació (no 500) | Gate operatiu | ✅ EX-01.5 | **Sí** | EX-01.3/01.5 | E2E: 401/409; `mapStationRpcError` |
| PG-07 | ST-18a identitat manual (DNI/llista) | Gate privacitat | ✅ EX-02.3 + EX-02.4 | **Sí si** `manual`/`list` actiu | EX-02.3/02.4 | Anti-enumeració + PIN challenge ✅ |
| PG-08 | Historial kiosk reautenticat | Gate privacitat | ✅ EX-02.6 | **Sí si** historial actiu | EX-02.6 | PIN obligatori; `session_allow_history` default false; ST-T22 |
| PG-12 | Presets + auto-blank + masking | Gate privacitat | ✅ EX-02.7 | **Sí** kiosk compartit | EX-02.7 | Presets; `unsafe_station_config`; waiting blank; ST-T23 |
| PG-09 | CI estacions (SQL + E2E gate) | Gate qualitat | ✅ EX-01.5 | **Sí** | EX-01.5 | `.github/workflows/attendance-station-tests.yml` |
| PG-10 | RPC sense overloads ambigus | Gate qualitat | ✅ BL-01/02 resolts | **Sí** | Pre-EX-01 | Suites attendance + portal verdes |
| PG-11 | Migracions locals = repo | Gate entorn | ✅ BL-07 resolt | **Sí** abans de mesurar | EX-00 | `migration list` sense `remote=""` |
| FF-01 | `attendance_effective_time_enabled` | Feature flag | ✅ Track G (G1–G6) | No (opt-in) | Track G | Default `false`; motor + UI quan actiu; G2a.2 `flex_midday` ✅ |
| FF-02 | `punch_only_at_stations` (ST-10/10b) | Feature flag | ✅ EX-02.1b | No (producte) | EX-02.1b | Cascada empleat → grup → site → tenant; ST-T18b |
| FF-03 | Resolver V2 `resolve_employee_work_plan` | Feature flag dual-run | ✅ EX-03.7 | No | EX-03.7 | Shadow-compare + backfill; hot path sempre canònic |
| FF-04 | Offline deferred punch (ST-9 V2) | Feature flag | ✅ EX-05.6 | No (opt-in) | EX-05.6 | `station_offline_deferred_punch`; runbook; E2E 05.5 |
| FF-05 | Geo antifraud estació (ST-5) | Config per estació | ✅ ST-5 | No (opt-in) | ST-5 | `geo_antifraud_*` + probe; ST-T9/T10; geo NULL al punch |
| DM-01 | Vacants / `shift_openings` | Feature | ✅ EX-07 | No | EX-07 | Openings, claims, portal, swaps, push |
| DM-02 | Auto-scheduler / forecast | Demand-only | ❌ | No | — | Només proposta (SP-6); diferit |

## 16. EX-01.1 — QR atòmic (tancat 2026-07-15)

**Estat:** ✅

**Implementat:**

- `api.resolve_attendance_identity_token` — previsualització sense `used_at`.
- `api.record_station_time_punch(..., p_identity_token)` — valida i consumeix token dins la transacció del punch.
- `station-api` + `public-portal` — `identity_token` obligatori en punch QR.
- Migracions: `20261015000002_station_qr_atomic.sql`, `20261015000003_station_qr_atomic_token_id_fix.sql`.

**Evidència:** `attendance_station_tests.sql` — 15/15 PASS (ST-T8, ST-T8a, ST-T8b).

**Rollback:** revertir migracions; kiosk ha de tornar a enviar `identity_token` en mode QR.

## 17. EX-01.2 — Secret kiosk HttpOnly (tancat 2026-07-15)

**Estat:** ✅

**Implementat:**

- Proxy `/api/station/*` emet cookie `attendance_station_auth` (HttpOnly, SameSite=Lax, Path=/api/station).
- El client només guarda metadades (`device_id`, `device_public_id`) a `sessionStorage`; **mai** el secret.
- `POST /api/station/register` i `session/migrate` estableixen la cookie; `session/logout` i errors d'auth la netegen.
- Migració automàtica des de `localStorage` legacy (`session/migrate`).
- CSP + `X-Frame-Options` a `/station/*`.
- Revocació admin (`revoke_attendance_station_secret`) invalida el secret al servidor; el kiosk rep `station_invalid_secret` i es desaparella.

**Fitxers:** `app/api/station/[...path]/route.ts`, `lib/attendance-station/{cookie,proxy,client,constants}.ts`, `next.config.ts`, `station/page.tsx`.
