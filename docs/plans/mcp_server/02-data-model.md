# MCP — Model de dades

> Schema orientatiu per a migracions. Noms finals poden ajustar-se al catàleg `data.*` existent; no inventar schemas paral·lels.

## 1) Feature flags (plataforma)

Reutilitzar `feature_flags` + overrides per tenant (patró admin-portal):

| key | Default inicial | Significat |
|-----|-----------------|------------|
| `mcp_enabled` | `false` | MCP disponible |
| `mcp_oauth_enabled` | `false` | Mode OAuth usuaris |
| `mcp_api_keys_enabled` | `false` | Mode API keys S2S |

Kill switch d’emergència: env `MCP_SERVER_FORCE_DISABLED` (no és fila BD).

## 2) Settings per tenant

Taula `data.tenant_mcp_settings` (o columnes a settings existent si ja hi ha patró similar):

| Columna | Tipus | Notes |
|---------|-------|--------|
| `tenant_id` | uuid PK/FK | |
| `mcp_enabled` | boolean | Default false |
| `oauth_enabled` | boolean | |
| `api_keys_enabled` | boolean | |
| `user_access_mode` | text | `roles` \| `allowlist` \| `owners_only` |
| `allowed_roles` | text[] | Si mode `roles` |
| `max_requests_per_hour` | int null | Quote interna |
| `max_requests_per_day` | int null | |
| `updated_at` | timestamptz | |
| `updated_by` | uuid null | |

Allowlist d’usuaris (si cal):

`data.tenant_mcp_allowed_users (tenant_id, user_id | member_id, created_at, created_by)`  
UNIQUE `(tenant_id, user_id)`.

## 3) API keys

`data.mcp_api_keys`:

| Columna | Tipus | Notes |
|---------|-------|--------|
| `id` | uuid PK | |
| `tenant_id` | uuid NOT NULL | |
| `name` | text NOT NULL | |
| `key_prefix` | text NOT NULL UNIQUE | p.ex. primers chars + entorn |
| `key_hash` | text NOT NULL | HMAC-SHA256 |
| `site_id` | uuid null | Scope opcional |
| `allowed_tools` | text[] null | null = allowlist tenant default |
| `expires_at` | timestamptz null | |
| `revoked_at` | timestamptz null | |
| `last_used_at` | timestamptz null | Actualitzar throttled |
| `last_client_name` | text null | |
| `created_by_user_id` | uuid/text | |
| `created_at` | timestamptz | |

Índexs: `(tenant_id, revoked_at)`; parcial actives (`revoked_at IS NULL`).

## 4) Grants OAuth

`data.mcp_client_grants`:

| Columna | Tipus | Notes |
|---------|-------|--------|
| `id` | uuid PK | |
| `user_id` | uuid NOT NULL | `auth.users` |
| `oauth_client_id` | uuid NOT NULL | claim `client_id` |
| `tenant_id` | uuid NOT NULL | |
| `site_id` | uuid null | |
| `allowed_tools` | text[] null | |
| `created_at` | timestamptz | |
| `revoked_at` | timestamptz null | |
| `created_via` | text | `consent` \| `admin` |

UNIQUE actiu: `(user_id, oauth_client_id, tenant_id, site_id)` on `revoked_at IS NULL` (índex únic parcial).

**RLS:** policies que exigeixen `(auth.jwt() ->> 'client_id') IS NULL` per INSERT/DELETE humans al portal; agents **no** llegeixen ni amplien grants. El resource server comprova grants amb **admin client** + filtres explícits `user_id`, `oauth_client_id`, `tenant_id`, `site_id`.

## 5) Usage logs (ops)

`data.mcp_usage_logs`:

| Columna | Tipus |
|---------|-------|
| `id` | uuid/bigserial |
| `tenant_id` | uuid NOT NULL |
| `auth_type` | text `oauth` \| `api_key` |
| `api_key_id` | uuid null |
| `user_id` | uuid null |
| `oauth_client_id` | uuid null |
| `client_name` | text null |
| `user_agent` | text null |
| `mcp_method` | text |
| `tool_name` | text null |
| `resource_uri` | text null |
| `status` | text (`success`, `error`, `rejected_*`) |
| `latency_ms` | int |
| `created_at` | timestamptz |

Retenció: job ~90 dies. Índexs: `(tenant_id, created_at DESC)`, `(created_at)` per purge.

**No** escriure cada tool call a `audit_logs`.

## 6) Rate limit windows (opcional BD capa 3)

`data.mcp_rate_limit_buckets (scope_type, scope_id, window_start, window_size, count)`  
o equivalent Upstash-only a capa 2+3 si es prefereix zero DDL de buckets.

## 7) Events `data.audit_logs`

Cicle de vida (naming MAJÚSCULES_AMB_GUIÓ_BAIX). Payload **sense** secrets/tokens.

| action | entity_type (ex.) |
|--------|-------------------|
| `MCP_ENABLED` / `MCP_DISABLED` | `tenant_mcp_settings` |
| `MCP_OAUTH_ENABLED` / `MCP_OAUTH_DISABLED` | `tenant_mcp_settings` |
| `MCP_API_KEYS_ENABLED` / `MCP_API_KEYS_DISABLED` | `tenant_mcp_settings` |
| `MCP_API_KEY_CREATED` / `MCP_API_KEY_REVOKED` | `mcp_api_key` |
| `MCP_GRANT_CREATED` / `MCP_GRANT_REVOKED` | `mcp_client_grant` |
| `MCP_USER_ACCESS_POLICY_CHANGED` | `tenant_mcp_settings` |
| `MCP_QUOTA_CHANGED` | `tenant_mcp_settings` |
| `MCP_PLATFORM_FLAG_CHANGED` | `feature_flag` (actor admin) |

Triggers BD on settings/keys/grants **o** insert explícit des de Server Actions / Edge (fire-and-forget).

## 8) Permisos RBAC (orientatiu)

| Permís | Qui |
|--------|-----|
| `mcp.settings.manage` | owner/admin tenant |
| `mcp.api_keys.manage` | owner/admin |
| `mcp.grants.manage` | owner/admin (+ usuari revoca els seus) |
| `mcp.usage.read` | owner/admin |
| Admin plataforma | control-plane existent (feature flags) |

## 9) Avaluació efectiva (pseudocodi)

```
if env.MCP_SERVER_FORCE_DISABLED: deny
if !effective(mcp_enabled, tenant): deny
if auth == oauth:
  if !effective(mcp_oauth_enabled, tenant): deny
  if !tenant.oauth_enabled: deny
  if !user_allowed(tenant, user): deny
  if !grant_active(...): deny
if auth == api_key:
  if !effective(mcp_api_keys_enabled, tenant): deny
  if !tenant.api_keys_enabled: deny
  if key revoked/expired/hash mismatch: deny
```
