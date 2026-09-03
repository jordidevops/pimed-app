# Pla — Import i sincronització d'empleats (EI)

> **Data:** 2026-07-02 (v1) · actualitzat 2026-07-17  
> **Estat:** pla operatiu — MVP CSV ✅ · **EHR-7 CSV V2 ✅** (2026-07-21); **EI3+ en cua** (Holded/PayFit deferits fins a client pilot)  
> **Índex:** [README.md](./README.md)

### Progrés per fase

| Fase | Estat | Notes |
|------|-------|-------|
| **EI0** Contracte canònic + match | ✅ | `employeeImportTypes.ts` + helpers SQL |
| **EI1** Import CSV | ✅ | `api.import_employees_bulk` + UI Empleats |
| **EI2** `external_entity_mappings` | ✅ | Taula + vista + enllaços a fitxa |
| **EI3** Framework connectors | 🧊 | En cua (EX-08 tancat) |
| **EI4** Holded inbound | 🧊 | En cua — cal compte pilot |
| **EI5** PayFit inbound | 🧊 | En cua |
| **EI6** Re-sync + auditoria | 🧊 | En cua |

---

## Resum executiu

**Problema:** els clients tenen empleats a Holded, PayFit, A3, Sage o Excel de gestoria. Avui a PiMed només hi ha **alta manual** (`EmployeesPage` → `api.employees`). Sense importació, hi ha doble entrada i l'export de nòmina (D3.1) falla si el NIF no coincideix.

**Solució:** capa d'**import inbound** amb tres canals, per ordre de valor:

1. **CSV universal** — qualsevol sistema (inclou A3/Sage sense API).
2. **Mapping d'IDs externs** — per re-sync i connectors API.
3. **Connectors Holded / PayFit** — API key per tenant (BYO).

**Principis:**

1. **PiMed no és el màster de nòmina** — importem des del sistema que el client ja usa; no empènyem empleats cap a Holded/PayFit en V1.
2. **Un empleat = una fila** a `data.employees`; IDs externs a taula separada (no contaminar el core).
3. **Match determinista** — mapping existent → NIF → email → crear nou (amb confirmació UI).
4. **Idempotent** — reimportar el mateix CSV o re-sync no duplica.
5. **Independent** del pla genèric `docs/plans/api/` i de `stripe_holded` (facturació).

**MVP usable:** EI0 + EI1 + EI2 (~3–5 dies).  
**Integració SaaS:** + EI3 + EI4 o EI5 (~5–8 dies cadascun).

---

## Context: què tenim avui

| Component | Estat |
|-----------|-------|
| `data.employees` + `api.employees` | ✅ CRUD manual |
| Camps: `full_name`, `document_id`, `email`, `phone`, `site_id`, `department_id`, `weekly_hours`, `status`, `metadata` | ✅ |
| Import CSV empleats | ❌ |
| `external_entity_mappings` | ❌ (només proposat a docs) |
| Export nòmina amb `document_id` | ✅ D3.1 |
| Connectors Holded/PayFit employees | ❌ |

**Conseqüència:** el client ha d'alinear NIF manualment perquè l'export encaixi amb A3/Sage/Holded.

---

## Mapa de fonts externes

| Font | Direcció habitual | Canal recomanat | API empleats |
|------|-------------------|-----------------|--------------|
| **CSV / Excel** | Extern → PiMed | EI1 | No cal |
| **Gestoria / A3 / Sage** | Export llista treballadors → CSV | EI1 | D3.2 WK ⏸️ posposat (D3.1 CSV actiu) |
| **Holded** | Holded → PiMed (màster ERP) | EI4 (+ EI1 pont) | ✅ REST employees |
| **PayFit** | PayFit → PiMed (màster nòmina) | EI5 (+ EI1 pont) | ✅ collaborators (API key client) |
| **Alta manual** | — | Actual | — |

**Export nòmina (sortida)** resta al track D3 (`payroll_export_profiles`); aquest pla és només **entrada** d'empleats.

---

## Índex de fases

