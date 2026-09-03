# Pla específic — Planificador de torns V2 integrat

**Estat:** proposta tècnica per implementar  
**Àmbit:** planificació operativa, calendaris laborals, horaris, ubicacions, absències, portal d'empleat, fitxatges i cobertura  
**Sectors prioritaris:** fàbrica, hostaleria, restauració i operacions amb torns  
**Documents relacionats:**

- [Pla d'implementació de control horari](../../product-design/17-time-attendance-implementation-plan.md)
- [Model de dades de control horari](../../product-design/16-time-attendance-data-model.md)
- [Pla d'estacions de fitxatge](./plan-attendance-stations.md)
- [Estudi UX de fitxatge en estació](./estudi-station-punch-ux-v2.md)
- [Calendaris laborals i cascada actual](../../help/horaris/calendaris-laborals.md)
- [Estat del projecte de control horari](./STATUS.md)
- [Pla mestre d'execució](./EXECUTION.md) — paquets EX-03, EX-04, EX-06 i EX-07
- [Anàlisi de producte](./analisi-producte-control-horari.md)

---

## 1. Resum executiu

El planificador actual és un **MVP visual i de backend**, no encara la font operativa completa de l'horari de l'empleat.

Avui:

- permet crear instàncies de torn, detectar solapaments, publicar una setmana i calcular una cobertura diària bàsica;
- té backend per a intercanvis, auditoria i notificacions push de canvis en torns publicats;
- però `api.resolve_work_day()`, que determina les hores esperades per als fitxatges, resums i exportacions, **no consulta `shift_slots`**;
- `data.resolve_schedule_planner_day()` tampoc incorpora els torns publicats;
- *(Històric, resolt a ADR-0003)* `work_schedules` va estar desconnectat del resolver des de juliol de 2026 i finalment s'ha eliminat; la base recurrent setmanal ara viu a `calendar_group_weekly_intervals` / `employee_weekly_intervals`, consultades en directe pel resolver;
- alguns dashboards criden el resolver de calendari directament i poden ignorar absències i overrides que sí aplica `resolve_work_day()`;
- la UI només representa un torn per empleat i dia, encara que el model permet torn partit;
- la cobertura actual compara empleats únics del dia amb un total diari, no cobertura real per franja, ubicació i rol;
- no hi ha vacants, disponibilitat, rols/capacitacions ni un flux complet d'empleat per consultar, reclamar o intercanviar torns.

Per tant, no s'han d'afegir vacants sobre l'MVP sense resoldre abans la font de veritat. El V2 ha de complir aquesta regla:

> Un torn en esborrany és una proposta. Només un torn publicat modifica l'horari operatiu esperat de l'empleat. Una absència aprovada continua tenint prioritat sobre el torn.

El torn publicat serà l'últim esglaó de la **cascada de planificació**, però no l'últim de totes les regles: les absències aprovades, els bloquejos legals i els períodes de nòmina tancats són capes de control superiors.

---

## 2. Què funciona ara

### 2.1 Backend disponible

| Capacitat | Estat actual | Observació |
|---|---|---|
| Plantilles de torn | Disponible | `data.work_shifts`, amb hores, color i local opcional |
| Instàncies assignades | Disponible | `data.shift_slots`, amb snapshot d'inici/final i estat |
| Esborrany/publicació/cancel·lació | Parcial | Sense lot versionat ni revisió formal |
| Detecció de solapaments | Disponible | Inclou torns nocturns |
| Excés d'hores setmanals | Disponible | Avís bàsic contra `weekly_hours` |
| Cobertura requerida | Parcial | Només recompte diari; insuficient per operacions |
| Intercanvis | Backend parcial | RPCs existents; falta experiència completa de manager i empleat |
| Auditoria | Disponible | Triggers sobre taules de torns |
| `calendar_events` | Disponible | Es crea en publicar |
| Push per canvi de torn | Disponible | Cua i worker ja implementats |
| Integració amb horari efectiu | **Disponible** (EX-03.3+) | `resolve_employee_work_plan` / `resolve_work_day` llegeixen slots published |
| Recompute en canvi de torn | **Disponible** (EX-03.5) | Publish/cancel encua `attendance_recompute_queue`; draft no afecta |
| Horaris setmanals com a base | **Disponible** (ADR-0003 / EX-03.2-bis) | `calendar_group_weekly_intervals` / `employee_weekly_intervals` |
| Dashboard coherent amb absències | **Disponible** (EX-03.6) | `get_today_dashboard_rows` → `resolve_employee_work_plan` |

### 2.2 UI disponible

`ShiftsPage.tsx` ofereix:

- selecció setmanal i per centre;
- paleta de plantilles;
- assignació per clic;
- eliminació;
- publicació de tots els esborranys de la setmana;
- avís visual d'excés d'hores;
- cobertura agregada per dia.

Limitacions:

1. `slotMap[employee_id|date]` conserva un sol torn: un torn partit o dos torns no solapats es perden visualment.
2. No hi ha edició d'hores, ubicació, rol, pauses o notes des de la cel·la.
3. No hi ha copiar setmana, patrons rotatius, selecció múltiple, drag-and-drop real ni desfer.
4. No hi ha filtres per departament, rol, línia, zona o qualificació.
5. No es distingeix bé esborrany, publicat, modificat després de publicar i cancel·lat.
6. La cobertura és diària i pot donar un fals positiu encara que falti personal durant la punta de feina.
7. El càlcul de dates amb `toISOString()` des de dates locals pot desplaçar el dia segons zona horària/DST.
8. No hi ha vista operativa «qui falta ara» ni comparació planificat/real.
9. Les anomalies retornades per `assign_shift_slot` no es presenten correctament al manager.
10. No hi ha CRUD de plantilles `work_shifts` ni de requisits de cobertura a la UI.
11. Els push de canvi de torn poden enllaçar a un calendari de portal que no mostra el torn notificat.
12. `calendar_events` rep events de torn, però el registre visual no tracta completament `shift_slot`.

### 2.3 Intenció original

El pla original pretenia:

- una graella visual setmanal/mensual;
- assignar plantilles a empleats;
- alertar de solapaments, hores contractuals i cobertura;
- publicar la setmana;
- exposar els torns al calendari general;
- permetre intercanvis.

La base és aprofitable, però la declaració «Phase 2 completada i tancada» només és certa per al **core inicial**. No ho és per a la integració amb l'horari legal/esperat ni per a una operació robusta de fàbrica o hostaleria.

---

## 3. Model conceptual: separar cinc conceptes

No s'han de continuar barrejant aquests conceptes:

1. **Calendari laboral base:** dies laborables, festius i excepcions.
2. **Patró horari base:** intervals setmanals habituals (`work_schedules`).
3. **Torn operatiu:** assignació concreta i publicada per a una data.
4. **Demanda/cobertura:** quantes persones calen, on, quan i amb quin rol.
5. **Assistència real:** fitxatges i temps realment treballat.

Relació:

```text
Contracte + patró horari + calendari
                  │
                  ▼
        disponibilitat teòrica
                  │
         torn publicat (concreta)
                  │
        absència aprovada (ajusta)
                  ▼
       horari operatiu esperat
                  │
           fitxatges reals
                  ▼
    diferència planificat vs real
```

La demanda no modifica directament l'horari de ningú. Genera mancances, suggeriments o vacants. Només una assignació publicada crea obligació operativa.

---

## 4. Cascada canònica de resolució

### 4.1 Ordre de la base cap a la capa més específica

1. Override individual de calendari (puntual, `labor_calendar_overrides`).
2. Override de grup al local (puntual).
3. Override de local (puntual).
4. Override de grup global (puntual).
5. Override d'empresa (puntual).
6. Festiu assignat al tenant/local.
7. **Base recurrent setmanal individual** (`employee_weekly_intervals`, ADR-0003).
8. **Base recurrent setmanal de grup** (`calendar_group_weekly_intervals`, ADR-0003).
9. **Torn o torns publicats** per a l'empleat i data.
10. **Absència aprovada**, total o parcial.

> **Nota ADR-0003 (reobre EX-03.2):** la capa «patró setmanal `work_schedules`» es va rebutjar a ADR-0002 i **ara s'ha eliminat** (taules dropejades). En el seu lloc hi ha una base recurrent viva per `day_of_week` (grup + empleat), consultada directament pel resolver sense materialitzar overrides — veure [ADR-0003](./adr-0003-weekly-recurring-base.md).

Interpretació:

- les capes 1–8 formen el calendari/horari base (puntual > festiu > recurrent);
- la capa 9 és l'últim esglaó de la planificació operativa;
- la capa 10 no és un horari alternatiu: és una incidència aprovada que anul·la o redueix l'obligació.

### 4.2 Regles que eliminen ambigüitats

- Un `shift_slot` en `draft` **mai** afecta `resolve_work_day`, recordatoris, anomalies ni nòmina.
- Un o més `shift_slots` en `published` substitueixen els intervals base del dia.
- Diversos slots no solapats formen un sol dia esperat amb diversos intervals.
- Un torn publicat **no pot convertir per si sol** un dia `holiday`, `vacation` o `leave` en jornada laboral. Abans de publicar-lo cal un override laboral explícit que defineixi el dia com a `work`; després, el torn concreta hores, ubicació i rol. El preflight ha d'enllaçar a aquesta correcció, no limitar-se a acceptar un warning.
- Una absència total aprovada anul·la els intervals esperats, però conserva els minuts planificats de referència per als còmputs que corresponguin.
- Una absència parcial retalla o marca l'interval afectat; no converteix automàticament tot el dia en absència.
- Si una absència s'aprova després de publicar, el torn no es reasigna silenciosament: es crea una mancança de cobertura i s'avisa el manager.
- Els overrides legacy `employee_day_overrides` s'han de migrar i retirar. No hi pot haver dos editors d'excepcions individuals.
- En períodes de nòmina tancats, cap canvi retroactiu pot alterar el resultat sense un flux d'esmena auditat.

### 4.3 Decisió sobre `work_schedules`

**Resolt a EX-03.2 / [ADR-0002](./adr-0002-work-schedules-option-b.md) (opció B) — superseded per EX-03.2-bis / [ADR-0003](./adr-0003-weekly-recurring-base.md).**

`work_schedules`, `work_schedule_intervals` i `employee_schedule_assignments` s'han **eliminat** (no només congelat). La SoT setmanal és ara una base recurrent viva:

- `data.calendar_group_weekly_intervals` (per grup) i `data.employee_weekly_intervals` (per empleat, override individual) — consultades directament pel resolver per `day_of_week`, sense materialitzar `labor_calendar_overrides`;
- assignació única via `employee.calendar_group_id` (ja existent) — sense dualitat amb un segon model d'assignació setmanal;
- `api.apply_weekly_pattern_to_calendar` es manté només per a **excepcions temporals per rang de dates** (no per l'horari habitual);
- helper one-way `convert_work_schedule_assignments_to_labor_calendar` eliminat (ja no té sentit sense taula origen);
- UI de «Horaris de treball» segueix retirada de `LaborCalendarSetupPage`; l'edició de la base recurrent viu a `WeeklyRecurringBaseEditor` (pestanya «Grups» de `PlanificacioPage` i fitxa d'empleat);
- seed de punches Acme continua llegint el calendari laboral resolt (`resolve_labor_calendar_for_employee`), ara alimentat per la base recurrent.

### 4.4 Una sola funció de domini

Crear una funció interna canònica:

```text
data.resolve_employee_work_plan(employee_id, work_date)
```

Ha de retornar:

- `day_type`;
- `base_source`, `effective_source` i IDs d'origen;
- intervals base;
- slots publicats;
- intervals efectius després d'absències;
- minuts planificats, d'absència i efectius;
- `scheduled_site_id` i `scheduled_location_id`;
- rol/posició;
- zona horària;
- festiu i compensació potencial;
- warnings i conflictes;
- versió de publicació.

Consumidors:

- `api.resolve_work_day`;
- `api.get_schedule_planner_days`;
- recomputació de fitxatges;
- recordatoris d'entrada/sortida;
- portal d'empleat;
- estació de fitxatge;
- resums i exportació de nòmina.

No s'ha de duplicar la cascada en TypeScript i SQL. La UI pot explicar-la, però el resultat autoritatiu ha de venir del backend.

Els dashboards i RPC que avui criden `resolve_schedule_planner_day()` directament han de migrar al resolver canònic; en cas contrari continuaran ignorant absències o altres capes.

---

## 5. Ubicacions: «centre», «zona de fitxatge» i «lloc planificat»

Són dimensions diferents:

- `site_id`: centre administratiu/operatiu.
- `location_id`: lloc o zona concreta on s'ha de prestar servei i, si aplica, fitxar.
- ubicació real del fitxatge: estació/GPS des d'on es registra.

### Regles

- Afegir `location_id` a `shift_slots` i a les vacants.
- El local de la plantilla és només un valor per defecte; el slot publicat conserva la ubicació concreta.
- Un empleat pot pertànyer administrativament a un centre i cobrir un torn en un altre si té autorització.
- L'assignació fixa de `attendance_location_assignments` és elegibilitat/base, no substitueix el «lloc del dia».
- L'estació compara la seva ubicació amb `scheduled_location_id` retornat pel resolver.
- Es conserva separadament `scheduled_location_id` i `punch_location_id` per poder detectar `WRONG_SCHEDULED_LOCATION`.
- Canviar el nom o configuració d'una ubicació no ha de reescriure la història: el slot publicat conserva el snapshot mínim visible.

---

## 6. Model de dades V2

### 6.1 Evolució de `work_shifts`

Continua sent una plantilla reutilitzable. Afegir, si no existeixen:

- `default_location_id`;
- `default_role_id`;
- `paid_minutes` o política de pauses;
- `code` estable per integracions;
- `tags`;
- `valid_from`, `valid_to`;
- `is_active`.

Editar una plantilla no pot modificar slots ja publicats; aquests ja tenen snapshot d'hores, ubicació, rol i pauses.

### 6.2 Evolució de `shift_slots`

Afegir:

- `location_id`;
- `role_id`;
- `publication_id`;
- `revision_no`;
- `supersedes_slot_id`;
- `break_policy_snapshot`;
- `location_name_snapshot`;
- `role_name_snapshot`;
- `published_at`, `published_by`;
- `cancel_reason`, `cancelled_at`, `cancelled_by`;
- `source`: `manual`, `rotation`, `vacancy`, `swap`, `import`, `optimizer`;
- `lock_version` per concurrència optimista.

Restriccions:

- hores obligatòries i durada positiva amb suport nocturn;
- tenant/site/location/employee/role coherents;
- no solapament per empleat, incloent el dia anterior/següent;
- no assignar empleat inactiu;
- no mutar directament snapshots publicats;
- índexs per `(employee_id, slot_date, status)`, `(site_id, slot_date, status)`,
  `(location_id, slot_date, status)` i publicacions;
- transaccions amb lock en claim, swap i publicació.
- qualsevol transició rellevant d'un slot publicat encua de manera idempotent la recomputació de `(employee_id, work_date)`.

### 6.3 Lots i revisions de publicació

Nova `shift_publications`:

- tenant, centre, rang;
- versió;
- estat `draft`, `published`, `superseded`, `cancelled`;
- qui/quand;
- resum de warnings acceptats;
- hash o snapshot del contingut.

Objectius:

- publicar atòmicament;
- saber exactament quina versió va veure l'empleat;
- canviar només afectats després de publicar;
- notificar diferències, no tota la setmana;
- impedir edició retroactiva silenciosa.

### 6.4 Rols i qualificacions

Introduir:

- `work_roles`: cambrer, cuina, recepció, operari de línia, cap de torn, manteniment;
- `employee_role_assignments`: rols que pot cobrir cada empleat, amb nivell i vigència;
- `employee_qualifications`: capacitacions/certificats amb caducitat;
- `role_qualification_requirements`: requisits obligatoris per rol o torn.

No s'ha d'utilitzar `job_title` com a motor de validació: és text descriptiu, no una capacitat operativa.

### 6.5 Disponibilitat i preferències

Introduir:

- `employee_availability_rules`: regla recurrent per dia/setmana i vigència;
- `employee_availability_exceptions`: excepcions per data;
- preferència `preferred`, `available`, `unavailable`;
- motiu opcional privat;
- data límit de canvi.

La disponibilitat no és una absència ni garanteix un torn. Serveix per validar/suggerir i per limitar vacants elegibles.

### 6.6 Demanda i cobertura

L'actual `shift_coverage_requirements` és insuficient. Evolucionar-lo o substituir-lo per requisits amb:

- centre i ubicació;
- rol;
- data concreta o regla recurrent;
- inici/final;
- mínim, objectiu i màxim;
- prioritat;
- font: manual, plantilla, reserves/POS, comandes, producció, esdeveniment;
- vigència i versió.

La cobertura es calcula per buckets de 15 o 30 minuts:

```text
ubicació + rol + franja
necessaris / assignats / presents / absents / vacants
```

Cal separar:

- **planificada:** slots publicats;
- **confirmada:** empleats que han acceptat si el tenant ho exigeix;
- **real:** fitxatges actuals;
- **qualificada:** persones presents que compleixen el rol/certificació.

---

## 7. Cobrir una punta de treball

### 7.1 Flux manager

1. Defineix una demanda extraordinària: data, franja, ubicació, rol i persones addicionals.
2. El sistema calcula el gap contra els torns publicats.
3. Proposa:
   - ampliar/reassignar persones disponibles;
   - crear torns curts;
   - publicar vacants;
   - oferir hores a una llista elegible.
4. Mostra impacte: descans, hores, solapaments, qualificacions, equitat i cost si hi ha dades.
5. El manager publica l'opció escollida.

### 7.2 Vacants

No fer `employee_id = NULL` a `shift_slots` sense redefinir totes les invariants. Mantenir:

- `shift_openings`: torn ofert, capacitat i política;
- `shift_opening_claims`: candidatures/claims;
- en acceptar, crear un `shift_slot` assignat i publicat dins una única transacció.

`shift_openings`:

- data, hores, centre, ubicació, rol i qualificacions;
- places totals/disponibles;
- `claim_policy`: `first_eligible`, `manager_approval`, `ranked_window`;
- finestra d'oferta;
- col·lectiu elegible;
- compensació o etiqueta informativa, si aplica;
- estat `draft`, `open`, `filled`, `expired`, `cancelled`.

### 7.3 Validació atòmica d'un claim

En el moment d'acceptar, revalidar:

- la vacant continua oberta i amb places;
- empleat actiu i autoritzat al centre;
- rol i certificacions vigents;
- no hi ha absència;
- disponibilitat;
- no hi ha solapament;
- descans entre jornades;
- límits diaris/setmanals i hores extraordinàries;
- no s'ha cobert la plaça en paral·lel.

Si tot és correcte:

1. bloquejar la vacant;
2. acceptar claim;
3. crear slot publicat;
4. incrementar revisió/publicació;
5. recalcular cobertura;
6. notificar empleat i manager;
7. tancar o reduir la vacant;
8. auditar.

### 7.4 Polítiques recomanades

- Per defecte: `manager_approval`.
- `first_eligible` només en tenants que ho activin i sempre amb validacions dures.
- `ranked_window` per equitat: es recullen candidats fins a una hora límit i el manager decideix amb criteris explicables.
- No implementar adjudicació «AI» opaca. Primer, suggeriments deterministes i auditables.

---

## 8. Intercanvis, cessió i baixa de darrera hora

Separar:

- **swap:** A i B intercanvien dos torns;
- **give away:** A ofereix el seu torn i B l'assumeix;
- **call-off:** A comunica que no podrà assistir;
- **manager reassignment:** el responsable reassigna;
- **open replacement:** es publica substitució urgent.

Flux:

1. empleat inicia petició;
2. sistema filtra destinataris elegibles;
3. candidat accepta;
4. manager aprova si la política ho exigeix;
5. transacció revalida totes les regles;
6. es creen revisions dels slots, mai canvis silenciosos;
7. notificacions i auditoria.

El backend actual d'intercanvis es pot reaprofitar, però cal ampliar estats, UI, ubicació/rol i validacions legals.

---

## 9. Regles laborals i seguretat operativa

Crear un motor de regles configurable per tenant/site/conveni:

- descans mínim entre jornades;
- durada màxima diària i setmanal;
- màxim de dies consecutius;
- pauses obligatòries;
- regles de menors;
- hores extraordinàries i aprovació;
- treball nocturn;
- festius;
- restriccions de rol/certificació;
- disponibilitat;
- mínims de cobertura crítica;
- període mínim de preavís per canvis.

Cada regla té severitat:

- `info`;
- `warn_require_reason`;
- `block`.

No codificar com a universal una xifra legal concreta: pot variar per país, conveni, edat, sector o acord. El producte ha d'oferir presets i configuració validada.

### Invariants dures

- tenant isolation i permisos;
- no solapament;
- claim sense sobreassignació;
- publicació atòmica;
- snapshots publicats immutables;
- període tancat no mutable;
- dates resoltes en timezone del centre;
- cap notificació abans del commit;
- idempotència en publicació, claim, swap i cancel·lació.

---

## 10. UX objectiu

### 10.1 Planificador de manager

Vistes:

1. **Persones × dies:** assignació setmanal.
2. **Cobertura temporal:** franges per ubicació i rol.
3. **Línia/servei:** llocs o posicions com files.
4. **Operació en viu:** planificat, present, tard, absent, vacant.

Funcions bàsiques:

- múltiples torns per dia;
- drag-and-drop i selecció múltiple;
- copiar dia/setmana i rotacions;
- editar hores/ubicació/rol/pauses;
- desfer abans de publicar;
- filtres i cerca;
- warnings inline;
- resum d'hores contractuals, planificades i extres;
- comparació amb disponibilitat i absències;
- publicació amb preflight;
- diff de canvis després de publicar;
- CRUD de plantilles de torn;
- visualització de les anomalies retornades pel backend;
- integració de `shift_slot` al calendari general.

### 10.2 Preflight de publicació

Abans de publicar:

- errors bloquejants;
- warnings que requereixen motiu;
- gaps de cobertura;
- persones sense descans;
- solapaments;
- torns en festiu;
- absències;
- certificacions caducades;
- empleats afectats i notificacions a enviar.

Publicar no és només canviar `status`: crea una revisió autoritativa.

### 10.3 Portal d'empleat

Nova secció «Els meus torns»:

- avui/setmana/mes;
- lloc, rol, hora i instruccions;
- confirmació opcional de recepció;
- vacants elegibles;
- reclamar o retirar candidatura;
- disponibilitat i preferències;
- demanar swap/cessió;
- informar baixa de darrera hora;
- historial de canvis;
- deep links des de push/email/in-app.

No s'ha d'obrir el portal personal des d'una estació compartida.

### 10.4 Estació de fitxatge

La sessió de l'empleat rep:

- torn actual/següent;
- ubicació planificada;
- interval i pauses;
- warnings de lloc incorrecte;
- accions de fitxatge adequades a l'estat.

La política `warn/block` continua sent configurable per estació, amb avís per defecte.

---

## 11. Notificacions

Reutilitzar la cua push existent i afegir:

- setmana publicada;
- torn assignat/modificat/cancel·lat;
- nova vacant elegible;
- claim rebut/acceptat/rebutjat/expirat;
- torn disponible per swap;
- swap acceptat/rebutjat;
- recordatori de confirmació;
- cobertura crítica no resolta;
- call-off urgent.

Canals configurables:

- in-app sempre;
- push web opt-in;
- email;
- altres canals només via integració futura.

Controls:

- deduplicació;
- quiet hours excepte urgències;
- localització i timezone;
- preferències de l'empleat;
- registre de lliurament;
- cap dada personal sensible al text visible de la notificació bloquejada.

---

## 12. Integració amb fitxatges i nòmina

### 12.1 Fitxatges

En registrar/recomputar:

- usar la versió de `resolve_employee_work_plan` que correspon al dia;
- conservar el slot planificat relacionat amb cada entrada;
- comparar inici/final real amb intervals publicats;
- detectar retard, sortida anticipada, no-show, lloc incorrecte i extensió no planificada;
- suportar torn partit i nocturn;
- no rebutjar automàticament un fitxatge real només perquè la planificació sigui incorrecta.

### 12.2 Canvis retroactius

- Abans de tancament: recomputar dies afectats i marcar revisió.
- Després d'aprovació: requerir reobertura o esmena.
- Després d'exportació/nòmina bloquejada: crear ajust, no reescriure història.
- Guardar quina revisió de planificació es va usar en el resum.

### 12.3 Informes

- planificat vs treballat;
- absències i no-show;
- cobertura prevista vs real;
- hores extres planificades vs sobrevingudes;
- canvis després de publicar;
- vacants i temps de cobertura;
- equitat en repartiment de torns;
- treball fora de la ubicació planificada.

---

## 13. Roadmap d'implementació

### SP-0 — Contracte de domini i tests de caracterització

**Estat:** ✅ (EX-03.1, 2026-07-16)

**Objectiu:** congelar el comportament actual abans de migrar.

- [x] inventariar l'última definició efectiva de cada RPC;
- [x] tests de caracterització de calendari, horari, absència, torn, nocturn i timezone;
- [x] documentar dades legacy i ús real de `employee_schedule_assignments`;
- [x] reparar o substituir tests que encara assumeixen el resolver anterior basat en `work_schedules`;
- [x] identificar dashboards/consumidors que eviten `resolve_work_day` (migració → EX-03.6);
- [x] decidir migració d'`employee_day_overrides` (retirar a EX-03.3+);
- [x] definir contracte JSON del resolver canònic.

**Sortida:** [`adr-0001-work-plan-source-of-truth.md`](./adr-0001-work-plan-source-of-truth.md) · suite `attendance_calendar_tests.sql` **15/15 PASS**.

### SP-1 — Resolver canònic i ubicació del torn

**Objectiu:** fer que el torn publicat sigui l'horari operatiu real.

- [x] `data.resolve_employee_work_plan` (EX-03.3);
- [x] integrar slots published i múltiples intervals *(base = labor + weekly ADR-0003)*;
- [x] adaptar `api.resolve_work_day` com a adaptador;
- [x] `location_id` i snapshots (EX-03.4 / ST-19);
- [ ] integrar absències parcials (retall d'intervals; total ja cobert);
- [x] trigger idempotent de recompute en publicar/modificar slots (EX-03.5);
- [x] corregir el dashboard «programat avui» perquè respecti absències (EX-03.6);
- [x] feature flag / dual-run (EX-03.7).

**Criteri de sortida SP-1 (EX-03 tancat):** resolver canònic, ST-19 schema, recompute, dashboard i dual-run/backfill. Absències parcials (retall d'intervals) resten com a millora; UI planificador V2 → EX-04 / SP-2.

### SP-2 — Publicació robusta i UI V2 bàsica

**Objectiu:** planificar sense corrupció ni sorpreses.

- [x] lots/revisions de publicació (EX-04.1);
- [x] preflight (EX-04.3);
- [x] múltiples slots per dia (EX-04.2);
- [x] CRUD de plantilles `work_shifts` (EX-04.2);
- [ ] edició, còpia, rotacions i selecció múltiple;
- [x] timezone-safe dates (EX-04.2: `toISODate` local);
- [x] diffs post-publicació (EX-04.3);
- [x] mostrar anomalies d'assignació (EX-04.2); registrar `shift_slot` al calendari visual (EX-04.4);
- [x] bloqueig de períodes tancats (EX-04.3);
- [ ] notificacions només després de commit.

**Criteri de sortida (parcial EX-04.4):** calendari general mostra torns + portal «Els meus torns» (published). SP-4 autoservei i EX-04.5 estació resten pendents.

### SP-3 — Cobertura real per franja, ubicació i rol

**Objectiu:** gestionar operació i puntes.

- [x] rols i qualificacions mínimes (EX-06.1);
- [x] demanda recurrent i extraordinària (EX-06.2);
- [x] CRUD de requisits de cobertura (EX-06.2);
- [x] buckets de cobertura (EX-06.3);
- [x] capes planificat/confirmat/real/qualificat (EX-06.4);
- [x] vista de gaps + dashboard planificat/real (EX-06.5);
- torns curts i suggeriments deterministes.

**Criteri de sortida:** es detecta una mancança concreta, no només un dèficit diari.

### SP-4 — Autoservei: vacants, disponibilitat i swaps

**Objectiu:** cobrir torns amb participació dels empleats.

- [x] disponibilitat (EX-07.1);
- [x] `shift_openings` i claims (EX-07.2);
- [x] eligibility + accept transaccional → slot published (EX-07.3);
- [x] portal vacants list/claim/withdraw (EX-07.4);
- [x] swap / give-away / call-off (EX-07.5);
- [x] push openings/claims/swaps + escalat urgent (EX-07.6);
- polítiques d'adjudicació;
- transaccions i idempotència.

**Criteri de sortida:** una vacant pot publicar-se, reclamar-se, aprovar-se i convertir-se en torn sense solapaments ni sobreassignació.

### SP-5 — Compliance, equitat i operació avançada

**Objectiu:** robustesa sectorial.

- motor de regles configurable;
- alertes de fatiga i descans;
- criteris d'equitat explicables;
- rols/certificats avançats;
- confirmació de torn;
- escalat automàtic de vacant urgent;
- mètriques i informes.

### SP-6 — Demanda assistida i integracions

**Objectiu:** optimitzar, no substituir el control humà.

- imports de reserves, vendes, ocupació, comandes o pla de producció;
- forecast per franges;
- generació suggerida de demanda;
- auto-scheduler en mode proposta;
- simulació de cost/cobertura;
- connectors de nòmina/ERP/POS.

No iniciar SP-6 fins tenir dades fiables, regles i explicabilitat.

---

## 14. Estratègia de migració segura

1. Afegir camps/tables sense canviar comportament.
2. Backfill de snapshots i ubicacions.
3. Crear resolver V2 sota feature flag.
4. Executar antic i nou en paral·lel; registrar diferències.
5. Corregir divergències esperades i inesperades.
6. Activar V2 en tenant de prova.
7. Recomputar períodes oberts, mai els bloquejats sense esmena.
8. Migrar UI i consumidors.
9. Retirar resolvers/overrides legacy.
10. Activar vacants només després de SP-1 i SP-2.

Rollback:

- feature flag per tornar a lectura antiga durant SP-1;
- migracions additives;
- cap eliminació de columnes legacy fins a dos cicles estables;
- jobs idempotents i observables.

---

## 15. Matriu mínima de tests

### Cascada

- patró setmanal sense overrides;
- festiu sobre patró;
- cada nivell d'override;
- slot draft ignorat;
- slot publicat substitueix base;
- dos slots no solapats;
- torn en festiu sense override laboral rebutjat i amb override `work` autoritzat;
- absència total i parcial sobre slot;
- cancel·lació/revisió.

### Temps

- torn nocturn;
- canvi DST;
- centre península/Canàries;
- dues ubicacions amb timezone diferent;
- límits de setmana i mes.

### Concurrència

- dos claims per l'última plaça;
- swap simultani;
- publicació concurrent;
- modificació amb `lock_version` antic;
- retry idempotent.

### Seguretat

- RLS cross-tenant;
- manager limitat a centre;
- empleat només veu les seves ofertes/slots;
- claim en nom d'un altre;
- manipulació de role/location;
- worker amb payload antic o duplicat.

### Integració

- publicació → portal → notificació;
- publicació → `resolve_work_day` → recordatori;
- publicació → estació → lloc programat;
- slot/absència → recompute;
- període tancat → canvi rebutjat/esmena;
- claim → slot → cobertura.

---

## 16. Funcionalitats sectorials recomanades

### Fàbrica

Must-have:

- línia/zona/posició;
- cap de torn i dotació mínima per qualificació;
- rotacions;
- torns nocturns;
- relleu i solapament entre equips;
- certificacions amb caducitat;
- fatiga/descans;
- absència de darrera hora i substitució urgent;
- cobertura en viu.

Avançat:

- demanda des del pla de producció;
- skills matrix;
- restriccions de conveni;
- simulació de throughput segons cobertura;
- tasques de relleu associades al torn.

### Hostaleria/restauració

Must-have:

- ubicació i rol;
- torn partit;
- franges curtes per puntes;
- disponibilitat;
- vacants i swaps mòbils;
- cobertura per servei;
- previsió per reserves/esdeveniments;
- canvi urgent i notificacions.

Avançat:

- demanda des de reserves/POS/ocupació;
- comparació cost laboral/vendes;
- borsa multi-centre;
- torns «on call» només si la política laboral ho permet;
- suggeriment de sortida anticipada quan baixa la demanda, sempre amb registre i aprovació.

---

## 17. Funcionalitats a evitar o ajornar

- Auto-scheduler opac que publica sense revisió.
- Editar directament un torn publicat sense revisió.
- Fer que un esborrany afecti fitxatges.
- Usar només `weekly_hours` com a compliance.
- Cobertura només per recompte diari.
- Assignar rols a partir de text lliure.
- Permetre claim sense revalidació transaccional.
- Sobreescriure hores històriques després de nòmina.
- Bloquejar un fitxatge real perquè el planner estigui mal configurat.
- Implementar un xat general abans de tenir notificacions i fluxos d'acció fiables.

---

## 18. Decisions proposades

1. El torn publicat és la capa més específica de planificació.
2. L'absència aprovada preval sobre el torn i obre gap de cobertura.
3. Els drafts no afecten cap càlcul extern.
4. Una única funció SQL resol l'horari autoritatiu.
5. `location_id` és obligatori per a slots publicats quan el tenant treballa amb ubicacions.
6. Les plantilles no reescriuen slots publicats.
7. Vacants en taules separades; l'acceptació crea un slot.
8. Claims per defecte amb aprovació de manager.
9. Cobertura per franja + ubicació + rol.
10. Dates sempre segons timezone del centre.
11. Canvis post-publicació creen revisió i notificació.
12. Períodes tancats només canvien per esmena.
13. Els fitxatges es registren encara que hi hagi conflicte de planificació; es marca anomalia.
14. Regles legals configurables i explicables, amb severitat.
15. Primer suggeriments deterministes; optimització avançada després.

---

## 19. Criteris de «solució integrada i tancada»

No es considerarà complet fins que:

- qualsevol pantalla i procés obtingui el mateix horari esperat;
- un torn publicat modifiqui recordatoris, estació, anomalies i resums;
- ubicació planificada i ubicació del fitxatge siguin traçables;
- torns partits i nocturns funcionin de punta a punta;
- absències generin cobertura pendent sense inconsistències;
- publicació i claims siguin atòmics, idempotents i auditats;
- no es pugui alterar silenciosament un període tancat;
- cobertura sigui temporal, geogràfica i per rol;
- l'empleat pugui veure canvis i actuar sobre vacants/swaps;
- les regles expliquin per què una assignació s'avisa o es bloqueja;
- els tests de cascada, timezone, concurrència, RLS i integració siguin obligatoris a CI.

Aquest ordre és deliberat: **primer una font de veritat; després una publicació segura; després cobertura i autoservei; finalment optimització**.
