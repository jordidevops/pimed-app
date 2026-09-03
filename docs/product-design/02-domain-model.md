# 2. Model de domini bàsic

Aquí descrivim **les entitats genèriques** que sustenten qualsevol sector.
Cap entitat és sectorial. El sector només aporta *labels* i *metadata*.

## 2.1 Mapa d'entitats

```
Tenant
 ├─ Site                       (local propi, clínica, restaurant, "general")
 │   ├─ Location (arbre)       (sala, box, taula, zona, línia de muntatge)
 │   └─ Asset                  (unitat dental, forn, vehicle, eina, màquina)
 ├─ Department (arbre)         (organització lògica)
 ├─ TenantMember (= User+Role) (usuari amb login)
 ├─ Employee                   (persona contractada, pot tenir o no User)
 ├─ Contact                    (client, pacient, comensal, lead, proveïdor)
 │   └─ ContactSite (opcional) (adreces/locals del client on intervenim)
 ├─ Catalog                    (productes i serveis venuts pel tenant)
 │   ├─ Product                (item físic, configurable o no)
 │   └─ Service                (intervenció estàndard amb preu)
 ├─ Project                    (obra, cas clínic, esdeveniment, comanda)
 │   ├─ Task
 │   ├─ Line (project_lines)   (línies de catàleg consumides/venudes)
 │   └─ WorkLog
 ├─ CalendarEvent              (cita, reserva, recordatori, bloc)
 ├─ Document (DMS)             (expedient, contracte, foto, factura)
 ├─ Note                       (apunt lliure polimòrfic)
 └─ Communication              (email/SMS/WhatsApp enviat o rebut)
```

### Distinció important: Site del tenant vs ContactSite

- **`Site`** = local/seu **del tenant** (on treballem nosaltres).
- **`ContactSite`** = adreces/locals **del client** on anem a intervenir.
  Exemple: el taller fabrica al seu workshop (`Site`) i va a instal·lar a la
  fàbrica del client (`ContactSite`). Això evita explotar `data.sites` amb
  adreces de tercers i manté RLS net.
