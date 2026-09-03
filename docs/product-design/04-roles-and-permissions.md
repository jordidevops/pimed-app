# 4. Rols, permisos i identitats

## 4.1 Model actual (recordatori del que ja hi ha)

- **4 rols jeràrquics**: `owner` > `manager` > `member` > `viewer`.
- **Scope dual**: rol global per tenant **o** específic per site
  (`tenant_members.site_id IS NULL` vs `NOT NULL`).
- **Permisos granulars** ja implementats a `data.get_role_permissions()` i
  injectats al JWT com a `app_metadata.user_permissions`:
  ```
  user_permissions = {
    "<tenant_id>": {
      "global_permissions": ["..."] | ["*"],
      "sites": { "<site_id>": { "permissions": [...] } }
    }
  }
  ```
- **Personalització per tenant** a `data.tenants.metadata.role_permissions`.
- **`owner`** té wildcard `["*"]`.
- **Funció font de veritat**: `data.jwt_user_tenants()` (JWT + fallback cache).

Aquesta base és sòlida. El que segueix només **afegeix capes** sense tocar el
que ja funciona.

---

## 4.2 Les tres capes d'identitat

Abans de parlar de permisos, deixem clares les **tres identitats** que poden
existir al sistema. Confondre-les és l'origen del 90% dels problemes RBAC en
ERP/CRM:

| Capa | Què és | Té login? | Cost de llicència? | Exemple |
|---|---|---|---|---|
| **Auth User** (`auth.users`) | Identitat global del sistema | Sí | — | Una persona pot pertànyer a N tenants |
| **TenantMember** | Vincle Auth User ↔ Tenant amb rol+permisos | Sí (heretat) | **Sí** | Owner electricista; cambrer amb app |
| **Employee** | Persona contractada (RRHH) | Opcional | **No** (per defecte) | Cuiner sense mòbil; aprenent que rota |
| **Contact** (no és identitat interna) | Client/pacient/comensal | No (V1) | No | El pacient del dentista |

### Regles d'or

1. **Empleat ≠ Usuari.** Es vinculen via `employee.user_id` (opcional).
2. **Llicència = TenantMember actiu**, no Employee. Si cobrem per "seat",
   crear empleats és gratis; donar-los login es factura.
3. **Contact mai té permisos d'app**. Si necessita interactuar
   (confirmar cita, veure pressupost) → **share_link signat temporal**.
4. **L'Auth User no porta rol**. El rol viu sempre en el vincle TenantMember.

---

## 4.3 Eixos de permís

Un permís efectiu d'un usuari sobre una acció concreta es resol creuant
**5 eixos**:

```
1. Tenant      → A quin tenant pertany l'acció?
2. Site        → Global o limitat a un site?
3. Funció      → job_title → permission_bundle
4. Recurs      → contacts, projects, calendar, documents…
5. Visibilitat → all | own | department | team
```

L'eix 5 (visibilitat) és el que sovint falta a CRM petits i fa que un
recepcionista vegi historials mèdics que no hauria de veure.

---

## 4.4 Job title funcional ≠ rol jeràrquic

El rol jeràrquic (`owner/manager/member/viewer`) defineix **autoritat**.
El job title defineix **funció** dins el sector.

### Per què calen tots dos

- Dos cambrers poden ser tots dos `member` però només un d'ells és
  `head_waiter` amb permís sobre la caixa.
- Un dentista i una recepcionista són tots dos `member`, però veuen coses
  radicalment diferents.
- L'`owner` sempre és `owner` independentment del seu títol.

### Implementació proposada (mínima)

```sql
ALTER TABLE data.tenant_members
  ADD COLUMN job_title text;          -- clau opaca: 'doctor', 'waiter', ...
```

- Els valors vàlids vénen del `sector_profile.permission_bundles` (catàleg
  controlat per sector).
- Quan canvia el `job_title`, els permisos efectius es recalculen i s'injecten
  al JWT en el següent refresh.
