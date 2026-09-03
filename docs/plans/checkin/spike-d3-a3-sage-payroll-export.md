# Spike D3 — Export nòmina A3 / Sage

> **Data:** 2026-07-02  
> **Estat:** spike tancat (recomanació d’implementació)  
> **Relacionat:** [`plan-monthly-close-approval.md`](./plan-monthly-close-approval.md) Track D · D2 `export_payroll_period`  
> **Tipus TS:** `apps/tenant-portal/src/features/attendance/api/payrollConnectorTypes.ts`

---

## Resum executiu

**Ni A3 (Wolters Kluwer) ni Sage 200 / Despachos Connected exposen un fitxer pla universal i estable** per importar registre de jornada des de tercers. El patró dominant en ambdós ecosistemes és:

1. **Plantilles Excel configurables** per empresa / conveni → conceptes variables de nòmina (hores, dies, imports).
2. **Integració nativa** (A3: `a3gestión del tiempo` ↔ nómina amb codis d’incidència; Sage: incidències diàries + conceptes salariales).
3. **API partner** (A3 Conectia) per clients que ja són al stack WK — fora del MVP genèric.

**Recomanació PiMed:** implementar una capa **`payroll_export_profiles`** (mapping tenant) sobre el model canònic D2, amb sortida **CSV/Excel per plantilla**. La integració API directa (**D3.2 Conectia**) queda **posposada** fins validació E2E amb tenant WK (veure secció D3.2 al spike).

---

## Objectius del spike

| Inclòs | Exclòs (post-spike) |
|--------|---------------------|
| Formats reals A3 / Sage (documentació pública) | Connector API en producció |
| Matriu camps nostres → conceptes típics | UI d’editor de plantilles completa |
| Esquema proposat `payroll_export_profiles` | Certificació Wolters Kluwer Marketplace |
| Estratègia per fases D3.1 / D3.2 | Replicar taxonomia PayFit (D4) |

---

## Punt de partida (D2 — ja fet)

RPC `api.export_payroll_period` + UI `PayrollExportButton`:

| Mode | Granularitat | Ús |
|------|--------------|-----|
| `daily` | 1 fila / empleat × dia | Revisió gestor, mapping per incidències diàries |
| `aggregate` | 1 fila / empleat × període | Totals mensuals (hores extra, dies IT, etc.) |

**Camps clau del model canònic** (veure `payrollExportService.ts` i `payrollConnectorTypes.ts`):

- Identificació: `employee_name`, `document_id`, `employee_id`
- Temps: `work_date`, `expected_minutes`, `worked_minutes`, `overtime_minutes`
- Calendari: `day_type`, `holiday_name`, `is_laborable`
- Absències: `absence_type`, `absence_type_name`, `is_it`, `partial_*`
- Estat nòmina: `summary_status`, `needs_review`, `payroll_action`
- Agregat: `total_overtime_minutes`, `it_days`, `absence_days`, `missing_punch_days`, …

Aquest model és **suficient** com a font per connectors; el que falta és la **capa de transformació** cap al format del gestor de nòmina.

---

## A3 (Wolters Kluwer)

### Productes rellevants

| Producte | Rol |
|----------|-----|
| **a3gestión del tiempo** | Control horari / presència (equivalent funcional al nostre mòdul) |
| **a3innuva Nómina** / **a3asesor Nom** | Càlcul nòmina empresa / gestoria |
| **Conectia API** | Integració cloud amb tercers (marketplace / dev portal WK) |

### Com entren les hores / incidències

**Camí 1 — Integració nativa GT ↔ Nómina (recomanat per clients WK)**

- Les incidències tenen **sentit d’exportació** (`GT → Nómina`, `Nómina → GT`, `Cap`).
- Cada tipus porta **codi extern** (p.ex. `14-1` tipus-contingència); si es trenca, no sincronitza.
- Tipus d’hora / marcaje es configuren com a incidències (dies vs hores).
- **Implicació:** un export genèric des d’PiMed **no substitueix** aquest flux si el client ja té GT+nómina WK; cal **API Conectia** o que el client continuï amb GT com a presència.