- Un `Project` o `CalendarEvent` pot referenciar `site_id` (on treballem) i
  opcionalment `contact_site_id` (on s'executa físicament).

V1 mínim: `data.contact_sites { id, contact_id, name, address, geo, notes }`.
No cal jerarquia de locations dins el client en V1.

Totes les entitats porten `tenant_id` i (quan aplica) `site_id`.
Totes les polimòrfiques porten el seu propi `tenant_id`/`site_id` per RLS
**sense JOIN al pare**.

## 2.2 Contact — la peça clau no implementada

És el "client universal". Substitueix la temptació de fer `patients`,
`diners`, `customers` separats.

| Camp | Tipus | Notes |
|---|---|---|
| `id`, `tenant_id`, `site_id?` | uuid | site opcional (un contacte pot ser global) |
| `kind` | enum: `person` \| `company` | |
| `display_name` | text | calculat o introduït |
| `given_name`, `family_name` | text? | per `person` |
| `legal_name`, `tax_id` | text? | per `company` |
| `email`, `phone`, `phone_alt` | text? | normalitzats E.164 |
| `preferred_channel` | enum: `email` \| `sms` \| `whatsapp` \| `none` | per recordatoris |
| `tags` | text[] | classificació lliure |
| `metadata` | jsonb | **camps específics del sector** (validats per JSON Schema) |
| `source` | text? | "web", "referral", "import" |
| `owner_user_id` | uuid? | qui el "porta" |
| `consent_*` | bool + timestamp | RGPD: marketing, recordatoris |
| `is_archived` | bool | soft delete |

**Validació de `metadata`**: cada `sector_profile` defineix un JSON Schema.
Un trigger `data.validate_contact_metadata()` el valida abans d'INSERT/UPDATE.
Així el dentista no pot crear un pacient sense `birthdate`, però l'electricista
no es veu obligat a omplir-ho.

### Subtipus, no taules separades

*(Exemples — els noms d'ofici són verticals derivats d'arquetips, vegeu
[03-sector-profiles.md](03-sector-profiles.md).)*

- **Pacient** = Contact + metadata `{birthdate, insurance, allergies, …}`
- **Client field-service** = Contact + metadata `{billing_address, iban?}`
- **Comensal recurrent** = Contact + tag `recurrent` + metadata `{preferences, allergens}`
- **Proveïdor** = Contact amb tag `supplier`
- **Lead** = Contact amb tag `lead` i sense `consent_marketing` confirmat

### Relacions entre contactes — quan i com

**Problema real**: hi ha casos on un Contact "actor" no és el mateix que
el Contact "qui paga / qui rep comunicacions / qui dona consentiment":

- **Veterinari**: el pacient és l'animal, el responsable és el tutor humà.
- **Dentista pediatre / pediatra**: el pacient és un menor, els pares
  signen consentiments i reben recordatoris.
- **B2B field-service**: el client és una empresa (Contact `company`) i
  el contacte operatiu és una persona física (Contact `person`) que treballa
  per ella.
- **Advocat**: cas amb diverses parts (client, contrari, perit…).

**Decisió V1**: NO creem `contact_relationships` encara. Resolem amb el
mínim necessari:

1. **Per al cas "qui paga / qui rep"**: dos camps opcionals al propi
   `Contact`:
   - `billing_contact_id uuid? → contacts.id` (qui rep factures)
   - `primary_contact_id uuid? → contacts.id` (qui rep comunicacions si
     el contacte principal no és contactable: menor, animal, empresa)
2. **Per al cas vet/pediatre**: el `Contact` del pacient/animal té
   `kind='person'` amb `metadata.is_dependent=true` i
   `primary_contact_id` apuntant al tutor. RLS i comunicacions usen el
   tutor automàticament.
3. **Per al cas B2B (empresa+persona)**: el Contact `company` té una llista
   de Contacts `person` mitjançant `employer_contact_id` (camp opcional al
   Contact persona). És una relació N:1 simple, no necessita taula
   intermedia en V1.

**Quan promoure-ho a `data.contact_relationships` (V2+)**:
- Quan calgui **N:M amb tipus** (un menor amb dos tutors, un cas legal
  amb múltiples parts amb rols diferents).
- Quan calgui **historiar** la relació (data inici/fi: "va ser tutor de
  X fins al 2027").
- Quan els addons clínic/legal demanin ròtuls de relació específics
  ("pare", "mare", "germà", "contrari", "perit…").

Esquema previst per quan toqui:
```
data.contact_relationships {
  id, tenant_id, from_contact_id, to_contact_id,
  kind text,            -- 'tutor', 'employer', 'parent', 'spouse', 'opponent', 'expert'
  is_primary bool,      -- el principal per comunicacions
  starts_on date?, ends_on date?,
  metadata jsonb
}
```

## 2.3 Employee ≠ User — revisitat

**Decisió: són entitats separades, vinculables.**

| Aspecte | TenantMember (User) | Employee |
|---|---|---|
| Té login? | Sí (auth.users) | Pot ser que no |
| Què representa | Identitat digital + permisos | Persona contractada (RRHH) |
| Casos | Owner, manager, cambrer amb app | Cuiner sense mòbil, cambrer extra de cap de setmana |
| Dades | rol, permisos, sites | contracte, salari, IBAN, document ID, hores, vacances |
| Cicle de vida | Invitació → activació → revocació | Alta → contracte → baixa |

### Per què separat

1. **Cost de llicència**: si cobrem per usuari, no volem forçar a crear login a
   un cuiner que no toca l'app.
2. **RRHH ≠ accés**: l'autònom electricista *ell mateix* és el TenantMember
   (owner). Els seus 2 ajudants potser només són Employee per RRHH/nòmines.
3. **Privacitat**: dades laborals/salarials no han de viure barrejades amb
   identitat d'auth.

### Vincle

`employee.user_id uuid? REFERENCES auth.users(id)` — opcional. Una vista
`api.workforce` les uneix per UI.

### Què hi ha d'haver a Employee (V1 mínim, sense overengineering)

- Identitat: `full_name`, `document_id` (DNI/NIE), `birthdate`, `email`, `phone`
- Laboral: `job_title`, `department_id?`, `start_date`, `end_date?`, `status`
- Contractual: `contract_type` (text lliure V1), `weekly_hours`
- Pagaments: `iban?` (xifrat), `payment_method`
- `metadata jsonb` per extensions (talles, idiomes, certificacions…)
- `documents` via DMS polimòrfic (`entity_type='employee'`)

V2 afegiria torns, fitxatges (work_logs ja serveix), nòmines (ext o integració),
absències.

## 2.4 Polimorfisme controlat

Entitats que poden penjar-se de qualsevol pare:

| Entitat | `entity_type` típics |
|---|---|
| Document | `contact`, `project`, `task`, `employee`, `asset`, `work_log` |
| Note | `contact`, `project`, `asset`, `employee` |
| CalendarEvent | `contact`, `project`, `task`, `employee` (torn) |
| Communication | `contact`, `project` |

**Regla d'or**: cada una porta el seu `tenant_id` i `site_id?` propis i RLS
*no* fa cap JOIN al pare. Així evitem l'infern del polimòrfic.

## 2.5 Catalog (Products + Services) — primitiva nova

Necessària per al sector taller fabricant i útil per a tots:

- L'electricista vol un catàleg de **serveis tarifats** ("Hora oficial 1a:
  45€", "Visita: 30€") per fer pressupostos ràpids.
- El dentista té un **tarifari de tractaments**.
- El restaurant pot tenir una carta lleugera (V2; el POS és l'autoritat).
- El taller té **producte propi** amb SKU, preu, opcionalment estoc i fitxa
  tècnica.

### `data.catalog_items` (V1 mínim)

| Camp | Notes |
|---|---|
| `id`, `tenant_id`, `site_id?` | site opcional (catàleg per local) |
| `kind` | enum: `product` \| `service` |
| `sku` | text? únic per tenant |
| `name`, `description` | i18n al `metadata` si cal |
| `unit` | text (`u`, `h`, `m`, `kg`, …) |
| `price_cents`, `currency`, `tax_rate_pct` | preu de venda públic |
| `cost_cents?` | per marge (privat) |
| `is_stockable` | bool (només `product`) |
| `stock_qty?` | numeric (V1: camp simple, sense moviments) |
| `metadata` | jsonb (fitxa tècnica, atributs configurables) |
| `is_active` | bool |

### `data.project_lines` (línies d'un projecte/comanda/pressupost)

Polimòrfic lleuger sobre `Project`:
`{ project_id, catalog_item_id?, description, qty, unit_price_cents, tax_rate_pct, line_total_cents }`

Això ens permet:
- Pressupostos i comandes sense crear taules `quotes`/`orders` separades.
- L'estat del Project (`draft`/`quoted`/`accepted`/`in_progress`/`done`)
  governa el cicle.
- Posteriorment, generar factura via integració amb facturador.

### Estoc — abast V1

Només `stock_qty` en el propi item, decrementat quan es marca un
`project_line` com a *consumit* (trigger simple) i incrementat quan es
*compra* (entrada manual). **No**: lots, ubicacions múltiples, reserves,
movements log. Si algun sector ho necessita seriosament → integració amb
un mini-WMS o salt a Holded/Odoo per aquell flux concret.

## 2.6 El que **no** modelem (encara)

- Stock/inventari profund (lots, sèries, ubicacions, moviments) → no V1.
  Només `stock_qty` simple (vegeu §2.5).
- Comptabilitat de doble partida → no, integrem.
- BOM/MRP → no és el nostre target.
- Workflow engines configurables → no (anti-pattern declarat al projecte).
