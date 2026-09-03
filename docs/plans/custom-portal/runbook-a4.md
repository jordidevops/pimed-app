# Runbook CP-A4 — Customer portal reader

## Flux normal

1. Tenant crea share → secret 64 hex (una sola vegada).
2. URL: `{VITE_CUSTOMER_PORTAL_ORIGIN}/s/{secret}`.
3. BFF `GET /s/{token}` crida Edge `resolve-customer-report-share` `{token}` → cookie HttpOnly `cp_share_session` → redirect `/r`.
4. `/r` revalida amb `{session_token}` a cada càrrega (kill-switch / revocació immediata).
5. Media: `/api/media/...` revalida sessió i stream des de `customer-report-media` (Range).

## Staff «Veure com el client»

1. RPC `create_customer_portal_staff_session(version_id)` → secret.
2. Obrir `{origin}/staff/{secret}` → cookie `cp_actor_type=staff`.
3. Banner «Vista de suport»; no compta MAU client.
4. Kill-switch / `security_version` invalida O(1).

## Token compromès

1. Revocar la share al tenant-portal (incrementa `session_version`).
2. Opcional: kill-switch tenant (`api.set_my_customer_portal_enabled(false)`).
3. Plataforma: `api.set_customer_portal_kill_switch('platform', …)` (service_role).
4. Revisar `customer_report_share_access_logs` + `customer_portal_unknown_token_ledger`.

## Rate limits

- Exchange: `data.assert_customer_portal_rate_limit` fail-closed (Edge → 429).
- No usar fallback in-memory del public-portal per aquest flux.

## Headers / SEO

- `Cache-Control: private, no-store`
- `X-Robots-Tag: noindex, nofollow`
- `robots.txt` → `Disallow: /`
- `Referrer-Policy: no-referrer`, CSP amb `frame-ancestors 'none'`

## Retenció

- Logs: particions mensuals `customer_report_share_access_logs_*` (drop partition, no DELETE massiu).
- Shares revocades es retenen; no hard-delete mentre hi ha evidència d’accés.