- El tenant **no crea bundles propis en V1** (anti-overengineering). Pot
  afegir/treure permisos individuals com a *override* (ja suportat via
  `data.tenants.metadata.role_permissions`).

### Resolució final de permisos d'un usuari

```
permisos_efectius =
    permisos_base_del_rol_jeràrquic
  ∪ permisos_del_bundle(job_title, sector_profile)
  ∪ overrides_del_tenant
  − denials_del_tenant   (V1.5: només si demanda real)
```

`owner` continua sent wildcard `["*"]`.

---

## 4.5 Catàleg de recursos i accions (extens)

Mantenim el patró `<recurs>.<acció>`. Llista actualitzada per cobrir tots
els nous mòduls (Contacts, Catalog, ContactSites, Employees, Projects, etc.):

### Bàsics (transversals)
```
contacts.{view_all, view_own, edit, delete, export, merge}
contact_sites.{view, edit, delete}
projects.{view_all, view_own, view_dept, edit, delete, change_status}
tasks.{view, edit, delete, assign, complete}
calendar.{view_all, view_own, edit, delete, manage}
documents.{view, upload, edit, delete, share, sign}
notes.{view, edit, delete}
communications.{view, send, send_marketing}
```

### Catàleg / vendes
```
catalog.{view, edit, delete}
catalog.prices.{view_cost, edit_price}      -- diners → restringit
stock.{view, adjust}                         -- només si stock_lite actiu
quotes.{create, send, accept_on_behalf}      -- són Project amb estat
orders.{view, manage}
```

### RRHH
```
employees.{view, edit, delete}
employees.payroll.{view, edit}               -- molt sensible, separat
employees.documents.{view, upload}
shifts.{view_all, view_own, edit}
absences.{view_all, view_own, request, approve}
```

### Administració del tenant
```
members.{view, invite, edit_role, remove}
sites.{view, create, edit, delete}
departments.{view, edit}
settings.{view, edit}
permissions.{view, manage}                   -- editar bundles/overrides
billing.{view, edit}                         -- subscripció SaaS pròpia
audit.{view, export}
integrations.{view, connect, disconnect}
```

### Sectorials (només quan l'addon corresponent està actiu)
```
clinical.records.{view_all, view_own_patients, edit}
clinical.consents.{request, view}
reservations.{view, manage, no_show_mark}
field.work_logs.{start, stop, view_all, view_own}
```

### Convenció de wildcards
- `contacts.*` concedeix totes les accions de contactes.
- `*` només per `owner`.
- Per a vistes ràpides al frontend, exposem helper `hasAny('contacts.view_all', 'contacts.view_own')`.

---

## 4.6 Permission bundles per **arquetip** (esborrany)

> Els bundles són **per arquetip** (`field_service`, `practice`,
> `hospitality`, `lodging`, `workshop_maker`, `generic`), no per vertical
> concret. Vegeu [03-sector-profiles.md](03-sector-profiles.md) per a la
> taxonomia arquetip→vertical. Els exemples d'oficis (doctor, cambrer,
> tècnic…) són **noms suggerits** que el tenant pot renombrar; el que
> importa és el conjunt de permisos del bundle.

Cada `industry_archetype` declara els bundles disponibles. El tenant els
assigna per `job_title`. Els bundles **són additius sobre el rol jeràrquic**
— mai el substitueixen.

### `generic`
- *(sense bundles obligatoris; només rols jeràrquics)*

### `field_service` *(Tier A o B; ex: electricista, lampista, fontaner…)*
| Bundle | Pensat per | Permisos addicionals (sobre `member`) |
|---|---|---|
| `tecnic` | Operari/ajudant que va a obres | `field.work_logs.start/stop`, `documents.upload`, `notes.edit`, `tasks.complete` |
| `comercial` | Qui fa pressupostos i parla amb clients | `contacts.*`, `quotes.create/send`, `catalog.view`, `calendar.edit` |
| `admin` | Administració/oficina | `quotes.*`, `catalog.edit`, `billing.view`, `employees.view` |

