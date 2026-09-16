# MCP — Arquitectura i seguretat

> Decisions de producte: [`README.md`](./README.md) · ordre: [`EXECUTION.md`](./EXECUTION.md)

## 1) Principis no negociables

1. **Aïllament multi-tenant a SQL** — `WHERE tenant_id = $tenantId` (+ `site_id` si la sessió en té); mai filtrar només en memòria.
2. **Defensa en profunditat** — auth + grant/key binding + RLS + validació d’arguments + rate limit + WAF.
3. **Fail-closed** — falta de secret, flag, grant, membresia o scope → rebuig.
4. **Producció amb capa edge** — no obrir MCP públic sense WAF/API Gateway.
5. **Observabilitat abans del rollout global** — usage, alertes, runbook, canary.

## 2) Rols OAuth (MCP remota)

| Rol | Qui |
|-----|-----|
| Authorization server | Supabase Auth (`/auth/v1/oauth/*`) |
| Consent screen | `tenant-portal` (`/oauth/consent`) |
| Resource server | Edge Function MCP (+ proxy `/mcp`) |
| OAuth client | Claude, Cursor, ChatGPT, etc. |

Supabase **no** és el servidor MCP; només emet tokens. El resource server valida i executa tools.

## 3) Modes d’autenticació

### 3.1 OAuth (usuaris app)

1. Request sense token → `401` + `WWW-Authenticate` amb `resource_metadata` (RFC 9728).
2. Client descobreix AS; usuari autentica i consent; tria tenant/site permesos.
3. Insert a `mcp_client_grants`.
4. Token Bearer: verificar JWKS, `iss`, **`client_id` obligatori** (rebutjar session JWTs).
5. Comprovar grant + flags + membresia; client Supabase **user-scoped** per RLS.

**Caveats Supabase (documentats Makerkit, agos. 2026):**

- Ignora `resource` (RFC 8707); `aud` = `"authenticated"` → no servir com a audience binding.
- Sense scopes custom → tenancy i tools via grants / `allowed_tools`.
- Re-autoritzacions auto-aprovades → UI “connected apps” obligatòria.
- Tokens OAuth amb `aal1` → polítiques MFA/`aal2` poden buidar resultats; exempció estreta per `client_id` o resolució admin del slug.

### 3.2 API key (S2S)

- Format estricte: `mcp_live_<…>` / `mcp_test_<…>` (regex **abans** de BD).
- Emmagatzematge: `key_prefix` + `key_hash` (HMAC-SHA256 amb `MCP_API_KEY_SECRET`; sense fallback insegur).
- Binding: `tenant_id`, `site_id?`, `allowed_tools[]`, caducitat, revocació.
- Atribució: `api_key_id` + `created_by`; no és un usuari interactiu.

### 3.3 Prohibit

- JWT de sessió portal + `X-Tenant-Id` / `X-Site-Id` com a auth MCP.

## 4) Flux de request

1. WAF: IP/geo, rate limit edge, TLS.
2. Pre-auth a la funció: mètode, mida body (p.ex. 64 KB), format credencial, rate limit distribuït (Upstash/WAF — **no** Map en memòria d’instància).
3. Resoldre auth (`oauth` | `api_key`).
4. Avaluar cascada de flags + settings tenant.
5. Rate limit de negoci (tenant / user / key).
6. Executar tool/resource amb SQL scoped; timeout curt (5–10 s).
7. Escriure `mcp_usage_logs` (async/best-effort); retornar resposta MCP.

## 5) Rate limiting (3 capes)

| Capa | On | Què |
|------|-----|-----|
| 1 | WAF / Cloudflare | IP, burst |
| 2 | Store distribuït (Upstash/Redis) o WAF per fingerprint de credencial | Pre-auth, abans de BD costosa |
| 3 | BD / quotes tenant | Hora/dia per tenant, user OAuth, API key |

## 6) Errors apresos a evitar

1. Rate limit després de N queries d’auth.  
2. Lookup SQL per qualsevol string amb prefix `mcp_`.  
3. Body sense límit.  
4. Filtrar `site_id` en memòria.  
5. CORS `*`.  
6. Secrets amb fallback.  
7. `last_used_at` UPDATE síncron a cada request (hot row) → throttle / cron.  
8. Acceptar session JWT sense `client_id`.  
9. Passar `tenant_id` com a argument de tool.

## 7) Tools i resources

- MVP: només **read**.  
- Allowlist pública revisada (GDPR/RBAC); subconjunt del xat intern, no còpia cega.  
- Arguments: Zod/schema estricte, UUIDs, enums.  
- Resources: URI amb tenant/site; han de coincidir amb la sessió.  
- Errors de negoci: `isError` in-band (no throw → protocol error).

## 8) Config runtime

| Variable | Notes |
|----------|--------|
| `MCP_SERVER_FORCE_DISABLED` | Kill switch |
| `MCP_API_KEY_SECRET` | Obligatori en prod |
| `MCP_PUBLIC_URL` | URL estable del resource (proxy) |
| `MAX_BODY_BYTES` | p.ex. 64 KB |
| `MCP_CORS_ALLOW_ORIGINS` | Allowlist o buit si no browser |
| Secrets Upstash/WAF | Rate limit capa 2 |

Edge Function: `verify_jwt = false` al gateway; validació Bearer a la funció.

## 9) Portals

### admin-portal
- Flags globals + overrides per tenant (OAuth / API keys).  
- Kill switch / motiu.  
- Ús cross-tenant (`mcp_usage_logs`).  

### tenant-portal
- Settings MCP (si admin ho permet).  
- Política usuaris OAuth (rols o allowlist).  
- Consent + connected apps + API keys + ús propi.  

## 10) Relació amb Makerkit

Adoptar: OAuth AS/RS, PRM, `client_id`, grants, Streamable HTTP stateless, RLS user-scoped.  
Mantenir del pla original: WAF, pre-auth, hashing keys, canary, Go/No-Go, admin observabilitat.  
Descartar: JWT sessió com a mode MCP.
