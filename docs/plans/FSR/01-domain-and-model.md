# FSR — Domini i model de dades

> Part del pack [`README.md`](./README.md).

## Entitats

### `data.menu_items` (nova)

Carta operativa del restaurant. **No** sobrecarregar `catalog_items` (SKU/facturació, sense `site_id`).

| Camp | Notes |
|------|--------|
| `tenant_id`, `site_id` | Obligatoris |
| `section` | entrants / principals / postres / begudes / menú del dia… |
| `name`, `description`, `price` | UI xef, no SKU en primer pla |
| `tax_rate?`, `catalog_item_id?` | Pont opcional a facturació |
| `allergens[]`, `photo_url` | Guest + KDS |
| `prep_time_min`, `station` | `kitchen` / `bar` / `dessert` — base ETA i filtre KDS |
| `day_of_week[]`, `is_menu_dia` | Rotació menú del dia |
| `availability` | `available` / `sold_out` (86 del servei) |
| `is_active` | Soft off de carta |

### Taules de sala — `data.assets` (convenció)

**No** crear `dining_tables`. Reutilitzar assets:

- `metadata.kind = 'dining_table'`
- `metadata.capacity` (int, validat per trigger/CHECK)
- `asset_tag` = codi QR físic estable de la taula (paret)
- `site_id`, `location_id?` (zona/sala)

El QR de paret **no** obre comanda lliure: només resol “hi ha `dining_session` open?”.

### `data.dining_sessions`

| Camp | Notes |
|------|--------|
| `tenant_id`, `site_id` | Obligatoris |
| `table_asset_id` | FK assets |
| `party_size` | Comensals |
| `status` | `open` / `closed` |
| `guest_token_hash` | Token de sessió (mai plaintext) |
| `opened_by_employee_id` | Qui ha obert |
| `reservation_id?` | Vincle Fase 3 |
| `eta_seconds?` | Denormalitzat; actualitzar només en canvi d'estat / nou item enviat |
| `opened_at`, `closed_at` | |

### `data.dining_orders`

| Camp | Notes |
|------|--------|
| `tenant_id`, `site_id`, `session_id` | |
| `channel` | `waiter` \| `guest` |
| `waiter_employee_id?` | |
| `status` | `open` / `sent` / `completed` / `cancelled` |
| `course_wave` | Tongada (int); hold/fire |

### `data.dining_order_items`

| Camp | Notes |
|------|--------|
| `tenant_id`, `site_id`, `order_id`, `menu_item_id` | |
| `qty`, `notes`, `allergens_snapshot`, `station` | Snapshot en crear |
| `status` | `pending` → `preparing` → `ready` → `served` (o `cancelled`) |
| `prep_started_at`, `ready_at`, `served_at` | |

**ETA:** no columna reescrita en cascada a cada item. RPC `api.get_dining_session_eta(session_id)` i/o `dining_sessions.eta_seconds` en canvis controlats.

Fórmula v1 (creïble, no ML):

```text
eta_item ≈ prep_time_min(menu_item)
         + queue_penalty(count pending|preparing same station, site)
         + load_factor(site_settings)
```

Guest veu l'ETA agregat de la sessió (plat pendent més lent / política documentada).

### `data.reservations` (Fase 3)

`tenant_id`, `site_id`, `party_size`, `start_at`, `duration_min`, `status` (`requested` / `confirmed` / `seated` / `completed` / `no_show` / `cancelled`), `table_asset_id?`, `channel`, contacte, `notes`, `deposit_amount?`.

RPC: `api.check_table_availability(site_id, start_at, party_size)`.

### `data.ops_devices`

Dispositius d'operació (KDS). **No** estendre `attendance_devices`.

`kind = 'kitchen_display'`, `tenant_id`, `site_id`, `station_filter[]`, `public_id`, `secret_hash`, `last_seen_at`.

### `data.dining_service_events` (mínim)

Events de sala: almenys `guest_call` (taula, session_id, timestamp, acknowledged_by?). Opcional: audit fire/86.

Alimenta l'inbox **Crides** de Sala.

---

## Estats i transicions

### Item

```text
pending → preparing → ready → served
    ↘ cancelled (només abans de preparing, o manager/cuina després)
```

### Sessió

```text
(open by waiter) → open → closed
Guest comanda només mentre open.
```

### Reserva (Fase 3)

```text
requested → confirmed → seated → completed
                 ↘ cancelled | no_show
```

`seated` pot obrir/lligar `dining_session`.

---

## Permisos

Namespace `dining.*` (documentar a `04-roles-and-permissions.md` quan s'implementi):

- `dining.menu.{view,edit}`
- `dining.floor.{view,manage}`
- `dining.orders.{view,manage}`
- `dining.kds.operate`
- `dining.reservations.{view,manage}`

Gating per archetype/addon hospitality. No confondre amb el permís genèric `orders.*` del checklist ERP (work/sales).

---

## Multi-tenant

Totes les taules calentes porten `tenant_id` + `site_id`. RLS / RPCs alineats amb `jwt_has_permission(..., site_id)`. El JWT del portal empleat ha d'incloure `site_id` o un gate de selecció abans de Sala.
