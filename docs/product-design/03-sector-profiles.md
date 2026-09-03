# 3. Arquetips i verticals — perfils sectorials i onboarding

> **Nota important**: els noms tipus `electrician` o `dental` que apareixien
> a versions prèvies d'aquest document eren **exemples**, no categories
> tancades. La taxonomia real té dos nivells (vegeu §3.2): **arquetips**
> (pocs i estables) i **verticals** (molts i derivats). El que defineix el
> comportament del producte és l'**arquetip**.

## 3.1 Idea central

El **codi és el mateix per a tots els sectors**. Una **recepta declarativa**
personalitza:

- *Labels* visibles (Client → Pacient / Comensal)
- Camps obligatoris i opcionals del `Contact.metadata` (JSON Schema)
- Mòduls (addons) preactivats
- Plantilles de comunicació (email/SMS/WhatsApp)
- Tipus d'esdeveniments de calendari i durades
- Tipus de projecte/treball per defecte
- Dashboards d'inici (widgets)
- `permission_bundles` per `job_title`
- Catàleg seed (productes/serveis)
- Estructures físiques seed (Sites/Locations/Assets típics)

---

## 3.2 Taxonomia de 2 nivells

```
Archetype (4-7, estables)
   └─ Vertical (N, derivats)
        └─ Tenant config (overrides finals)
```

### Per què 2 nivells

- **Arquetip** = patró de negoci (com es treballa, no què es fa).
  Defineix **el 90% del comportament del producte**: model de cita, ús
  d'expedient, presència de tarifari, treball a camp, RRHH formal, etc.