| ID | Tema | Prioritat | Esforç |
|----|------|-----------|--------|
| **EI0** | Contracte canònic + algorisme de match | P0 | XS |
| **EI1** | Import CSV (UI + RPC bulk) | P0 | M |
| **EI2** | Taula `external_entity_mappings` | P0 | S |
| **EI3** | Framework connectors (credencials, test, sync run) | P1 | M |
| **EI4** | Provider Holded | P1 | M |
| **EI5** | Provider PayFit | P2 | M–L |
| **EI6** | Re-sync programat + logs | P2 | M |

Ordre recomanat: **EI0 → EI2 → EI1 → EI3 → EI4** (Holded abans PayFit si cal triar) **→ EI5 → EI6**.

---

# EI0. Contracte canònic i match — P0, XS

**Objectiu:** un tipus TypeScript i un document de camps mínims compartits per CSV, Holded i PayFit.

### Model canònic (`EmployeeImportRecord`)

```typescript
interface EmployeeImportRecord {
  external_id?: string          // id al sistema origen (opcional en CSV pur)
  provider?: string             // 'csv' | 'holded' | 'payfit' | ...
  full_name: string
  document_id?: string | null   // NIF/NIE — clau principal export nòmina
  email?: string | null
  phone?: string | null
  job_title?: string | null
  status: 'active' | 'inactive' | 'terminated'
  starts_on?: string | null     // ISO date
  ends_on?: string | null
  weekly_hours?: number | null
  site_external_ref?: string | null   // codi local extern (opcional)
  department_external_ref?: string | null
  metadata?: Record<string, unknown>  // SS, conveni, codi Sage, etc.
}
```

### Algorisme de match (per fila importada)

```
1. Si (provider, external_id) existeix a external_entity_mappings → UPDATE employee
2. Sinó si document_id normalitzat coincideix amb employee del tenant → UPDATE + crear mapping
3. Sinó si email normalitzat coincideix → UPDATE + mapping (ambigüitat: avís si NIF diferent)
4. Sinó → CREATE employee (+ mapping si hi ha external_id)
```

**Normalització NIF:** majúscules, sense espais/guions.  
**Normalització email:** trim + lowercase.

### Mapatges per proveïdor (esborrany)

| Camp canònic | CSV (columnes acceptades) | Holded API | PayFit API |
|--------------|---------------------------|------------|------------|
| `full_name` | `full_name`, `nombre`, `name` | `name` | `firstName` + `lastName` |
| `document_id` | `document_id`, `nif`, `dni` | camp fiscal / identificador | dades personals contracte |
| `email` | `email`, `correo` | `email` | `email` |
| `status` | `active`/`inactive`/`terminated` | estat employee | estat contracte |
| `external_id` | columna opcional `external_id` | `id` Holded | `collaboratorId` |

### Criteris d'acceptació

- [ ] Fitxer `employeeImportTypes.ts` (o equivalent) amb contracte + mapatges.
- [ ] Document de columnes CSV d'exemple (CA) a `docs/help/empleats/import-csv.md` (creat en implementar EI1).
- [ ] Regles de match documentades i testables en unit tests.

---

# EI1. Import CSV — P0, M

**Objectiu:** qualsevol client pot pujar un CSV i importar/actualitzar empleats sense API.

### UX (tenant-portal)

**Ubicació:** `Empleats` → botó **Importar CSV**.

Flux:

1. Descarregar **plantilla CSV** (capçaleres recomanades + fila exemple).
2. Pujar fitxer (`.csv`, separador `;` o `,` detectat).
3. **Previsualització:** taula amb acció per fila: Crear / Actualitzar / Omitir / Error.
4. Resolució de conflictes (mateix email, NIF diferent) amb decisió explícita.
5. Confirmar → crida RPC → toast amb resum: `X creats, Y actualitzats, Z errors`.
6. Opcional: guardar `external_id` + `provider='csv'` a mappings si la columna existeix.

### Backend

**RPC proposada:**

```sql
api.import_employees_bulk(
  p_rows jsonb,              -- array EmployeeImportRecord
  p_options jsonb DEFAULT '{}'  -- { dry_run, default_site_id, update_mode }
)
RETURNS jsonb  -- { created, updated, skipped, errors: [{ row, code, message }] }
```

