# Fase 2 — Seguretat server-side, Gestoria, rutes `/sales`

> **Ordre:** 2 · **Depèn de:** 1A (mínim; 1B recomanat) · **Bloqueja:** 4, 5, 6 (UI)  
> **Índex:** [`README.md`](./README.md)

## Objectiu

Protegir totes les RPC d’escriptura amb tenant actiu + permisos JWT. Obrir la IA Comercial (`/sales`) i un preset Gestoria sense donar poder d’edició.

## Permisos

### Claus noves

- [ ] Afegir a `PermissionKey` / `ALL_PERMISSION_KEYS` (`permissions.ts`):
  - `invoices.review`
  - `invoices.export`
- [ ] Actualitzar `data.get_role_permissions` i seeds/defaults SQL (mateix patró que altres migracions de permisos).
- [ ] Dependències: `review`/`export` → requereixen `invoices.view`; `edit` → `view`; `manage` → `edit` (+ view).

### Matriu (V1)

| Acció | view | review | export | edit | manage |
|-------|:----:|:------:|:------:|:----:|:------:|
| Veure `/sales` llistes/fitxes | ✓ | ✓ | ✓ | ✓ | ✓ |
| Marcar revisió comptable | | ✓ | | | ✓ |
| Generar/descarregar export | | | ✓ | | ✓ |
| Emitir / cancel·lar factura, cobrar factura | | | | ✓ | ✓ |
| Sèries, exercicis, perfils export | | | | | ✓ |

### Overrides per membre

- [ ] Model: allow/deny per `tenant_members` (metadata o taula) que es fusiona al rebuild de `user_permissions`.
- [ ] Preset invitació **Gestoria**:
  - base rol `viewer`
  - allow: `invoices.view`, `invoices.review`, `invoices.export`
  - deny implícit: edit/manage, members, settings, cobrament camp si cal
- [ ] UI Settings → Membres: triar preset o overrides (mínim viable: preset + llista permisos).
- [ ] Rebuild JWT/cache quan canvien overrides.

### Helper SQL

- [ ] `data.assert_invoice_permission(p_tenant, p_key)` (o genèric `jwt_has_permission`).
- [ ] Totes les RPC DEFINER d’invoice/payment/fiscal/export:
  - `auth.uid()` no nul
  - `active_tenant_id()` no nul
  - document.tenant_id = active tenant
  - permís adequat
- [ ] Tests: membre d’un altre tenant / sense permís / active tenant diferent → `forbidden`.

## Rutes i navegació

### Rutes (`App.tsx`)

- [ ] `/sales` — dashboard (KPI stub OK si Fase 4 completa)
- [ ] `/sales/quotes` (moure o reutilitzar `QuotesPage`)
- [ ] `/sales/delivery-notes`
- [ ] `/sales/delivery-notes/:id` (stub → Fase 6)
- [ ] `/sales/invoices`
- [ ] `/sales/invoices/:id` (stub → Fase 6)
- [ ] `/sales/accounting` (stub → Fase 5)
- [ ] Redirects: `/quotes`, `/delivery-notes`, `/cobraments` → equivalents `/sales/…` conservant query.
- [ ] `?view=` → redirect a fitxa quan existeixi.

### Sidebar

- [ ] Un sol item `sales`, label «Comercial», `to: '/sales'`, match `/sales`.
- [ ] Gate nav: `isOffice` **o** `invoices.view` (gestoria sense ser «oficina» clàssica — decidir: preferir `invoices.view`).
- [ ] `defaultNavLayout`: treure `quotes` + `delivery_notes` separats; posar `sales`.
- [ ] `resolveNav`: aliases `quotes`, `delivery_notes`, `cobraments` → `sales`.
- [ ] `navigationReturn.ts` + tests: paths nous i legacy.
- [ ] Locales ca/es/en: «Comercial».

### Tabs

- [ ] Layout `/sales/*` amb tabs: Pressupostos | Albarans | Factures | (Comptabilitat si `review|export|manage`).
- [ ] Usar `components/ui/tabs.tsx` / scrollable tab bar existent.

## Fitxers

| Àmbit | Fitxers |
|-------|---------|
| Permisos | `permissions.ts`, migració RBAC, Members UI |
| Rutes | `App.tsx`, pàgines sota `features/commercial/` o `features/sales/` |
| Nav | `navCatalog.ts`, `defaultNavLayout.ts`, `resolveNav.ts`, tests |
| SQL | assert permission a RPCs 1A/1B |

## Proves

- [ ] TS: aliases nav, redirects, `navigationReturn`.
- [ ] SQL: gestoria no pot `issue_invoice` / `record_invoice_payment` / `cancel_invoice`.
- [ ] SQL: gestoria pot SELECT documents del tenant actiu.
- [ ] Manual: usuari gestoria veu Comercial; no veu Settings sèries.

## DoD

- [ ] Cap RPC invoice sense active tenant + permís.
- [ ] `/sales` navegable; legacy URLs redirigeixen.
- [ ] Preset Gestoria documentat i usable.
- [ ] Checklist actualitzat.
