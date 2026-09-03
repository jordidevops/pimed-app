# Customer portal — Estat d'implementació

> **Última actualització:** 2026-08-07  
> **Propòsit:** seguir el desenvolupament del portal del client i butlletins d'intervenció.  
> **Pla:** [`README.md`](./README.md) · ordre d'execució [`EXECUTION.md`](./EXECUTION.md)

## Llegenda

| Símbol | Significat |
|--------|------------|
| ✅ | Fet i usable |
| 🔄 | En curs |
| ❌ | No començat |
| 📦 | Diferit (fase posterior / altre pla) |
| ⚠️ | Parcial |

---

## Milestones

| Fase | Nom | Estat | Notes |
|------|-----|-------|-------|
| **CP-0** | Contracte i documentació | ✅ | |
| **CP-A0.1** | Contactes empresa-persona + canals | ✅ | Base reescrita a CP-C |
| **CP-A1** | Domini immutable i autorització | ✅ | Base reescrita a CP-C |
| **CP-A0.3–7** | Backfill / legacy | ✅ | |
| **CP-A2** | Shares i lliurament | ✅ | Base reescrita a CP-C |
| **CP-A3** | UX butlletí tenant | ✅ | |
| **CP-A4** | Reader + staff view | ✅ | |
| **CP-ADM** | Entitlements / admin | ✅ | |
| **CP-B** | Portal client light | ✅ | MVP històric; model substituït |
| **CP-C** | Portal centrat en el contacte | 🔄 | P0+P1+P2 frontera tancats al codi; resta CP-C (multi-dest / ops) |

---

## CP-C — Portal centrat en el contacte

| # | Ítem | Estat | Evidència |
|---|------|-------|-----------|
| 1 | Contracte README / EXECUTION / product-design | ✅ | Decisions compte+principal+delivery |
| 2 | Rewrite migracions contactes / CIR / shares / grants | ✅ | Sense recipient; canals; delivery_rules |
| 3 | UI Contactes `portal_access` + hub | ✅ | Fitxa + hub (també invites-only) |
| 4 | Butlletí: draft obert, publicar sense destinatari, preflight | ✅ | Publish ≠ cancelled; multi-link |
| 5 | Multi-destinatari + autoenviament + BCC + worker | 🔄 | Cron+trigger+on_publish SQL; login email |
| 6 | Staff scope compte + dashboard per compte | 🔄 | Media `?v=` staff arreglat |
| 7 | `db reset` + types + tests | 🔄 | Reset OK (vector 409 residual); P1+P2 suites PASS |

### P0 frontera (2026-08-06) — tancats al codi

| # | P0 | Estat |
|---|----|-------|
| 1 | Media client-controlled → `file_node_id` + ledger privat + completion `service_role` | ✅ |
| 2 | `site_origin` phishing al grant resolver | ✅ eliminat; només `CUSTOMER_PORTAL_ORIGIN` |
| 3 | Resolvers sense credential BFF | ✅ `X-Customer-Portal-Bff-Secret` + rotació |
| 4 | `service_role` al customer-portal BFF | ✅ eliminat; stream Edge + CI guard |
| 5 | Segona porta `publish_project_client_report` | ✅ DROP; CIR única autoritat |

### P1 frontera (2026-08-06) — tancats al codi

| # | P1 | Estat |
|---|----|-------|
| 6 | Media teatre → selector `file_node_id` + hydrate | ✅ |
| 7 | `portal.manage` + REVOKE writes delivery + triggers | ✅ |
| 8 | Forge draft/version (SELECT-only CIR) | ✅ residual tancat |
| 9 | Draft `preparing_media` retry + Edge→`failed` | ✅ |
| 10 | Legacy sense compte → unresolved + cleanup ghosts | ✅ |
| 11 | SafeLinks: GET/HEAD estèril, POST exchange | ✅ `/s` `/invite` `/g` `/staff` |
| 12 | CP-B RAISE + denial T6 | ✅ |
| 13 | Staff handoff → opaque (`exchanged_at`) | ✅ |

Ops local: mateix `CUSTOMER_PORTAL_BFF_SECRET` a BFF i `supabase/functions/.env.local`; reiniciar `functions serve` (copy + stream + resolve).