- `SECURITY DEFINER`, validació `attendance.manage` o permís nou `employees.manage`.
- Transacció per fila (o batch amb savepoints) per no perdre tot si una fila falla.
- Audit: `EMPLOYEE_IMPORTED` / `EMPLOYEE_IMPORT_UPDATED` a `tenant_operation_logs` o audit existent.

**Alternativa V1:** mutació client amb loop `upsert` — descartada per rendiment i consistència; preferir RPC.

### Plantilla CSV mínima

```csv
full_name;document_id;email;phone;job_title;status;starts_on;weekly_hours;external_id
"Joan Garcia";12345678A;joan@empresa.com;600000000;Electricista;active;2024-01-15;40;HOLD-abc123
```

### Casos A3 / Sage

- La gestoria exporta llista de treballadors (format variable).
- El client (o nosaltres) defineix **perfil de columnes** reutilitzant lògica de `payroll_export_profiles` **inversa** (futur EI1.1) o mapping manual a la previsualització.
- **V1:** plantilla fixa + document «adapta el teu Excel a aquestes columnes».

### Criteris d'acceptació

- [ ] Import 50 empleats en < 10 s en local.
- [ ] Re-import del mateix fitxer → 0 creats, N actualitzats (idempotent per NIF).
- [ ] Errors per fila no bloquegen la resta.
- [ ] Només owner/manager pot importar.
- [ ] Traduccions CA a `locales/ca/employees.json`.

---

# EI2. `external_entity_mappings` — P0, S

**Objectiu:** relacionar `employees.id` amb IDs Holded/PayFit/CSV sense tocar `data.employees`.

### Migració SQL (esborrany)

```sql
CREATE TABLE data.external_entity_mappings (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  provider      text NOT NULL,   -- 'holded' | 'payfit' | 'csv' | 'a3' | 'sage' | ...
  entity_type   text NOT NULL DEFAULT 'employee',
  internal_id   uuid NOT NULL,   -- employees.id
  external_id   text NOT NULL,
  external_meta jsonb NOT NULL DEFAULT '{}',
  last_synced_at timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT external_entity_mappings_unique
    UNIQUE (tenant_id, provider, entity_type, external_id),
  CONSTRAINT external_entity_mappings_internal_unique
    UNIQUE (tenant_id, provider, entity_type, internal_id)
);

-- FK opcional: internal_id → employees(id) ON DELETE CASCADE
```

- Vista `api.external_entity_mappings` amb `security_invoker`.
- RLS: SELECT per membres del tenant; WRITE per `attendance.manage` o `employees.manage`.
- GRANT sobre `data.*` (patró D3.1).

### UI

- A la fitxa empleat: secció **«Enllaços externs»** (provider + external_id, només lectura V1).
- A import/sync: crear/actualitzar mapping automàticament.

### Criteris d'acceptació

- [ ] Un empleat pot tenir mapping Holded **i** PayFit simultanis (providers diferents).
- [ ] Eliminar empleat → CASCADE mapping.
- [ ] No es pot duplicar `external_id` per provider dins el tenant.

---

# EI3. Framework connectors — P1, M

**Objectiu:** infraestructura comuna per Holded/PayFit sense copiar `docs/plans/api/` sencer.

### Taula credencials (àmbit **només RRHH/nòmina**, no facturació)

```sql
CREATE TABLE data.tenant_hr_connectors (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  provider        text NOT NULL,  -- 'holded' | 'payfit'
  credentials     jsonb NOT NULL, -- xifrat aplicació o referència vault; mai API key en clar al client
  config          jsonb NOT NULL DEFAULT '{}',
  is_active       boolean NOT NULL DEFAULT true,
  last_test_at    timestamptz,
  last_test_ok    boolean,
  last_sync_at    timestamptz,
  last_sync_error text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  UNIQUE (tenant_id, provider)
);
```

**Nota:** nom diferent de `tenant_integrations` genèric (doc 06) per mantenir aquest pla **independent**; es pot fusionar més endavant.