### `practice` *(ex: dentista, fisio, advocat, veterinari…)*
| Bundle | Permisos clau |
|---|---|
| `professional` | `records.edit` (expedient genèric), `contacts.view_own` (els seus clients), `documents.upload`, `quotes.create` |
| `assistant` | `records.view_all`, `calendar.edit`, `documents.upload` |
| `reception` | `contacts.view_all`, `calendar.manage`, `communications.send`, **NO** `records.*` |
| `practice_admin` | tot l'anterior + `billing.view`, `employees.view` |

*Nota*: per al vertical `dentist` el permission key real és
`clinical.records.*` (alias de `records.*` quan l'addon `clinical` està
actiu). Per al vertical `lawyer` serà `legal.records.*`. És un detall
d'addon, no de bundle.

### `hospitality` *(ex: restaurant, bar, cafeteria, sala d'esdeveniments…)*
| Bundle | Permisos clau |
|---|---|
| `staff` | `reservations.view/manage`, `calendar.view_all`, `contacts.view_all` |
| `head_staff` | `staff` + `reservations.no_show_mark`, `shifts.view_all` |
| `kitchen` | `calendar.view_all` (només lectura), `notes.view`, **res** de contactes |
| `kitchen_staff` | `shifts.view_own`, `notes.view` |
| `floor_manager` | tot el bloc operatiu + `employees.view`, `audit.view` |

### `lodging` *(V2 — esborrany; ex: hotel petit, B&B, casa rural, càmping…)*
| Bundle | Pensat per | Permisos clau |
|---|---|---|
| `reception` | Recepció / front desk | `reservations.*` (incl. multi-dia), `contacts.*`, `documents.upload` (escanejos DNI/passaport), `communications.send`, `tourist_tax.view` |
| `housekeeping` | Equip de neteja | `calendar.view_all` (només `cleaning_block` i `stay`), `tasks.complete`, `notes.edit` (estat habitació), **res** de contactes ni billing |
| `maintenance` | Manteniment intern | `assets.view`, `tasks.complete`, `documents.upload`, `field.work_logs.start/stop` (intern) |
| `lodging_admin` | Direcció | tot l'anterior + `billing.view`, `employees.view`, `tourist_tax.manage`, `channel_manager.configure`, `audit.view` |

*Notes específiques de `lodging`*:
- `reservations.*` aquí implica **rang de dies** i bloqueig automàtic
  d'`Asset` (habitació/parcel·la) durant l'estada.
- `documents.upload` és **més sensible** que en altres arquetips (porta
  documentació d'identitat per regulació hostatgeria) → `housekeeping`
  no l'ha de tenir.
- `tourist_tax.*` i `channel_manager.*` són permisos d'addons V2 (vegeu
  doc 03 §3.6 i doc 06).

### `workshop_maker` *(ex: fusteria, serralleria, taller mecànic…)*
| Bundle | Permisos clau |
|---|---|
| `tecnic_taller` | `tasks.complete`, `stock.adjust`, `documents.upload`, `field.work_logs.start/stop` (al taller) |
| `tecnic_camp` | `field.work_logs.*`, `contact_sites.view`, `documents.upload`, `notes.edit` |
| `comercial` | `contacts.*`, `quotes.create/send`, `catalog.view`, `calendar.edit` |
| `administracio` | `billing.view`, `employees.view`, `quotes.accept_on_behalf`, `audit.view` |
| `cap_servei` | tot el bloc operatiu + `members.invite` (limitat) |

### Format al `industry_archetypes.permission_bundles`

```jsonb
{
  "professional": {
    "label_i18n": { "ca": "Professional", "es": "Profesional", "en": "Professional" },
    "applies_to": ["member"],            -- rol jeràrquic compatible
    "permissions": ["records.edit", "contacts.view_own", "documents.upload"],
    "scope_hints": { "contacts": "own" } -- pista per UI/RLS
  }
}
```

---

## 4.7 Visibilitat: `all` vs `own` vs `dept`

Aquest és l'eix més oblidat i el que evita escàndols de privacitat.