- **Vertical** = nínxol comercial. Hereta tot de l'arquetip i només aporta:
  labels específiques (\"Pacient\" vs \"Client\"), camps `metadata` propis del
  nínxol, plantilles de comunicació amb to sectorial, catàleg seed.

Així:
- L'**arquetip és pocs i ben mantingut** (el codi de la startup els coneix).
- Els **verticals són molts i barats** d'afegir (només data, no codi).
- El client final no escull \"arquetip\" — escull el **vertical** que li
  sona (\"Sóc fisioterapeuta\"). El sistema sap que això mapeja a l'arquetip
  `practice` i aplica les seves regles.

---

## 3.3 Catàleg d'arquetips proposats (V1)

| Arquetip | Patró de negoci | Verticals típics |
|---|---|---|
| **`field_service`** | Professional/equip que es desplaça al lloc del client. Cita curta, treball facturat per hores/serveis. Eina principal: agenda + cat. de serveis + obres. | Electricista, lampista, persianista, fontaner, tècnic d'electrodomèstics, climatització, jardiner, neteja a domicili, manyà, antenista, instal·lador de panells solars |
| **`practice`** | Professional rep el client en un local propi en cita programada. Hi ha **expedient** del client (historial). Recordatoris crítics. | Dentista, fisioterapeuta, podòleg, psicòleg, metge, veterinari, òptica, logopeda, nutricionista, advocat, gestoria, assessor fiscal, notari (light) |
| **`hospitality`** | Servei al públic en un local amb capacitat limitada i **rotació ràpida** (hores). Reserves o assignació de torns/taules. Forta plantilla. | Restaurant, bar, cafeteria, sala d'esdeveniments, catering amb sala |
| **`lodging`** | Estades **multi-dia** amb **check-in / check-out**, ocupació d'un recurs (habitació, parcel·la, apartament) durant un període. Tarifa per nit, calendari de disponibilitat, neteja entre estades, possible host taxa turística. | Hotel petit, B&B, casa rural, càmping, apartaments turístics, alberg, coliving curt |
| **`appointment_walkin`** | Mix de cites amb possibilitat de walk-in. Servei prestat al local en sessió curta. RRHH visible (qui ha atès). | Perruqueria, barbería, estètica, manicura, spa, gimnàs (PT), tatuatge |
| **`workshop_maker`** | Producció pròpia + venda + servei postvenda. Cat. de productes + estoc lleuger + intervencions a camp. | Fusteria, serralleria, taller mecànic, marbreria, vidrieria, retolació, fabricant a mida, taller de bicicletes, taller informàtic |
| **`retail_light`** | Venda directa amb mostrador (no és el nostre core) — només si demanda real. POS és el rei aquí; nosaltres complementem amb CRM/agenda. | Botiga de barri amb cita prèvia (boutique, joieria, llibreria especialitzada) |
| **`generic`** | Fallback. Cap supòsit. | Consultor freelance, projectes ad-hoc, pre-onboarding |

> **Decisió**: V1 implementem **`field_service`, `practice`, `hospitality`,
> `workshop_maker`, `generic`**. `lodging` i `appointment_walkin` queden
> com a esborranys per V2 (cada un té patrons clarament diferents que
> mereixen el seu arquetip propi en lloc de forçar-los dins els altres).

### Diferències estructurals entre arquetips

| Tret | field_service | practice | hospitality | lodging | workshop_maker |
|---|---|---|---|---|---|
| Treball al lloc del client | ✅ | ❌ | ❌ | ❌ | parcial (postvenda) |
| Local propi crític | ❌ | ✅ | ✅ | ✅ | ✅ |
| Expedient del client | mínim | **central** | mínim | mínim (preferences) | mínim |
| Catàleg productes | només serveis | només serveis | mínim (POS extern) | tarifes per nit + extres | **productes + serveis** |
| Estoc | ❌ | ❌ | ❌ | ❌ (amenities lleugeres) | ✅ light |
| RRHH formal V1 | ❌ | parcial | ✅ | ✅ (incl. neteja) | parcial |
| Capacitat/recursos limitats | ❌ | sí (boxes/agenda) | ✅ (taules) | ✅ (habitacions, multi-dia) | sí (línia muntatge) |
| Rotació del recurs | — | hores | hores | **dies** (check-in/out) | dies/setmanes |
| Recordatoris massius | ✅ | ✅✅ (no-show car) | ✅ | ✅ (pre-arrival, post-stay) | parcial |

Aquestes diferències són les que **realment justifiquen un arquetip diferent**.
Si dos verticals tenen la mateixa fila a aquesta taula, són el mateix arquetip.

---

## 3.4 Estructura proposada (data model)

### `data.industry_archetypes` (catàleg, gestionat per la startup)

```
id                  text PK         -- 'field_service', 'practice', ...
name_i18n           jsonb           -- { ca: 'Servei a camp', es: '...', en: '...' }
description_i18n    jsonb
icon                text
labels              jsonb           -- defaults per Contact, Project, Event, Site...
contact_schema      jsonb           -- JSON Schema base de contact.metadata
default_addons      text[]
default_event_types jsonb
default_project_types jsonb
default_dashboards  jsonb
permission_bundles  jsonb           -- bundles funcionals base
default_sites_seed  jsonb           -- estructura física suggerida
default_catalog_seed jsonb          -- 0-N items inicials
defaults_metadata   jsonb           -- altres valors per defecte
is_active           bool
```

### `data.industry_verticals` (catàleg gestionat per la startup, ampliable)

```
id                  text PK         -- 'electrician', 'plumber', 'dentist', 'physio', ...
archetype_id        text FK → industry_archetypes
name_i18n           jsonb           -- "Electricista", "Lampista", "Dentista"
description_i18n    jsonb
icon                text
labels_overrides    jsonb           -- només el que difereix de l'arquetip
contact_schema_extension jsonb      -- camps addicionals del nínxol
templates_seed      jsonb           -- plantilles amb to del nínxol
catalog_seed        jsonb           -- serveis/productes típics del nínxol
keywords            text[]          -- per cerca al wizard ("autonom", "obres", "manteniment")
is_active           bool
sort_order          int
```

### `data.tenant_sector_config` (assignació + overrides per tenant)

```
tenant_id          uuid PK
archetype_id       text FK
vertical_id        text FK         -- pot ser NULL (vertical 'custom')
overrides          jsonb           -- el tenant fa fine-tuning
applied_at         timestamptz
```

### Resolució (capes, baix→alt prioritat)

```
config_efectiu(tenant) =
    archetype.defaults
  ⊕ vertical.overrides
  ⊕ tenant.overrides
```

(`⊕` = deep merge amb prioritat dreta).

---

## 3.5 Exemples de mapeig vertical → arquetip

| Vertical (el que el client tria) | Arquetip | Diferència respecte arquetip |
|---|---|---|
| `electrician` | field_service | catàleg seed de serveis elèctrics, etiquetes \"Obra\" |
| `plumber` (lampista) | field_service | catàleg seed de serveis lampisteria |
| `solar_installer` | field_service | catàleg amb instal·lacions, vertical sovint multi-dia |
| `hvac_tech` | field_service | catàleg manteniments periòdics |
| `dentist` | practice | metadata expedient dental, plantilles odontologia |
| `physio` | practice | metadata anamnesi muscular, sessions de 45min |
| `psychologist` | practice | metadata confidencialitat reforçada, sessions setmanals |
| `vet` | practice | metadata: pacient és l'animal + tutor humà (relació especial) |
| `lawyer` | practice | metadata: cas, jurisdicció, terminis |
| `restaurant` | hospitality | reserves amb party_size, taules com a Assets |
| `bnb_small` | lodging | habitacions com a Assets, estades multi-dia, check-in/out |
| `rural_house` | lodging | propietat sencera com a Asset, estades multi-dia |
| `small_hotel` | lodging | habitacions, neteja entre estades, taxa turística |
| `campsite` | lodging | parcel·les com a Assets |
| `furniture_maker` | workshop_maker | catàleg productes a mida + instal·lació |
| `bike_shop_repair` | workshop_maker | productes botiga + reparacions amb diagnòstic |
| `carpenter` | workshop_maker | producció + intervencions a camp |

**Punt clau**: si demà arriba el \"persianista\" o el \"tècnic d'aspiradors
robot\", **no toquem codi**. Afegim una fila a `industry_verticals` apuntant
a `field_service` amb el seu catàleg seed i ja tenim un onboarding nou.

---

## 3.6 Receptes per arquetip (esborrany)

> Aquestes receptes són **per arquetip**, no per vertical. El vertical
> només n'aporta el to (etiquetes, plantilles, catàleg seed).

### `generic` (fallback)
- Labels: Contact = Client, Project = Projecte, Event = Cita.
- Sense camps obligatoris extra.
- Addons: calendar, reminders, dms.
- Sense bundles (només rols jeràrquics).

### `field_service`
- Labels: Contact = Client, Project = Obra, Event = Visita.
- Suport actiu de **`ContactSite`** (clients amb diversos locals/comunitats).
- Contact metadata: `tax_id?`, `billing_address?`, `notes`.
- Addons: calendar, reminders, dms, work_orders, expenses, **catalog (serveis)**.
- Event types: `visit` (30min), `quote` (60min), `installation` (multi-day),
  `maintenance`.
- Bundles: `tecnic`, `admin`, `comercial`.
- Dashboard: avui (visites) + pendents de cobrar + pressupostos oberts.
- **Tier-aware**: si el tenant és Tier A (solo) → no activa departments,
  no mostra bundles a la UI; si és Tier B (3-15p) → activa departments
  i mostra funcions.

### `practice`
- Labels: Contact = **Pacient/Client** (el vertical decideix), Project =
  **Tractament/Cas/Expedient**, Event = Cita.
- Contact metadata: `birthdate?`, `gender?`, `id_document?`,
  `emergency_contact?`. **El vertical estén** amb camps clínics o legals.
- Addons: calendar, reminders, dms, **records** (expedient genèric),
  **consents**.
- Event types: `first_visit`, `followup`, `treatment`, `block`.
- Bundles: `professional` (doctor/advocat/psicòleg…), `assistant`,
  `reception`, `admin`.
- DMS folders inicials per Contact: `Documents`, `Consentiments`,
  **Abast**: només F&B i esdeveniments (rotació ràpida en hores). Hotels
  i allotjaments multi-dia van a `lodging`.
- Labels: Contact = Comensal, Project = Esdeveniment, Event = Reserva.
- Locations: sales/zones. Assets = taules amb `capacity`.
- Contact metadata: `allergens[]?`, `preferences?`, `vip?`, `source?`.
- Addons: calendar (booking), reminders, dms, hr, employees, shifts.
- Event types: `reservation` (party_size, table_id), `private_event`,
  `staff_shift`, `cleaning_block`.
- Bundles: `staff`, `head_staff`, `kitchen`, `floor_manager`.
- Templates: confirmació, recordatori 2h, no-show, post-visita.

### `lodging` *(V2 — esborrany)*
- Labels: Contact = Hoste, Project = Estada, Event = Reserva (rang de
  dies, no hores).
- Sites: una propietat. Locations: plantes/edificis.
- Assets = habitacions / parcel·les / apartaments amb `capacity` i
  `nightly_rate_cents`.
- Contact metadata: `id_document`, `nationality?`, `birthdate?` (regulació
  hostatgeria), `preferences?`, `vip?`.
- Addons: calendar (booking multi-dia), reminders (pre-arrival, post-stay),
  dms (escanejos DNI), employees, shifts, **`channel_manager`** (V2.5,
  pont amb Booking/Airbnb), **`tourist_tax`** (càlcul auto).
- Event types: `stay` (start/end date, guest count), `cleaning_block`,
  `maintenance_block`, `staff_shift`.
- Bundles: `reception`, `housekeeping`, `maintenance`, `lodging_admin`.
- Templates: confirmació, pre-arrival (instruccions), check-in,
  post-stay (review), no-show.
- **Diferenciadors clau** que justifiquen separar de hospitality:
  - Disponibilitat per **rang de dies**, no per slot d'hora.
  - Bloqueig automàtic d'`Asset` durant tota l'estada.
  - **Neteja entre estades** com a esdeveniment de primera classe.
  - Documentació obligatòria del client (DNI/passaport).
  - Possibles integracions amb canals externs (channel manager).
  - Tarifa variable (temporada alta/baixa)hifts.
- Event types: `reservation` (party_size, table_id), `private_event`,
  `staff_shift`, `cleaning_block`.
- Bundles: `staff`, `head_staff`, `kitchen`, `floor_manager`.
- Templates: confirmació, recordatori 2h, no-show, post-visita.

### `workshop_maker`
- Labels: Contact = Client (sovint B2B), Project = Comanda/Obra,
  Event = Intervenció.
- Sites del tenant: `workshop` + `office`. Locations dins workshop:
  `recepció`, `producció`, `magatzem`, `expedicions`.
- Contact metadata: `tax_id` (req B2B), `billing_address` (req),
  `payment_terms_days?`. **`ContactSite` actiu** (clients amb seus
  múltiples).
- Addons: calendar, reminders, dms, work_orders, expenses,
  **catalog (productes + serveis)**, **stock_lite**, employees (light).
- Departments seed: `Producció`, `Servei tècnic`, `Comercial/Admin`.
- Project types: `quote`, `order`, `installation`, `maintenance`, `repair`.
- Event types: `intervention`, `delivery`, `internal_task`.
- Bundles: `tecnic_taller`, `tecnic_camp`, `comercial`, `administracio`,
  `cap_servei`.
- **Cas diferenciador (ja descrit a doc 02)**: `Asset` venut s'enregistra
  al `ContactSite` del client → historial postvenda nadiu.

---

## 3.7 Procés d'onboarding (revisat)

```
1. Sign-up → crea tenant base (provision_tenant)
2. Wizard pas 1: «Què fas?»
     - Cerca lliure ("escric el meu ofici")  → matching contra verticals.keywords
     - Cards d'arquetips si no hi ha match
     - Sempre disponible "Ho configuro després" → vertical='generic'
3. Wizard pas 2: nom del negoci, telèfon, logo
4. Wizard pas 3: zona horària, idioma, canal de comunicació preferit
5. Wizard pas 4: tier? "Sóc jo sol" vs "Som un equip" → preset Tier A/B
6. Wizard pas 5 (Tier B): invitar 1r company (opcional)
7. Aplicar recepta atòmica (vegeu §3.8)
8. Redirigir a /today amb tour guiat de 3 passos
```

### Detall del pas 1

- **Cerca first**: l'usuari sap millor el seu ofici que la nostra
  taxonomia. Una cerca text amb suggeriment top-3 dels millors verticals
  és més humà que un dropdown.
- Si l'ofici no surt, l'usuari pot **demanar-lo** (form simple → cua de
  noves verticals per a la startup) i mentrestant continua amb l'arquetip
  més proper.
- Mai obliguem a triar (skip → `generic`).

---

## 3.8 RPC d'aplicació de recepta

Una única transacció `api.apply_sector_recipe(p_tenant_id, p_archetype_id, p_vertical_id?, p_tier text)`:

```
BEGIN
  INSERT/UPDATE tenant_sector_config
  Resol config efectiva (archetype ⊕ vertical ⊕ tier_adjustments)
  Activar default_addons (data.tenant_addons)
  Clonar plantilles d'email seed → data.email_templates
  Crear default_event_types
  Crear default_project_types
  Crear sites seed (si tenant no en té cap útil)
  Crear catalog seed
  Crear DMS folders seed (per Contact si aplica per arquetip)
  Crear permission_bundles efectius a referència
  Aplicar tier_adjustments (Tier A oculta departments, etc.)
  Audit: SECTOR_RECIPE_APPLIED
COMMIT
```

Idempotent: cridable diversos cops sense duplicar (UPSERT amb
`source='recipe_seed'`).

---

## 3.9 Editabilitat posterior

- El tenant pot **canviar labels** (`overrides.labels`).
- El tenant pot **estendre** `contact_schema` afegint camps propis.
- **Canviar vertical** (mateix arquetip): segur. Reaplicaria seeds nous
  sense esborrar dades.
- **Canviar arquetip**: desaconsellat. Avís fort. Permès però no toca
  dades existents.
- **Promoure de Tier A a Tier B**: 1-clic (activa departments + bundles
  visibles). Reversible.

---

## 3.10 Multi-sector dins un mateix tenant

**V1: NO.** Un tenant = un arquetip + un vertical. Si calgués (clínica
amb cafeteria interna), s'usen tags i projects.

V2 podria estudiar **un vertical per Site** (no arquetip), però només si
hi ha demanda concreta i clara. La complexitat de tenir labels diferents
per Site és alta.

---

## 3.11 Governança del catàleg

- Els arquetips evolucionen poc → canvis amb migració de dades, RFC intern.
- Els verticals s'afegeixen sovint → procés simple:
  1. Detectar via cua de \"vertical demanat\" (vegeu §3.7).
  2. Decidir arquetip pare.
  3. Insert al catàleg amb seeds (labels, plantilles, catàleg).
  4. Sense desplegament: nous tenants ja el veuen al wizard.
- **Versionat dels seeds**: cada vertical porta `seed_version`. Els
  tenants existents poden \"actualitzar seeds\" si volen (no automàtic
  per evitar trepitjar configuracions seves).

---

## 3.12 Decisions a tancar

1. **Verticals iniciables al llançament**: limitar a 6-8 ben acabats per
   no diluir-se. Resta s'afegeixen segons demanda real.
2. **\"Vertical custom\"** per Tier A: oferim plantilla buida amb 3 toggles
   (\"Treballes a casa del client?\", \"Tens local propi?\", \"Vens producte?\")
   que dedueix l'arquetip? → **Sí, és valuós i evita encallar-se**.
3. **Bundles són per arquetip o per vertical?** → **Per arquetip**. El
   vertical només pot afegir alguns bundles propis si realment són
   diferents (rar). Mantenir simple.
4. **Pot un vertical pertànyer a >1 arquetip?** → **No.** Si dubte, és
   senyal que falta arquetip o que el vertical està mal definit.
5. **Vertical sense arquetip pare**: prohibit. `archetype_id NOT NULL`.
