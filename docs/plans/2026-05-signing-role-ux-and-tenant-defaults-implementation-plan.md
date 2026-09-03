# Pla d'Implementacio Tecnica: UX de Rols de Document + Defaults de Tenant

Data: 2026-05-28
Estat: En curs (PR1 ✅ PR2 ✅ PR3 ✅ PR4 ✅ PR5 ✅ PR6 pending)
Owner funcional: Product + Startup Operations
Owner tecnic: tenant-portal + migrations + (futur) admin-portal

## 1. Objectiu

Fer que la configuracio de rols de document sigui:
1. Facil d'entendre per usuaris no tecnics o no acostumats a l'angles.
2. Rapida de configurar (1-2 clics en casos habituals).
3. Consistent entre plantilles de sistema i plantilles de tenant.
4. Preparada per auto-omplir rols en generar documents (quasi al vol).

## 2. Resultat esperat

1. En editar un idioma de plantilla, la seccio "Rols de document" explica clarament:
- que es pot usar qualsevol nom de rol,
- que es recomana role key estable en angles,
- i com impacta a la generacio/signatura.
2. L'usuari pot afegir rols des de suggeriments (dropdown + pills) sense escriure-ho tot manualment.
3. Les plantilles de sistema usen role keys estables en angles, mantenint labels localitzades.
4. Cada tenant pot definir defaults per rol + tipus d'entitat i aquests defaults s'apliquen automaticament a l'orquestrador.

## 3. Decisions d'arquitectura

