# Prompt per a la IA implementadora — Refinament de Pauses, Absències i Permisos al Control Horari

Tens accés complet al repositori i al pla `attendance_v3_plan.md` (Control Horari v3). Aquest document complementa el pla existent amb un refinament profund de com modelar les **pauses dins la jornada**, les **absències parcials** (visita mèdica personal, assumptes propis), els **permisos retribuïts legals** i les **incapacitats temporals (IT/baixes)**.

---

## 0. Marc legal de referència (vigent a Espanya, juny 2026)

### 0.1 Pauses dins la jornada (ET art. 34.4)

La clau legal és simple però important:

> "Quan la jornada diària continuada superi les 6 hores, s'establirà un descans mínim de 15 minuts. **Aquest període es considera temps de treball efectiu quan així s'estableixi per conveni col·lectiu o contracte de treball.**"

És a dir:
- **Per defecte legal:** la pausa de 15 min NO compta com a temps treballat (no es paga, no suma a les 8h).
- **Amb conveni/contracte:** pot comptar com a temps treballat (es paga, sí suma a les 8h).
- **Cada sector/empresa decideix:** el Conveni de la Banca, el Conveni d'Oficines i Despatxos, el Conveni de Comerç... molts inclouen la pausa "bocadillo" com a temps treballat. Hosteleria, logística, sanitat... no necessàriament.

**Exemples reals per arquetip/vertical:**
- `workshop_maker` (taller mecànic, carpinteria): pausa esmorzar 20 min, típicament SÍ computa per conveni metal·lúrgic.
- `hospitality` (restaurant, hotel): pausa menjar entre torns, típicament NO compta.
- `practice` (clínica dental, psicologia): pausa entre pacients, pot comptar com temps de presència.
- `field_service` (electricista, instal·lador): pauses curtes entre feines, computen depenent del conveni.

### 0.2 Absències parcials durant la jornada

Tres categories molt diferents que sovint es confonen:

**A) Visita mèdica per revisió d'empresa (medicina del treball):**
- Obligatòria per l'empresa (Llei de Prevenció de Riscos Laborals).
- Compta com a temps treballat. No es descompta de res.
- El treballador no ha de compensar-ho.

**B) Visita mèdica personal (metge de capçalera, especialista, urgències pròpies):**
- El conveni/contracte determina si és retribuïda o no.
- Molts convenis reconeixen "el temps indispensable" per visita mèdica com retribuït.
- Altres obliguen a recuperar les hores o descomptar de borsa de permisos.
- L'Estatut no garanteix aquest permís de forma explícita (sí el temps per urgències familiars, art. 37.3.b).

**C) Acompanyament a familiar (fill menor, dependent):**
- RDL 5/2023: fins a 4 dies/any per urgències familiars imprevisibles (malaltia sobtada, accident).
- Temps indispensable, retribuït.

### 0.3 Permisos retribuïts legals (ET art. 37.3, actualitzat a juny 2026)

Mínims legals vigents (el conveni pot millorar-los, mai empitjorar-los):

| Causa | Dies mínims | Notes |
|---|---|---|
| Matrimoni / pareja de hecho | 15 naturals | Conveni pot ampliar |
| Naixement fill (ambdós progenitors) | 19 setmanes | RDL 9/2025. 6 obligatòries ininterrompudes |
| Permís parental addicional | 8 setmanes | 2 retribuïdes + 6 sense retribució, fins 8 anys |
| Defunció cònjuge/parella/familiars 2n grau | 2 dies (4 amb desplaçament) | Acord pendent d'ampliar a 10 dies (no en vigor) |
| Hospitalització / operació familiar greu | 5 dies | RDL 5/2023 |
| Urgències familiars imprevisibles | 4 dies/any (per hores) | RDL 5/2023 art. 37.3.b |
| Trasllat domicili | 1 dia | |
| Funcions electorals / tribunal exàmens | Temps indispensable | |
| Formació vinculada a empresa | 20h/any acumulables 5 anys | ≥1 any antiguitat |
| Lactància | 1h/dia fins 9 mesos | Divisible o acumulable |
| Visites prenatals / preparació part | Temps indispensable | |
| Menstruació incapacitant | IT especial, 365+180 dies | Desde 2023 |

**Nota de conveni:** sectors com banca, administració pública, grans retail, asseguradores solen tenir permisos molt més generosos. Els arquetips de l'app (hospitality, field_service, workshop_maker, practice) solen tenir convenis sectorials amb entre 2-5 dies addicionals d'assumptes propis.

