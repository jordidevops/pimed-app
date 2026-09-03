# Customer portal — Pla mestre d'execució

> **Rol:** única font de veritat de l'ordre d'implementació i del treball pendent  
> **Creat:** 2026-08-04  
> **Pla d'arquitectura:** [`README.md`](./README.md)  
> **Estat per milestone:** [`STATUS.md`](./STATUS.md)  
> **Fase activa:** **CP-C** 🔄 (P0+P1+P2 frontera tancats al codi; resta CP-C + smoke local)  
> **Anterior:** CP-B MVP ✅ · CP-ADM ✅ · CP-A4 ✅ · … · CP-0 ✅  
> **Schema:** migracions CP-A/CP-B reescrites + `db reset` local

## Disciplina

1. Llegir aquest fitxer i STATUS a l'inici de cada conversa d'implementació.
2. Treballar **només** la fase activa (o un ítem de backlog acordat).
3. Al tancar: STATUS ✅ → changelog → avançar fase activa.
4. Mentrestant no hi hagi producció: **preferir editar la migració font** abans d'afegir fixups additius.

## Ordre real (gates)

| Ordre | Fase | Nota |
|------:|------|------|
| 1–9 | CP-0 … B | ✅ MVP històric (schema reescrit a CP-C) |
| 10 | **CP-C** | 🔄 Compte client + Contactes + publicació ⊥ lliurament |

---

## CP-C 🔄 — Portal centrat en el contacte

### Fet

- Compte client = empresa o persona; publicació sense destinatari; portal per compte.
- Accés a Contactes (`portal_access` / hub); Settings = toggle, entitlements, BCC.
- Principals nominatius i bústies compartides; `contact_delivery_rules`.
- Migracions reescrites; fixups 00031/00032 absorbits.

### En curs (post-revisió)

1. Smoke local: mateix `CUSTOMER_PORTAL_BFF_SECRET` a BFF + Edge; reiniciar `functions serve` (copy + stream + resolve).
2. Multi-destinatari / worker fulfill residual.
3. Re-`db reset` net sense 409 vector residual si possible.

### P0 frontera (2026-08-06) — fet al codi

1. Media: `file_node_id` + ledger privat + completion només `service_role`.
2. BFF secret rotatiu; sense `site_origin` al grant resolver.
3. Sense `service_role` al customer-portal; `stream-customer-report-media`.
4. `publish_project_client_report` eliminat; CIR única autoritat.

### P1 frontera (2026-08-06) — fet al codi

1. Media UI real + retry `preparing_media` / Edge `fail_prepare` (també 502).
2. `contacts.portal.manage` + REVOKE writes delivery/CIR + triggers.
3. SafeLinks GET/HEAD estèril; POST exchange a `/s` `/invite` `/g` `/staff`.
4. Staff handoff → opaque (`exchanged_at`); stream amb `p_allow_handoff_consume=false`.
5. Legacy sense compte → unresolved; CP-B RAISE + denial RLS real (T6).
6. Residual `00033`: no-consume a media; revoke handoffs backfill sense rotació.

### P2 frontera (2026-08-06) — fet al codi

1. Fulfill/reclaim: mark-only si `email_logs` `crs-email:{key}:{share_id}`; sinon revoke+remint.
2. `settings.manage` a UI, RPC DEFINER i REVOKE INSERT/UPDATE `customer_portal_tenant_state`.
3. Trigger `on_publish` salta `snapshots.backfill`; legacy upsert l’estampa; test regressió.
4. CIR versions SELECT-only a `00025`; test `has_table_privilege(...INSERT)=false`.
5. `request_id` mint server-side al BFF; Edge sobrescriu body (resolve/stream).
6. Sense `manualEmails`; en/es `settings.json` (`customer_portal` + tabs).
7. Tests: T2 ELSE FAIL; shares `SET ROLE service_role` + JWT; `customer_portal_p2_hardening_tests.sql` 4/4.

### Locales portal (2026-08-07) — fet al codi

1. Migració `00035`: `supported_locales` / `default_locale=es` / `allow_client_locale_change`; peek defaults.
2. RPCs `set_my_customer_portal_locales` (`settings.manage`) + `set_customer_portal_account_locale` (service_role).
3. Resolve share/grant/staff + entitlements: camps locale; BFF `ui_locale` preferred→default→`es` (cookie overlay post-canvi).
4. Tenant Settings idiomes; Contact Portal tab `preferred_locale`; bulletin draft/publish default cascade.
5. customer-portal: `react-i18next` ca/es/en; selector share/grant si allow; staff sense canvi ni cookie overlay.
6. Edge `set-customer-portal-locale`; tests `customer_portal_locales_tests.sql` 8/8.

### Backlog diferit

1. Inventari ampli GRANT→authenticated (enduriment B0 continuous).
2. SMS/WhatsApp com a transport.
3. Matriu SQL completa invite→accept→list / person-account / no-cross-tenant.

Coherència P1/P2 (2026-08-05): `ends_at` unificat (resolve/rules/view + anti-overlap), FK compte a versions, `on_publish` amb entitlement, UI `canCreateShares === true`, errors RPC + en/es contacts portal.

---

## Fora d'abast

Vegeu [Fora d'abast inicial](./README.md#fora-dabast-inicial).