1. Matching de rols per `role_key` (clau tecnica), no per label.
2. `role_key` recomanat en snake_case i angles per estabilitat cross-locale.
3. `label` sempre localitzable i editable (ca/es/en) a nivell de plantilla.
4. Defaults de tenant amb unicitat per combinacio:
- `(tenant_id, role_key, entity_type)`
5. Prioritat de pre-omplert a l'orquestrador:
- `entityContext` (si vens d'una entitat concreta)
- default de tenant
- manual

## 4. Scope

### In Scope (MVP)

1. UX millorada de la seccio "Rols de document" al modal d'edicio de locale.
2. Cataleg base de rols suggerits (cross-vertical + mòduls actuals).
3. Migracio de role keys dels seeds de sistema a angles.
4. Taula de defaults de tenant + auto-aplicacio a DocumentOrchestrator.
5. Nova pagina de Configuracio del tenant: "Plantilles" > "Rols per defecte".

### Out of Scope (post-MVP)

1. Editor complet del cataleg global al admin-portal (UI full CRUD).
2. Defaults per site (ara nomes tenant-level).
3. Inferencia AI de rols.
4. Reescriptura automatica massiva de plantilles legacy fora del flux controlat.

## 5. Cataleg de rols recomanat (v1)

Restrictit als `entity_type` actuals suportats:
- employee, contact, user, person, site, asset, tenant

### Core transversal

1. `worker` -> entity_type: employee -> for_signing: true
- ca: Empleat
- es: Empleado
- en: Worker
2. `manager` -> employee -> true
- ca: Responsable
- es: Responsable
- en: Manager
3. `approver` -> employee -> true
- ca: Aprovador
- es: Aprobador
- en: Approver
- nota: en contextos HR sempre es un empleat; si es un backoffice user el tenant pot usar `user` en una plantilla propia
4. `reviewer` -> employee -> true
- ca: Revisor
- es: Revisor
- en: Reviewer
5. `requester` -> employee -> false
- ca: Sollicitant
- es: Solicitante
- en: Requester
6. `external_party` -> contact -> true
- ca: Part externa
- es: Parte externa
- en: External party
7. `legal_representative` -> user -> true
- ca: Representant legal
- es: Representante legal
- en: Legal representative

### HR

1. `hr_manager` -> employee -> true
2. `direct_manager` -> employee -> true
3. `payroll_responsible` -> user -> false

### Operacions / EAM / CAFM

1. `technician` -> employee -> true
2. `supervisor` -> employee -> true
3. `site_manager` -> user -> true
4. `asset_custodian` -> employee -> false

### Comercial / legal

1. `client_signatory` -> contact -> true
2. `supplier_signatory` -> contact -> true
3. `compliance_officer` -> user -> false

## 6. Implementacio per fases i PRs

## PR1 - UX seccio "Rols de document" (tenant-portal) ✅ IMPLEMENTAT

### Fitxers creats/modificats
- `apps/tenant-portal/src/features/signing/constants/roleCatalog.ts` ← NOU
- `apps/tenant-portal/src/features/signing/components/TemplateFormModal.tsx`
- `apps/tenant-portal/src/locales/ca/signing.json`

Canvis:
1. Bloc d'ajuda desplegable damunt la graella de rols:
- explicacio curta del model `role_key + label`,
- missatge clar "pots usar qualsevol nom de rol",
- recomanacio "si es de sistema, usa key en angles".
2. Pills de suggeriments rapids:
- mostrar nomes rols no afegits,
- click = afegeix fila amb defaults (entity_type, order, for_signing, label).
3. Dropdown de suggeriments al camp `roleName`:
- mantindre input lliure,
- suggerir rols del cataleg segons categoria de plantilla quan disponible.
4. Hints no bloquejants de normalitzacio:
- si detecta nom amb espais/accents, oferir conversio a snake_case.

Nota d'arquitectura del cataleg:
- El cataleg de rols suggerits (per pills/dropdown) viu com a constant TypeScript
  a `apps/tenant-portal/src/features/signing/constants/roleCatalog.ts`.
- Aixo desbloqueja PR1 sense necessitat de DB ni de tenir PR3 fet.
- El PR3 (taula tenant_role_defaults) la consumeix quan l'usuari vol desar un default persistent.

Criteris d'acceptacio:
1. L'usuari pot afegir 3 rols comuns en menys de 30s.
2. No es trenca validacio actual (`^\w+$`).
3. Tots els texts visibles tenen `t('key', 'fallback')`.

## PR2 - Seeds i claus estables de sistema ✅ IMPLEMENTAT

### Fitxers modificats
- `scripts/generate-docx-seed.mjs`

### Mapatge aplicat
| Clau antiga | Clau nova |
|-------------|-----------|
| `Treballador` | `worker` |
| `Responsable_RRHH` | `hr_manager` |
| `Cap_immediat` | `direct_manager` |
| `Supervisor` | `safety_supervisor` |
| `Director_RRHH` | `hr_director` |
| `Director` | `manager` |
| `Responsable_magatzem` | `warehouse_manager` |
| `Cap_obra` | `site_manager` |
| `Cedent` | `transferor` |
| `Receptor` | `recipient` |
| `Responsable` (template 12) | `manager` |

Canvis:
1. Migrar keys localitzades a keys angleses estables.
Exemple:
- `Treballador` -> `worker`
- `Responsable_RRHH` -> `hr_manager`
- `Cap_immediat` -> `direct_manager`
2. Mantenir `label` localitzada per idioma.
3. **Obligatori**: actualitzar `variablesSchema.role` a la mateixa passada que `signingRolesSchema`.
   Ex: `{ role: 'Treballador' }` -> `{ role: 'worker' }`.
   No fer-ho trencaria el matching de variables per rol a l'orquestrador.
4. Afegir mapa de compatibilitat legacy (display only) per ajudar edicio de plantilles antigues.

Criteris d'acceptacio:
1. `node scripts/generate-docx-seed.mjs` funciona.
2. Plantilles de sistema creades amb keys angleses.
3. Sense regressions al render/omplert de variables per rol.

## PR3 - Model de dades defaults de tenant

Objectiu: guardar assignacions per defecte per rol i tipus d'entitat.

Migracio nova (exemple):
1. `supabase/migrations/20260529000001_signing_role_defaults.sql`

DDL proposat:

```sql
create table if not exists data.tenant_role_defaults (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references data.tenants(id) on delete cascade,
  role_key text not null,
  entity_type text not null,
  entity_id uuid,
  entity_label text,
  entity_email text,
  source text not null default 'tenant',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, role_key, entity_type)
);
```

Notes:
1. `entity_id` nullable per permetre entrada parcial (intencio sense assignacio final).
2. Validar `entity_type` contra domini o check consistent amb signing.
3. Afegir trigger `updated_at`.
4. Afegir RLS:
- select per membres del tenant,
- write per owner/manager.
5. Afegir audit event per INSERT/UPDATE/DELETE (ROLE_DEFAULT_CREATED/UPDATED/DELETED).

Regeneracio obligatoria de tipus:
1. `apps/tenant-portal/src/types/database.types.ts`
2. `supabase/functions/_shared/database.types.ts`

Criteris d'acceptacio:
1. UPSERT per `(tenant_id, role_key, entity_type)` funciona.
2. Policies bloquegen usuaris sense permisos.
3. Types generats sense errors.

## PR4 - Auto-aplicacio a DocumentOrchestrator

Objectiu: reduir passos manuals en generar document.

Fitxers principals:
1. `apps/tenant-portal/src/features/signing/components/DocumentOrchestrator.tsx`
2. `apps/tenant-portal/src/features/signing/api/` (hooks nous)

Canvis:
1. Hook `useTenantRoleDefaults(tenantId)`.
2. A `confirmSource()`, en inicialitzar `roleAssignments`, aplicar:
- `entityContext` si coincideix `entity_type`,
- sino `tenant_role_defaults` per `role_key + entity_type`,
- sino buit.
3. No sobreescriure seleccions manuals ja existents.
4. Si default apunta a entitat no disponible, mostrar warning no bloquejant.

Criteris d'acceptacio:
1. Obrint modal des d'empleat: el rol `worker` (employee) queda preomplert amb aquell empleat.
2. Obrint modal generic: s'apliquen defaults de tenant.
3. Sense regressions en flux manual.

## PR5 - Configuracio tenant: pagina "Plantilles"

Objectiu: UI per gestionar defaults sense tocar plantilles una a una.

Fitxers principals:
1. `apps/tenant-portal/src/features/settings/...` (nova pagina)
2. Routing/subnav configuracio
3. Hooks signing defaults

UX minima:
1. Taula de defaults existents.
2. Formulari alta/edicio:
- role_key (text + suggeriments)
- entity_type (select)
- selector d'entitat segons tipus
3. Botons eliminar/restablir.
4. Seccio "Rols de sistema recomanats" amb pills d'alta rapida.

Permisos:
1. owner/manager: write.
2. member/viewer: read-only o ocult.

Criteris d'acceptacio:
1. Es pot crear/editar/esborrar defaults des de UI.
2. Canvis impacten l'orquestrador en temps real (invalidacio query).

## PR6 - End-to-end, observabilitat i rollout

1. Tests manuals E2E:
- Crear locale amb rols suggerits
- Generar document des de modal generic
- Generar document des d'empleat
- Verificar prefills i signants
2. Logging i analytics minima:
- comptador de "role suggestion used"
- comptador de "default applied"
3. Rollout per feature flag opcional si es vol desplegament progressiu.

## 7. Compatibilitat i migracio legacy

Problema:
- hi ha plantilles amb role keys localitzades (ex. `Treballador`).

Estrategia:
1. No trencar lectura de plantilles existents.
2. Mostrar hint al modal si detecta key localitzada coneguda.
3. Oferir boto "normalitzar keys" per convertir a keys angleses de forma assistida.
4. Guardar amb control de conflictes si la key de desti ja existeix.

## 8. Riscos i mitigacions

1. Risc: mismatch entre role key i variables path-based (`{{Role.field}}`).
- Mitigacio: conversio assistida + preview de canvis abans de desar.
2. Risc: defaults stale (`entity_id` ja no existeix).
- Mitigacio: warning + neteja rapida des de UI.
3. Risc: usuaris confonen key i label.
- Mitigacio: ajuda contextual + placeholders i exemples.
4. Risc: creixement de cataleg massa ampli.
- Mitigacio: v1 curt i orientat a mòduls presents; ampliar per iteracions.

## 9. Checklist tecnica per cada PR

1. Lint/typecheck sense errors a tenant-portal.
2. i18n complet en texts nous.
3. RLS validada (cas autoritzat/no autoritzat).
4. Regressio sobre orquestrador sign_docuseal.
5. Si hi ha SQL: regenerar `database.types.ts` als 2 paths oficials.

## 10. Estimacio (ordre de magnitud)

1. PR1 UX modal: 1-2 dies
2. PR2 seeds keys: 0.5-1 dia
3. PR3 migracio + hooks base: 1-2 dies
4. PR4 auto-apply orquestrador: 1 dia
5. PR5 settings page tenant: 3-4 dies (entity pickers + RLS + i18n completa)
6. PR6 validacio i rollout: 1 dia

Total estimat: 7.5-11 dies laborables.

## 11. Seqencia recomanada d'execucio

1. PR1
2. PR2
3. PR3
4. PR4
5. PR5
6. PR6

Aquesta sequencia minimitza regressions i evita propagar role keys inconsistents.