### 0.4 Incapacitat Temporal (IT / baixes mèdiques)

La IT és un **estat de suspensió de la relació laboral**, no un permís. Categories:

| Tipus IT | Origen | Qui paga | Durada màxima |
|---|---|---|---|
| IT per malaltia comuna | Malaltia no laboral | Empresa dies 4-15; INSS des del 16 | 365 + 180 dies |
| IT per accident de treball | Accident laboral | INSS des del dia 1 | 365 + 180 dies |
| IT per malaltia professional | Exposició laboral | INSS des del dia 1 | 365 + 180 dies |
| IT per menstruació incapacitant | Malaltia | INSS des del dia 1 | 365 + 180 dies |
| Maternitat/Paternitat (Nacimiento) | Familiar | INSS des del dia 1 | 16-19 setmanes |

**Gestió documental de la IT:**
- Part mèdic de baixa → empleat lliura còpia a empresa en 3 dies hàbils (des de 2023 l'INSS ho envia directament).
- Parts de confirmació → cada 7 dies (malaltia comuna) o 14 dies (accident).
- Part d'alta → empresa ha de reincorporar el treballador.

**Per al control horari:** una IT implica **0 hores treballades** durant tot el període, i els dies NO es descompten de vacances ni permisos. El registre horari mostra l'employee en estat IT.

---

## 1. El problema de disseny central

El pla v3 (`attendance_v3_plan.md`) usa **`pause_type`** dins de `time_punches` per a les pauses, però no hi ha un model clar per a les absències (parcials o totals) ni per als permisos/IT.

**La distinció fonamental que el model ha de capturar:**

```
Jornada laboral d'un dia pot contenir:
  ├── Temps DINS la jornada
  │   ├── Temps treballat efectivament (punch_in → punch_out, descomptant pauses no computades)
  │   └── Pauses (break_start → break_end)
  │       ├── Computen com a temps treballat (counts_as_work: true)  → sumen a les 8h
  │       └── No computen (counts_as_work: false)                    → no sumen
  │
  └── Temps FORA de la jornada (absències)
      ├── Absència parcial (va al metge 2h, surt abans)
      │   ├── Retribuïda (compta com a treballat per conveni)
      │   └── No retribuïda (descompte de salari o borsa permisos)
      ├── Permís retribuït (dia sencer: defunció, matrimoni, etc.)
      │   → No requereix fitxatge; genera "dia complet cobert"
      └── IT / Baixa mèdica
          → Suspensió laboral; NO és absència gestionada per RRHH de l'empresa
```

---

## 2. Model de dades proposat — a revisar i implementar

### 2.1 Taula `tenant_pause_configs` — refinament

La taula proposada al pla és correcta però cal ampliar:

```sql
CREATE TABLE data.tenant_pause_configs (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            uuid NOT NULL,
  site_id              uuid,              -- null = tots els sites del tenant
  key                  text NOT NULL,     -- 'lunch', 'breakfast', 'rest', 'medical_company', 'custom_1'...
  name_i18n            jsonb NOT NULL,    -- {"ca": "Dinar", "es": "Comida", "en": "Lunch"}
  counts_as_work       boolean NOT NULL DEFAULT false,  -- LA CLAU
  default_duration_min integer,          -- minuts suggerits (per UX; no obligatori)
  max_duration_min     integer,          -- si supera → anomalia / alerta
  requires_justification boolean NOT NULL DEFAULT false,
  is_active            boolean NOT NULL DEFAULT true,
  sort_order           integer NOT NULL DEFAULT 0,
  created_at           timestamptz NOT NULL DEFAULT now()
);
```

**Seed de pauses per defecte** (es creen quan s'activa el mòdul d'assistència d'un tenant nou):

```sql
-- Esmorzar: compta com a temps treballat (la majoria de convenis d'industria/serveis)
('breakfast', '{"ca":"Esmorzar","es":"Almuerzo","en":"Breakfast"}', counts_as_work: true, 20min)

-- Menjar: NO compta per defecte (temps propi de l'empleat)
('lunch', '{"ca":"Dinar","es":"Comida","en":"Lunch"}', counts_as_work: false, 60min)

-- Descans pactat: compta (pausa breve oficial per conveni)
('rest', '{"ca":"Descans","es":"Descanso","en":"Break"}', counts_as_work: true, 15min)

-- Visita mèdica d'empresa: compta (obligatòria per llei)
('medical_company', '{"ca":"Rev. Mèdica Empresa","es":"Rev. Médica Empresa","en":"Company Medical"}',
  counts_as_work: true, requires_justification: false)
```

**Important:** el tenant pot modificar `counts_as_work` per adaptar-ho al seu conveni. El seed és un punt de partida raonable, no un valor definitiu.

### 2.2 Nova taula `employee_absences` — el model d'absències

Separar COMPLETAMENT les absències (fora de jornada) dels punches (dins de jornada):

```sql
CREATE TABLE data.employee_absences (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            uuid NOT NULL,
  site_id              uuid,
  employee_id          uuid NOT NULL,

  -- Tipus d'absència (veure enum)
  absence_type         text NOT NULL,  -- 'vacation', 'paid_leave', 'unpaid_leave', 'it_common',
                                       --  'it_work_accident', 'it_maternity', 'it_paternity',
                                       --  'it_parental', 'partial_medical', 'partial_personal',
                                       --  'other_paid', 'other_unpaid'

  -- Rang temporal
  start_date           date NOT NULL,
  end_date             date NOT NULL,   -- igual que start_date per a absències parcials d'un dia

  -- Per a absències parcials (dins d'un dia de treball)
  partial_start_time   time,            -- si és parcial: hora d'inici absència
  partial_end_time     time,            -- si és parcial: hora de fi absència
  partial_hours        numeric(4,2),    -- hores d'absència (calculat o introduït)

  -- Classificació laboral
  counts_as_worked     boolean NOT NULL DEFAULT false,  -- ¿computa com a temps treballat?
  affects_entitlement  boolean NOT NULL DEFAULT false,  -- ¿descompta de la borsa de permisos?
  entitlement_type     text,            -- quin entitlement afecta: 'vacation', 'personal_days', 'medical_leave'...

  -- IT (baixes Seguretat Social)
  it_reference         text,            -- número de baixa SS (si aplica)
  it_start_confirmed   boolean DEFAULT false,  -- part mèdic rebut
  it_end_confirmed     boolean DEFAULT false,  -- part d'alta rebut

  -- Flux d'aprovació
  status               text NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending','approved','rejected','cancelled','active','closed')),
  requested_by         uuid,            -- qui ho sol·licita (pot ser el manager per IT)
  approved_by          uuid,
  approved_at          timestamptz,
  rejection_reason     text,

  -- Documentació
  document_id          uuid,            -- ref al DMS si s'adjunta part mèdic, certificat, etc.
  notes                text,

  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);
```

### 2.3 Taula `tenant_absence_type_configs` — el conveni del tenant

Permet que el tenant adapti el comportament de cada tipus d'absència al seu conveni:

```sql
CREATE TABLE data.tenant_absence_type_configs (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            uuid NOT NULL,
  absence_type         text NOT NULL,
  name_i18n            jsonb NOT NULL,
  counts_as_worked     boolean NOT NULL DEFAULT false,
  affects_entitlement  boolean NOT NULL DEFAULT false,
  entitlement_type     text,
  requires_approval    boolean NOT NULL DEFAULT true,
  requires_document    boolean NOT NULL DEFAULT false,
  max_days_per_year    integer,         -- null = sense límit
  is_active            boolean NOT NULL DEFAULT true,
  is_system            boolean NOT NULL DEFAULT false,  -- tipus de sistema no eliminable
  created_at           timestamptz NOT NULL DEFAULT now()
);
```

**Seed de tipus d'absència** per a tots els tenants (is_system = true):

```sql
-- Vacances anuals
('vacation', counts_as_worked: false, affects_entitlement: true, entitlement: 'vacation',
  requires_approval: true, is_system: true)

-- Permís retribuït (dies assumptes personals, conveni)
('personal_days', counts_as_worked: true, affects_entitlement: true, entitlement: 'personal_days',
  requires_approval: true, requires_document: false, is_system: true)

-- Permís per defunció familiar (ET mínim: 2 dies)
('bereavement', counts_as_worked: true, affects_entitlement: false,
  requires_approval: false, requires_document: true, is_system: true)

-- Permís per matrimoni (ET: 15 dies naturals)
('marriage', counts_as_worked: true, affects_entitlement: false, max_days_per_year: 15,
  requires_approval: false, requires_document: true, is_system: true)

-- Permís per hospitalització / operació familiar (ET RDL 5/2023: 5 dies)
('family_hospitalization', counts_as_worked: true, affects_entitlement: false, max_days_per_year: 5,
  requires_document: true, is_system: true)

-- Permís per urgència familiar (ET RDL 5/2023: 4 dies/any per hores)
('family_emergency', counts_as_worked: true, affects_entitlement: false, max_days_per_year: 4,
  requires_document: false, is_system: true)

-- Visita mèdica personal (durant jornada)
('partial_medical_personal', counts_as_worked: false, affects_entitlement: false,
  requires_document: true, is_system: true)
-- NOTA: el tenant pot canviar counts_as_worked a true si el seu conveni ho preveu

-- Revisió mèdica d'empresa
('partial_medical_company', counts_as_worked: true, affects_entitlement: false,
  requires_document: false, is_system: true)

-- IT malaltia comuna (baixa SS)
('it_common', counts_as_worked: false, affects_entitlement: false,
  requires_approval: false, requires_document: true, is_system: true)

-- IT accident de treball
('it_work_accident', counts_as_worked: false, affects_entitlement: false,
  requires_document: true, is_system: true)

-- IT maternitat/paternitat (Nacimiento y cuidado del menor)
('it_maternity', counts_as_worked: false, affects_entitlement: false, max_days_per_year: 133,
  requires_document: true, is_system: true)  -- 19 setmanes * 7 dies

-- IT permís parental (post-nacimiento)
('it_parental', counts_as_worked: false, affects_entitlement: false, max_days_per_year: 56,
  requires_document: true, is_system: true)  -- 8 setmanes

-- Reducció de jornada (guarda legal, lactància acumulada)
('reduced_hours', counts_as_worked: false, affects_entitlement: false,
  requires_document: true, is_system: true)
```

### 2.4 Integració amb el recompute d'assistència

La funció `api.recompute_attendance_worker` ha de tenir en compte:

```
hores_treballades_efectives =
  sum(time_entries.worked_seconds) / 3600
  + sum(pauses WHERE counts_as_work = true)          -- pauses que computen
  + sum(absences WHERE counts_as_worked = true        -- absències retribuïdes que computen
        AND date = dia_recompute)

hores_absència_no_treballada =
  sum(absences WHERE counts_as_worked = false
        AND date = dia_recompute)

estat_del_dia =
  IT/baixa     → si hi ha absence_type IN ('it_*') activa per a aquest dia
  Permís       → si hi ha absence_type NOT IN ('it_*') cobrint tot el dia
  Parcial      → si hi ha absence parcial + punches
  Normal       → si hi ha punches sense absències
  Absent       → si no hi ha punches ni absències (anomalia)
```

---

## 3. Consideracions per arquetip/vertical

### 3.1 Pauses per arquetip

La IA ha de generar el **seed de pauses per defecte diferenciat per arquetip** (no per tenant individual), que s'aplica quan un tenant d'aquell arquetip activa el mòdul:

**`workshop_maker`** (metall, fusta, construcció — Conveni Metal·lúrgic / Construcció):
- Esmorzar 20 min, `counts_as_work: true` (estàndard en convenis d'indústria)
- Dinar 30 min, `counts_as_work: false`

**`hospitality`** (restaurant, hotel, bar):
- Dinar entre torns 30-60 min, `counts_as_work: false`
- Descans breu 15 min, `counts_as_work: true` (Conveni Hosteleria sol reconèixer descans curt)

**`practice`** (clínica, consulta, despatx):
- Descans 15 min, `counts_as_work: true`
- Dinar 30-60 min, `counts_as_work: false`

**`field_service`** (instal·ladors, tècnics, transport):
- Descans 15 min, `counts_as_work: true` (temps presència entre desplaçaments)
- Dinar variable, `counts_as_work: false`

**`generic`**:
- Esmorzar 15 min, `counts_as_work: true`
- Dinar 45 min, `counts_as_work: false`

### 3.2 Permisos per arquetip — dies addicionals conveni típics

La IA ha de documentar (no implementar automàticament, però sí fer-ho configurable) els dies típics per conveni sectorial que superen el mínim legal:

- **Hosteleria**: 2 dies assumptes personals (molts convenis provincials)
- **Metall/Indústria**: 3 dies assumptes propis, permís per fills menors d'edat a metge
- **Comerç**: 2-3 dies assumptes personals
- **Sanitat/Clínica privada**: 6 dies assumptes propis (Conveni Marc Sanitat Privada)
- **Construcció**: 2 dies assumptes propis

---

## 4. UX — equilibri entre potència i simplicitat

### 4.1 Per al treballador (fitxatge)

El treballador ha de veure una interfície simple:
- Botons de pausa: **els noms de les pauses configurades pel tenant**, sense tecnicismes.
- NO veu si compta o no com a temps treballat (això és cosa del sistema).
- Per a absències parcials (visita mèdica): botó "Sortida per permís" que demana el tipus (de la llista simplificada que el tenant ha activat) i l'hora de retorn prevista.
- No veu mai el codi intern `absence_type`.

### 4.2 Per al manager/RRHH (gestió)

- Pot veure i aprovar sol·licituds d'absència.
- Pot registrar baixes IT (introducció manual de la IT).
- Pot configurar quins tipus d'absència estan actius al seu tenant.
- Rep alertes quan una IT supera X dies sense part de confirmació.

### 4.3 Regla d'or per a la implementació

> **El tenant configura el comportament laboral (compta o no, necessita aprovació o no). El treballador simplement descriu el que fa (esmorzar, sortida mèdica). El sistema calcula les implicacions.**

---

## 5. Instruccions per a la IA implementadora

### 5.1 Revisió del pla existent (`attendance_v3_plan.md` — Control Horari v3)

El pla real és el **Control Horari v3**. Ja inclou les següents peces que cal tenir en compte:

**Ja cobert al pla v3 (NO reimplementar):**
- `time_punches` amb `pause_type`, `pause_counts_as_work`, `is_remote`, camps de geo i `geo_consent` (Fase 1.1).
- `tenant_pause_configs` amb `key`, `label_i18n`, `counts_as_work`, `max_duration_minutes` (Fase 1.3).
- `vacation_entitlements` amb cascada tenant/departament/empleat i `leave_type` (Fase 1.4).
- `attendance_absence_requests` amb flux complet: sol·licitud → aprovació → decrement entitlement → event calendari (Fase 1.5). Dissenyada compatible amb `approval_requests` genèric.
- `attendance_monthly_reports` + Edge Function `generate-attendance-report` (Fase 0b.3).
- Màquina d'estats completa amb cas crash/pausa no tancada i `max_duration_minutes` (Fase 2.1).
- Triggers d'automatització: `PAUSE_NOT_CLOSED`, `PUNCH_OUT_MISSING`, `OVERTIME_THRESHOLD_EXCEEDED`, `MONTH_CLOSED_REPORT`, `ABSENCE_REQUEST_PENDING` (Fase 6).
- Vista materialitzada `mv_today_site_status` (Fase 4).

**El que afegeix aquest document al pla v3 (SÍ cal incorporar):**
- `tenant_absence_type_configs` — catàleg configurable del comportament legal de cada tipus d'absència (`counts_as_worked`, `affects_entitlement`, `requires_document`). El pla v3 té `leave_type` com a text lliure; cal formalitzar-lo.
- **Seed de sistema** (`is_system = true`) dels tipus legals mínims (defunció, matrimoni, IT malaltia, IT accident laboral, IT maternitat/paternitat, permís parental, urgència familiar, revisió mèdica empresa, visita mèdica personal) — el pla v3 no especifica quins tipus existeixen per defecte.
- **Absència parcial dins jornada vs. pausa** — la visita mèdica personal NO és una pausa de descans: pot ser retribuïda o no (depenent del conveni), pot afectar entitlements, i hauria de generar una `attendance_absence_requests` parcial, no un `break_start/end`. Decisió clau: treure `medical_personal` de `tenant_pause_configs` i moure-la a `attendance_absence_requests` com a `partial_start_time`/`partial_end_time`. Cal decidir i documentar.
- **Seed de pauses per defecte diferenciat per arquetip** (el pla v3 no especifica valors inicials per arquetip; veure secció 3.1 d'aquest document).
- **Registre definitiu d'absències aprovades** — confirmar si `attendance_absence_requests` actua tant de sol·licitud com de registre definitiu (un cop `status: approved`), o si cal una taula `employee_absences` separada com a registre immutable post-aprovació.
- Confirmar si cal una taula `pause_sessions` (par `break_start`/`break_end` com a entitat) o si `time_punches` és suficient per als càlculs del recompute.

### 5.2 Decisions a prendre i documentar

1. **Pauses com a camps a `time_punches` vs. taula `pause_sessions`:** El pla actual usa `break_start`/`break_end` com a `punch_type` a `time_punches`. Funciona per a pauses simples, però fa difícil calcular la durada d'una pausa sense LEAD/LAG. Una taula `pause_sessions (id, employee_id, punch_in_id, punch_out_id, pause_config_id, start_at, end_at, duration_min)` seria més neta per als càlculs. Avaluar i decidir.

2. **Com es gestiona la visita mèdica personal (absència parcial):** L'empleat fa punch_out a les 10h (per la visita), torna a les 12h i fa punch_in. Això genera dos `time_entries` al dia. Al recompute, cal detectar que hi ha un "forat" entre els dos punches i associar-lo a una `employee_absence partial_medical_personal`. Dissenyar el flux UI de com l'empleat (o el manager) registra aquest forat.

3. **IT/Baixa: entrada manual vs. automàtica:** Des de 2023, l'INSS envia les baixes directament a l'empresa. Fins que no s'integri amb INSS (fora d'abast V1), el manager introdueix la baixa manualment. Dissenyar el formulari de registre d'IT a la UI de managers.

4. **Absència que coberta tot el dia i el treballador fitxa igualment:** Pot passar (error de l'empleat, o alguns sistemes permeten fitxar en IT). Definir la regla de precedència: la `employee_absence` activa té prioritat sobre els punches del dia? O és una anomalia que genera alerta?

5. **Seed diferenciat per arquetip:** confirmar si el sistema d'arquetips (`industry_archetypes`) ja té un mecanisme de seed diferenciat per a altres taules (com `templates_seed` o `catalog_seed`) i reaprofitar-lo per a `tenant_pause_configs` i `tenant_absence_type_configs`.

### 5.3 Integració amb sistemes existents

- **Motor d'automatitzacions:** `ABSENCE_APPROVED`, `IT_STARTED`, `IT_CLOSED` com a nous `audit_log` events que poden disparar workflows (ex: IT llarga → notificar RRHH, generar document de gestió de baixa).
- **Sistema de notificacions:** notificar al manager quan una sol·licitud d'absència queda pendent d'aprovació; notificar al treballador quan s'aprova o rebutja.
- **Sistema d'aprovacions genèric (`approval_requests`):** les sol·licituds de vacances i permisos han d'usar el sistema genèric d'aprovacions, no un flux ad-hoc.
- **DMS / plantilles de documents:** el permís per defunció, matrimoni, etc. pot generar automàticament (via automation) un document de registre de permís retribuït signat per l'empleat.
- **Timeline per entitat (empleat):** totes les absències/IT han de generar events a la timeline de l'empleat (`entity_type: 'employee'`).
- **Entitlements (`vacation_entitlements`, Fase 1.3 del pla):** la creació d'una `employee_absence` amb `affects_entitlement: true` ha de descomptar automàticament del `vacation_entitlements` corresponent de l'empleat.

---

## 6. Entregables esperats

1. **Decisió documentada** sobre `pause_sessions` vs. camps a `time_punches`.
2. **Migració SQL** (`YYYYMMDD_attendance_v3_absences.sql`) amb:
   - `data.tenant_pause_configs` (refinada)
   - `data.employee_absences`
   - `data.tenant_absence_type_configs`
   - Seeds de sistema (`is_system = true`) per a tots els tipus d'absència legals
   - Seeds de pauses per defecte per arquetip (si el mecanisme de seed per arquetip existeix)
   - RPCs: `api.request_absence`, `api.approve_absence`, `api.reject_absence`, `api.register_it`, `api.close_it`, `api.list_employee_absences`, `api.get_employee_absence_summary`
3. **Revisió i actualització del `recompute_attendance_worker`** per incloure absències al càlcul de hores.
4. **UI treballador:** component `AbsenceRequestForm` (sol·licitar permís/absència parcial) i visualització d'absències al calendari personal.
5. **UI manager:** llista d'absències pendents d'aprovació, formulari de registre manual d'IT, configuració de tipus d'absència actius per tenant.
6. **Configuració de pauses al tenant-portal** (`/settings/attendance` o equivalent): llistar, crear, editar pauses; canviar `counts_as_work`.
7. **Resum de decisions** — especialment les de punts 5.2.1 a 5.2.5.