**Camí 2 — Excel «Conceptos variables» / «Incidencias Excel»**

- Menú nòmina: exportar plantilla Excel → omplir → importar.
- L’estructura de columnes **és configurable per format** (assistent d’exportació); no és un CSV fix.
- Camps típics: codi empresa, codi treballador/NIF, període, **codi concepte**, unitats (hores/dies) o import.
- **Implicació PiMed:** generar un `.xlsx` que coincideixi amb la plantilla que la gestoria ha exportat des d’A3 (mapping per tenant).

Referències: [Incidencias Excel](https://a3responde.wolterskluwer.com/es/s/article/exportar-importar-incidencias-excel), [Variables masivas](https://a3responde.wolterskluwer.com/es/s/article/informacion-masiva-de-variables-en-la-paga-mensual-y-extra), [Integración GT](https://a3responde.wolterskluwer.com/es/s/article/no-se-han-traspasado-las-incidencias).

### Mapping orientatiu A3 (conceptes variables)

| Camp PiMed | Concepte A3 típic | Notes |
|------------|-------------------|-------|
| `total_overtime_minutes` (agregat) | Hores extra / tipus hora configurat | Codi concepte per conveni (no universal) |
| `overtime_minutes` (diari) | Incidència per hores (GT→nómina) | Si la gestoria demana detall diari |
| `worked_minutes` − `expected_minutes` | Hores ordinàries / complementàries | Depèn jornada parcial vs completa |
| `is_it` + dies | IT (incidències sistema ACL, IT, …) | Sovint dies, no hores |
| `absence_type` + `export_code` (C1) | Permisos / vacances / absències | Requereix `export_code` per tenant |
| `missing_punch_days` | Absentisme / revisió manual | Normalment no s’exporta automàtic |

---

## Sage (200 / Despachos Connected)

### Com entren les hores

**No hi ha import directe de «fitxatge brut»** des d’un CSV estàndard. Flux habitual:

1. **Conceptos salariales masivos** — plantilla Excel per empresa.
2. Omplir **cuantía** (hores/dies) i/o **import** per concepte i treballador.
3. **Incorporar incidencias desde plantilla** al mòdul de nòmina.

Perquè les hores surtin al **comunicado de horas** (art. 35.5 ET), cal informar **incidències per conceptes diaris** al empleat (Relaciones → Incidencias empleado).

Referències: [Plantillas Sage 200](https://es-kb.sage.com/portal/app/portlets/results/view2.jsp?k2dockey=230803103900327), [Despachos Connected](https://es-kb.sage.com/portal/app/portlets/results/view2.jsp?k2dockey=230808101623143), [Horas complementarias](https://es-kb.sage.com/portal/app/portlets/results/view2.jsp?k2dockey=230807073842393).

### Mapping orientatiu Sage

| Camp PiMed | Camp plantilla Sage | Notes |
|------------|---------------------|-------|
| `document_id` / codi empleat | Identificador treballador a plantilla | Ha coincidir amb codi Sage |
| `total_overtime_minutes` | Concepte salarial «hores extra» (codi intern empresa) | Codi 798 + concepte propi segons KB |
| `overtime_minutes` per dia | Incidència diària (conceptes diaris) | Per anexo mensual |
| `absence_type` | Concepte absència retribuïda / no retribuïda | Per `export_code` |
| `it_days` (agregat) | Baixa IT | Dies, no minuts |

---

## Comparativa de canals

| Canal | Estabilitat format | Esforç PiMed | Millor per |
|-------|-------------------|--------------|------------|
| CSV genèric D2 | Alta (control nostre) | ✅ fet | Gestories amb ETL propi |
| Excel plantilla A3/Sage | Mitjana (per tenant) | D3.1 | Majoria PYMES ES |
| a3gestión del tiempo + Conectia | API versionada WK | D3.2 L | ⏸️ Posposat — validació E2E WK |
| Holded / PayFit (D4) | Partner-specific | D4 | SaaS nòmina |

---

## Arquitectura proposada (D3.1)

### Taules (esborrany)

```sql
-- Per tenant: perfils d'exportació (A3 variables, Sage plantilla, CSV custom)
data.payroll_export_profiles (
  id uuid PK,
  tenant_id uuid FK,
  name text,                    -- "A3 conceptos variables - Client X"
  connector text NOT NULL,      -- 'a3_variables' | 'sage_concepts' | 'csv_custom'
  output_format text NOT NULL,  -- 'xlsx' | 'csv'
  source_mode text NOT NULL,    -- 'daily' | 'aggregate'
  column_mapping jsonb NOT NULL,-- veure payrollConnectorTypes.ts
  concept_mapping jsonb,        -- export_code / absence_type → codi concepte extern
  header_row int DEFAULT 1,
  is_active boolean DEFAULT true,
  created_at, updated_at
);
```

`column_mapping` exemple:

```json
{
  "columns": [
    { "header": "NIF", "source": "document_id" },
    { "header": "Fecha", "source": "work_date", "format": "dd/MM/yyyy" },
    { "header": "HEX", "source": "concept", "concept_key": "overtime_hours" }
  ]
}
```

`concept_mapping` exemple:

```json
{
  "overtime_hours": { "external_code": "102", "unit": "hours" },
  "it_day": { "external_code": "IT", "unit": "days" },
  "vacation": { "absence_type": "vacation", "external_code": "VA" }
}
```

### RPC proposada

```sql
api.export_payroll_period_profile(
  p_site_id uuid,
  p_from date,
  p_to date,
  p_profile_id uuid,
  p_employee_id uuid DEFAULT NULL
) RETURNS jsonb  -- { filename, mime, content_base64 } o rows preformatted
```

Pipeline:

1. Crida interna a lògica de `export_payroll_period` (ja validada).
2. Aplica `column_mapping` + `concept_mapping`.
3. Genera CSV o delega XLSX (edge function / client) segons `output_format`.

### UI proposada (fase D3.1)

- `/settings/attendance-control` → pestanya **Export nòmina** (o subsecció).
- Llista perfils + «Duplicar plantilla exemple A3 / Sage».
- Editor simple: taula columna destí ↔ camp PiMed (sense Excel upload v1).
- A `PayrollExportButton`: desplegable «CSV genèric» | perfils del tenant.

---

## Fase D3.2 — Conectia / API ⏸️ POSPOSAT

**Estat (2026-07):** integració API **a3innuva Nómina Conectia** posposada fins poder validar el funcionament final en un entorn WK real. **D3.1** (perfils CSV/Excel) cobreix el cas d’ús principal sense subscripció Conectia.

### Per què està posposat

WK no ofereix sandbox públic complet. Per a la primera crida real cal ([como empezar](https://a3developers.wolterskluwer.es/doc/a3innuva-n%C3%B3mina/como-empezar/)):

- Suscripción **a3innuva Nómina Conectia** (Subscription Key)
- Accés a **a3innuva Nómina amb WKA** (usuari del client)
- **Client OAuth** per client (gestionat internament per WK)

Sense això només es pot desenvolupar contra mocks; **no** certificar que incidències/variables arriben a la nòmina.

### Què es pot fer sense desbloquejar D3.2

| Capa | Validació |
|------|-----------|
| D3.1 + C1 | Export CSV/perfils → gestoria importa a A3 (manual) |
| Codi connector (futur) | Unit tests + contract tests amb OpenAPI WK |
| E2E producció | **Requereix** client pilot o tenant demo WK |

### Condició de desbloqueig

- Client pilot WK (Conectia + nómina) **o** credencials demo/partner WK.
- Prova mínima E2E: OAuth → lectura empresa → 1 incidència de prova → verificació a UI a3innuva abans del càlcul.

### Abans del spike (referència)

- Requerir compte desenvolupador Wolters Kluwer + client amb a3innuva.
- Mapping d’incidències amb codis externs (no duplicar GT si el client ja el té).
- **Només té sentit** si el client **no** vol usar PiMed com a presència i només vol passar variables a nómina — poc habitual.

**Decisió spike (original):** no prioritzar D3.2 fins tenir un client pilot WK. **Decisió producte (2026-07):** **posposat explícitament** fins validació E2E.

---

## Riscos i mitigacions

| Risc | Mitigació |
|------|-----------|
| Codi concepte diferent per empresa/conveni | `concept_mapping` per tenant; plantilles duplicables |
| Gestoria demana Excel amb capçaleres custom | `header_row` + mapping per columna, no format fix |
| Export sense dies aprovats | Filtrar `summary_status IN ('approved','exported')` o avís a UI |
| Absències sense `export_code` (C1 pendent) | Fallback a `absence_type` + avís al CSV |
| Confondre A3 «track A3» (UX tancament) amb A3 WK | Documentació: A3 nómina = Wolters Kluwer |

---

## Criteris d’acceptació spike ✅

- [x] Formats A3 i Sage documentats amb enllaços oficials.
- [x] Conclusió: plantilla configurable, no CSV universal.
- [x] Esquema `payroll_export_profiles` proposat.
- [x] Matriu camps PiMed → conceptes externs.
- [x] Fases D3.1 (plantilla) / D3.2 (API) prioritzades.
- [x] Tipus TS `payrollConnectorTypes.ts` com a contracte.

---

## Com funciona (D3.1 implementat)

### Flux per a l’usuari (gestor)

1. **Configuració → Control horari → Export nòmina (perfils)**
   - Afegir **Plantilla A3** o **Plantilla Sage** (o crear un perfil custom).
   - Editar columnes: capçalera del fitxer destí ↔ camp PiMed o `concept_key` (p. ex. `overtime_hours`, `it_day`).
   - Els `concept_mapping` lliguen cada concepte al codi extern del conveni (HEX, IT, etc.).

2. **Fitxatges / revisió nòmina → Export nòmina**
   - Triar **CSV genèric PiMed** (export D2 sense mapping) o un **perfil del tenant**.
   - El perfil aplica `source_mode` (diari o agregat mensual) i genera CSV amb el separador i columnes definits.

### Flux tècnic

```
export_payroll_period (D2)  →  dades canòniques per empleat/dia o agregat
         ↓
export_payroll_period_profile (RPC)  →  valida perfil + retorna payload + mapping
         ↓
payrollProfileExport.ts (client)  →  aplica column_mapping + concept_mapping → CSV
```

### Permisos

| Acció | Permís JWT |
|-------|------------|
| Llistar / exportar amb perfil | `attendance.export` |
| Crear / editar / eliminar perfils | `attendance.manage` (owner/manager) |

La vista `api.payroll_export_profiles` usa `security_invoker`: cal **GRANT** sobre `data.payroll_export_profiles` (no només sobre la vista). Veure migració `20260822000002_payroll_export_profiles_grants.sql`.

### Fitxers clau

- Migració: `supabase/migrations/20260822000001_payroll_export_profiles_d3.sql`
- Tipus / plantilles: `apps/tenant-portal/.../payrollConnectorTypes.ts`
- CRUD perfils: `payrollExportProfileService.ts`, `AttendancePayrollExportProfilesSection.tsx`
- Export amb perfil: `PayrollExportDialog.tsx`, `payrollProfileExport.ts`

---

## Següent pas recomanat (export nòmina)

D3.1 implementat. **D3.2 Conectia:** ⏸️ posposat fins client pilot / demo WK. Següent prioritat export: validar D3.1 amb **gestoria real**; en paral·lel **D4** Holded o altres SaaS.

1. ~~Migració `payroll_export_profiles` + seed 2 perfils exemple~~ ✅
2. ~~RPC `export_payroll_period_profile`~~ ✅
3. ~~UI mínima: triar perfil al export + settings per editar mapping~~ ✅
4. Validar amb **una gestoria real** un fitxer d’exemple abans de prometre compatibilitat.

---

##Referències internes

- `supabase/migrations/20260816000001_payroll_period_export_d2.sql`
- `apps/tenant-portal/src/features/attendance/api/payrollExportService.ts`
- `docs/product-design/17-time-attendance-implementation-plan.md` § Export V1