### P2 frontera (2026-08-06) — tancats al codi

| # | P2 | Estat |
|---|----|-------|
| 1 | Fulfill branques per `email_logs` (mark-only vs revoke+remint) | ✅ |
| 2 | `settings.manage` UI + RPC DEFINER + REVOKE writes `customer_portal_tenant_state` | ✅ |
| 3 | Backfill belt `snapshots.backfill` + test no `on_publish` | ✅ |
| 4 | GRANT INSERT CIR SELECT-only (`00025` + `00031`) | ✅ |
| 5 | Audit `request_id` server-only (BFF + Edge belt) | ✅ |
| 6 | Treure `manualEmails`; i18n en/es `settings.customer_portal` | ✅ |
| 7 | Tests honestos T2 ELSE FAIL; shares ROLE+JWT `service_role` | ✅ |

### Locales portal (2026-08-07) — tancats al codi

| # | Ítem | Estat |
|---|------|-------|
| 1 | `tenant_state`: supported/default(`es`)/allow_client_change + RPCs | ✅ |
| 2 | Resolve/entitlements exposen camps locale; persist compte via service_role | ✅ |
| 3 | Tenant Settings + tab Portal `preferred_locale` | ✅ |
| 4 | customer-portal `react-i18next` ca/es/en + `ui_locale` + selector (share/grant) | ✅ |
| 5 | Draft/publish locale: preferred compte → tenant default → `es` | ✅ |
| 6 | Tests SQL `customer_portal_locales_tests.sql` 8/8 | ✅ |

### Fixes post-revisió (2026-08-05)

- Dispatcher `invoke_customer_report_share_email_worker` + cron `*/2` + trigger INSERT intents
- Login return-visit: `enqueue_email` real (ja no només log)
- Backfill omple `customer_account_contact_id`
- Permís `contacts.portal.manage`; authz `shared_mailbox` = compte; person-account self
- TTL >72h exigeix second-channel; email intents max 72h
- Sense `share_url` a metadata; no revoke després d’enqueue OK
- `on_publish` via trigger a versions

---

## Changelog

| Data | Canvi |
|------|-------|
| 2026-08-07 | Footer tenant + `/dashboard/access`; settings perfil públic; staff history col·lapsable sota «Veure portal» |
| 2026-08-07 | P0 transparència accessos: grants + staff «Suport de {tenant}» al dashboard; historial staff al tab Portal; staff empty = dashboard.empty |
| 2026-08-07 | Fix staff preview: `create_customer_portal_staff_session` → SECURITY DEFINER (platform_state + INSERT sessions) |
| 2026-08-07 | Fix invite accept: `00032` CHECK havia eliminat `invitation_accepted` (i login/list); restaurat allow-list |
| 2026-08-07 | Locales portal: catàleg ca/es/en, default `es`, preferred compte, i18n customer-portal, tests 8/8 |
| 2026-08-06 | P2 frontera tancats (fulfill branques, settings.manage, backfill belt, request_id, i18n, tests) |
| 2026-08-06 | P1 residual: stream no-consume handoff; fail_prepare en 502; CP-B T6 denial real |
| 2026-08-06 | P1 frontera tancats (portal.manage+REVOKE, CIR SELECT-only, SafeLinks POST, staff opaque, CP-B RAISE) |
| 2026-08-06 | P0 frontera tancats al codi (media ledger, BFF secret, stream Edge, CIR-only publish) |
| 2026-08-05 | CP-C 🔄: correccions P0/P1 (worker, login mail, authz, media staff) |
| 2026-08-05 | CP-C tancat prematurament (revisió va trobar forats) |
| 2026-08-05 | CP-C obert: portal centrat en contacte; rewrite migracions (local) |
| 2026-08-05 | CP-B tancat (MVP); grants + dashboard; gate B0 |
| 2026-08-04 | CP-ADM tancat; entitlements UI + fix resolve/sync |
| 2026-08-04 | CP-A4 tancat; customer-portal reader + staff |
| 2026-08-04 | CP-A3 tancat; tab Butlletí |
| 2026-08-04 | CP-A2 tancat; shares + Edge resolver |
| 2026-08-04 | CP-A0.3–7 / A1 / A0.1 / CP-0 |