| Sufix | Significat | Implementació RLS |
|---|---|---|
| `view_all` | Veu tots els registres del tenant/site | Pertinença tenant + site OK |
| `view_own` | Només els que té assignats (`owner_user_id = auth.uid()`) o creats (`created_by = auth.uid()`) | Filtre per columna |
| `view_dept` | Els que toquen el seu `department_id` | Comprovació `department_id` del membre |
| `view_team` | (V2) Equips ad-hoc per projecte (ja `project_members`) | `EXISTS` sobre taula pivot |

### Regla d'agregació
Si un usuari té `view_all` i `view_own` simultàniament, mana **el més ampli**.
Això simplifica les polítiques i és el que l'usuari espera intuïtivament.

### Casos resolts

| Cas | Combinació |
|---|---|
| Doctor només els seus pacients | `contacts.view_own` + `contact.owner_user_id = doctor` |
| Recepcionista veu tots els pacients però no historials | `contacts.view_all` + cap `clinical.records.*` |
| Cambrer veu agenda completa del seu site, no d'altres locals | `calendar.view_all` amb scope=site |
| Cuiner només el seu torn | `shifts.view_own` |
| Tècnic de camp només les obres assignades | `projects.view_own` (assignee/project_member) |
| Administració restaurant veu ingressos només del seu site | `billing.view` scope=site |

---

## 4.8 Permisos especialment sensibles

Permisos que **no** s'inclouen mai per defecte en cap bundle i requereixen
acció explícita de l'`owner`:

- `employees.payroll.*` (salaris, IBANs)
- `clinical.records.*` (dades de salut → RGPD reforçat)
- `billing.edit` (canvi de pla, mètodes de pagament)
- `permissions.manage` (escalada de privilegis)
- `audit.export` (informació històrica massiva)
- `integrations.connect` (token tercers)
- `members.edit_role` (escalada de privilegis)

Cada concessió d'aquests genera un `audit_log` amb `severity='high'` (camp
nou suggerit, V1.5).

---

## 4.9 Convidats / clients amb portal lleuger

Casos: veure butlletí d'intervenció, confirmar activitat, descarregar artefactes
autoritzats, dashboard client (Fase B).

Font de veritat: [`13-customer-portal-architecture.md`](./13-customer-portal-architecture.md)
i pla [`docs/plans/custom-portal/README.md`](../plans/custom-portal/README.md).

### Fase A — Share de butlletí (sense compte)
- Bearer token 256-bit (hash a BD), sessió BFF opaca al `apps/customer-portal`.
- Scope: versió immutable + persona destinatària; no dashboard.
- Auditoria i rate limit fail-closed obligatoris.
- Els `share_links` DMS genèrics **no** són el vehicle del butlletí d'intervenció.

### Fase B — Portal client persistent
- Identitat: `auth.users` (magic link; `shouldCreateUser` controlat a la invitació).
- Autoritat: `customer_access_grants` live per
  `(auth_user_id, tenant_id, customer_account_contact_id, person_contact_id)`.
- El navegador **no** rep ni usa JWT Supabase contra PostgREST; només cookie BFF.
- Una persona pot ser membre intern d'un tenant i client d'un altre alhora.

### Decisió corregida (no `app_role='customer'` escalar)
Un `app_role='customer'` exclusiu a `app_metadata` **no** és viable: no modela
doble persona (intern + client) i empeny a confondre autorització amb un claim
global. Es conserva `auth.users`; els grants live són l'autoritat.

### Anti-patterns explícits
- **No** crear `tenant_members` per a clients (llicència, audit, RLS).
- **No** confiar només en `jwt_has_permission` / claims obsolets per publicar o
  compartir dades de tercers (usar comprovació fresh de membresia/permís).
- **No** deixar que un JWT customer-only accedeixi a views/RPC internes
  concedides a `authenticated` (gate de membre intern al tenant-portal abans
  de CP-B).
- **No** comptar clients contra `plans.max_members`.

---

## 4.10 Per Tier d'usuari: experiència

### Tier A (solo)
- A la UI no es mostra el concepte de bundles ni job_titles.
- Tots els membres convidats reben `member` i un job_title `tecnic` o `admin`
  prefixat.