### Interfície provider (TypeScript)

```typescript
interface HrImportProvider {
  id: 'holded' | 'payfit'
  testConnection(credentials): Promise<{ ok: boolean; message?: string }>
  listEmployees(credentials): Promise<EmployeeImportRecord[]>
}
```

### UI

**Configuració → Control horari** (o nova subsecció **«Connexions RRHH»**):

- Connectar Holded / PayFit (API key + botó «Provar connexió»).
- «Importar empleats ara» → mateixa previsualització que EI1.
- Estat: últim sync, error, nombre mapejats.

### RPC

```sql
api.sync_employees_from_provider(
  p_provider text,
  p_dry_run boolean DEFAULT false
) RETURNS jsonb  -- mateix shape que import_employees_bulk
```

Implementació: Edge Function o RPC PL/pgSQL que delega — preferir **Edge Function** per crides HTTP a Holded/PayFit (secrets fora de Postgres).

### Criteris d'acceptació

- [ ] API keys no apareixen en logs ni respostes client.
- [ ] Test connexió sense importar dades.
- [ ] Sync reutilitza EI0 match + EI2 mappings.

---

# EI4. Connector Holded — P1, M

**Objectiu:** importar empleats des de Holded API.

### API (referència)

- `GET /api/v2/employees` — llista
- `GET /api/v2/employees/{id}` — detall
- Autenticació: header `key: {API_KEY}`

### Mapping Holded → canònic

| Holded | Canònic |
|--------|---------|
| `id` | `external_id` |
| `name` / camps nom | `full_name` |
| identificador fiscal | `document_id` |
| `email`, `phone` | directe |
| estat actiu | `status` |
| contracte actiu (endpoint contract) | `weekly_hours`, `starts_on` (EI4.1 si cal segona crida) |

### Flux

1. Tenant configura API key (EI3).
2. «Importar des de Holded» → Edge Function fetch → `EmployeeImportRecord[]`.
3. Previsualització (EI1 UI compartida).
4. Confirmar → `import_employees_bulk` + mappings `provider='holded'`.

### Decisions

- **No** sincronitzar clock-in/out cap a Holded en aquest pla (veure estudi Holded_Payfit).
- V1 només **inbound** employees.

### Criteris d'acceptació

- [ ] Prova amb compte Holded sandbox (quan el client obri compte pilot).
- [ ] Empleat nou a Holded → apareix a previsualització com «Crear».
- [ ] Empleat existent per NIF → «Actualitzar» + mapping.

---

# EI5. Connector PayFit — P2, M–L

**Objectiu:** importar collaborators des de PayFit.

### Restriccions externes (2025–2026)

- **Partner marketplace pausat** per noves integracions.
- Clients amb pla avançat poden usar **API key pròpia** (`developers.payfit.io`).
- Endpoints: `GET collaborators`, dades contracte per hores/alta.

### Mapping PayFit → canònic

- `collaboratorId` → `external_id`
- Nom, email, identificador personal segons scopes disponibles a ES
- Estat contracte → `status`

### Flux

Igual que EI4 amb `provider='payfit'`.

### Riscos

| Risc | Mitigació |
|------|-----------|
| Partner tancat | Prioritzar API key BYO del client |
| Camps ES incomplets | EI1 CSV com a fallback |
| Rate limits | Paginació + backoff (doc PayFit) |

### Criteris d'acceptació

- [ ] Funciona amb API key de compte PayFit de prova ES.
- [ ] Documentat quins scopes calen al dashboard PayFit.

---

# EI6. Re-sync programat — P2, M

**Objectiu:** mantenir empleats alineats sense import manual mensual.

### Opcions

| Mode | Descripció |
|------|------------|
| Manual | Botó «Sincronitzar ara» (EI3) |
| Programat | `pg_cron` o job queue: 1×/dia per tenants amb connector actiu |
| Webhook | Holded/PayFit si ofereixen (investigar; no assumir V1) |

### Taula auditoria