- L'owner pot canviar permisos individualment des d'una vista simple
  ("Què pot fer en Joan?") amb 8-10 toggles, no 50.

### Tier B (micro)
- Vista de "Funcions" (job_titles) com a entrada principal.
- Bundles ja vénen del sector. El tenant nomès assigna persones a funcions.
- Vista avançada "Permisos detallats" amagada darrere d'un toggle.
- Plantilles d'invitació per funció (genera missatge i preassigna bundle).

---

## 4.11 Multi-tenant per usuari

Ja suportat. Mantenir. Notes per al disseny:

- **Tenant switcher** al frontend ja existent — assegurar que el switcher
  refresca el JWT (recarrega `user_permissions`).
- Un Auth User pot tenir job_titles **diferents** a tenants diferents
  (és recepcionista en una clínica i propietària d'un altre negoci).
- Les sessions són per Auth User, no per tenant: el switcher canvia el
  *context actiu*, no l'autenticació.

---

## 4.12 Auditoria de canvis RBAC

Tots aquests events han d'anar a `data.audit_logs` amb `entity_type` adequat:

| Action | entity_type | Severity |
|---|---|---|
| `MEMBER_INVITED` | tenant_member | normal |
| `MEMBER_ROLE_CHANGED` | tenant_member | high |
| `MEMBER_JOB_TITLE_CHANGED` | tenant_member | normal |
| `MEMBER_REMOVED` | tenant_member | high |
| `MEMBER_PERMISSION_GRANTED` | tenant_member | high |
| `MEMBER_PERMISSION_REVOKED` | tenant_member | normal |
| `EMPLOYEE_HIRED` | employee | normal |
| `EMPLOYEE_TERMINATED` | employee | high |
| `EMPLOYEE_LINKED_TO_USER` | employee | normal |
| `BUNDLE_OVERRIDE_APPLIED` | tenant | high |
| `SHARE_LINK_CREATED` | share_link | normal |
| `SHARE_LINK_ACCESSED` | share_link | low |

Camp `severity` és proposta nova V1.5 — actualment no existeix a
`audit_logs`. Permet construir un "panell de seguretat" sense recórrer tot
l'històric.

---

## 4.13 Decisions a tancar

1. **Job_title valors**: enum global o text lliure? → **Text lliure** validat
   contra `sector_profile.permission_bundles` via trigger. Permet evolució
   sense migracions.
2. **Empleat sense user té algun "permís implícit"?** → No. Si mai cal,
   passa per Auth User i TenantMember `viewer`.
3. **Owner pot delegar `permissions.manage`?** → Sí, però sempre queda un
   owner (no es pot remoure el darrer owner). Trigger ja existeix; verificar.
4. **Quan canvia un bundle del sector_profile (que és global), què passa amb
   tenants amb overrides?** → Els overrides prevalen. Els tenants veuen un
   avís "El sector ha actualitzat aquest bundle, vols sincronitzar?".
5. **Permisos negatius (denials)?** → No V1. Si demanda, V1.5 amb prioritat
   sobre concessions.
6. **`view_own` per Contact: assignació individual o per equip?** → V1
   individual (`contact.owner_user_id`). V2 podria afegir
   `contact.owner_team_id` lligat a Department.

---

## 4.14 Resum executiu

- La base RBAC actual (rols jeràrquics + scope per site + permisos granulars)
  **es manté intacta**.
- Afegim **`job_title` a `tenant_members`** lligat a bundles del sector.
- Afegim **eix de visibilitat** (`view_all` / `view_own` / `view_dept`) als
  permisos més usats.
- **Empleat ≠ Usuari** queda formalitzat com a tres capes d'identitat.
- **Convidats externs sempre via share_link** en V1.
- Catàleg de permisos s'estén per cobrir Contacts, Catalog, ContactSites,
  Employees, Reservations, Clinical i Field Service.
- **Bundles per sector** són la palanca de personalització UI: el tenant
  pensa en "funcions", no en permisos.