```sql
CREATE TABLE data.hr_import_sync_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  provider text NOT NULL,
  direction text NOT NULL DEFAULT 'inbound',
  status text NOT NULL,  -- 'running' | 'success' | 'partial' | 'failed'
  summary jsonb NOT NULL DEFAULT '{}',
  error text,
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz
);
```

### Criteris d'acceptació

- [ ] Log visible a UI connectors (últimes 10 execucions).
- [ ] Fallada API no esborra empleats locals (només update/create).

---

## Permisos

| Acció | Permís proposat |
|-------|-----------------|
| Import CSV / sync | `employees.manage` (nou) o reutilitzar `attendance.manage` V1 |
| Veure mappings | owner, manager, HR |
| Configurar connectors | owner, manager |

**V1 pragmàtic:** reutilitzar `attendance.manage` per no crear permís nou; refactor a `employees.manage` si el mòdul RRHH creix.

---

## UI — mapa de pantalles

```
Empleats/
  ├── Llista (existent)
  ├── Nou / Editar (existent)
  └── Importar CSV (EI1)
        └── Previsualització + confirmació

Configuració → Control horari / Connexions RRHH (EI3)
  ├── Holded — connectar, provar, importar, últim sync
  └── PayFit — idem

Fitxa empleat/
  └── Enllaços externs (EI2) — holded_id, payfit_id
```

---

## Relació amb export nòmina (D3)

```text
IMPORT (aquest pla)          EXPORT (D3.1, fet)
──────────────────          ──────────────────
Holded/PayFit/CSV    →      employees.document_id
       ↓                              ↓
  employees.id              payroll_export_profiles
       ↓                              ↓
  mappings                  CSV A3/Sage/Holded variables
```

**Clau:** sense import (o NIF alineat), l'export pot generar files amb `document_id` que el sistema destí no reconeix.

---

## Fora d'abast (explícit)

- Export / push de variables cap a Holded (`salary-records`) — pla Holded_Payfit fase H2.
- Push absències cap a PayFit — pla Holded_Payfit fase P2.
- Sincronització bidireccional (PiMed → extern com a màster).
- Import de contactes, clients, factures.
- Integració comptable Holded (`docs/plans/stripe_holded/`).
- API partner PayFit marketplace fins reobertura.

---

## Estimació global

| Fase | Dies (ordre magnitud) |
|------|------------------------|
| EI0 + EI2 | 1 |
| EI1 | 2–3 |
| EI3 | 2 |
| EI4 | 2–3 |
| EI5 | 2–4 |
| EI6 | 1–2 |
| **Total MVP (EI0–EI2–EI1)** | **~4–5** |
| **Total amb Holded** | **~8–11** |

---

## Ordre d'implementació recomanat (quan es prioritzi)

1. **EI0 + EI2** — fonaments.
2. **EI1** — valor immediat per tots (A3, Sage, Excel).
3. Validar amb **1 client real** (CSV gestoria).
4. **EI3 + EI4** si el pilot usa Holded.
5. **EI5** quan hi hagi client PayFit amb API key.
6. **EI6** quan el connector sigui estable.

---

##Referències

### Internes

- [`employees_module.sql`](../../../supabase/migrations/20260504000001_employees_module.sql)
- [`employeesService.ts`](../../../apps/tenant-portal/src/features/employees/api/employeesService.ts)
- [Estudi Holded/PayFit](../Holded_Payfit/estudi-integracio-holded-payfit.md)
- [Spike D3 export](../checkin/spike-d3-a3-sage-payroll-export.md)

### Externes

- [Holded API — Employees](https://www.holded.com/developers/api-reference)
- [PayFit API — Collaborators](https://developers.payfit.io/reference/get_collaborators)
- [PayFit — Sync collaborators guide](https://developers.payfit.io/docs/syncing-collaborators.md)

---

## Checklist abans de tancar V1 import

- [ ] Client pilot amb fitxer CSV real importat sense errors crítics.
- [ ] NIFs importats coincideixen amb export D3.1 de prova.
- [ ] Documentació ajuda CA: com preparar CSV des d'Excel / gestoria.
- [ ] Cap secret API en client bundle ni migracions.
