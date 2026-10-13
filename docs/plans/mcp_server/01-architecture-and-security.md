# MCP — Arquitectura i seguretat

> Decisions de producte: [`README.md`](./README.md) · ordre: [`EXECUTION.md`](./EXECUTION.md)  
> Bootstrap oficial: [Library headless MCP](https://supabase.com/library/docs/headless/mcp)

## 1) Principis no negociables

1. **Aïllament multi-tenant a SQL** — `WHERE tenant_id = $tenantId` (+ `site_id` si la sessió en té); mai filtrar només en memòria.
2. **Defensa en profunditat** — auth + grant/key binding + RLS + validació d’arguments + rate limit + WAF.
3. **Fail-closed** — falta de secret, flag, grant, membresia, `client_id` (path OAuth) o scope → rebuig.
4. **Producció amb capa edge** — no obrir MCP públic sense WAF/API Gateway.
5. **Observabilitat abans del rollout global** — usage, alertes, runbook, canary.
6. **Sense `supabaseAdmin` al ToolContext** — només client user-scoped (Library + PiMed).

## 2) Rols OAuth (MCP remota)

| Rol | Qui |
|-----|-----|
| Authorization server | Supabase Auth (`/auth/v1`) |
| Consent screen | `tenant-portal` (`/oauth/consent`) — bloc Library Consent adaptat a Vite |
| Resource server | Edge Function `mcp` (`@supabase/mcp` + capa PiMed) |
| OAuth client | Claude, Cursor, ChatGPT, etc. (DCR) |

Supabase **no** és el servidor MCP; emet tokens. El resource server valida i executa tools.

## 3) Stack canònic (Library + PiMed)

```ts
// Ordre middleware (Library). Després: gate client_id + grants + flags (PiMed).
pipeline(
  [withOAuthProtectedResource(), withSupabase({ auth: 'user', cors: { headers: CORS_HEADERS } })],
  handleMcp
)
```

| Capa | Orígen | Responsabilitat |
|------|--------|-----------------|
| `withOAuthProtectedResource` | Library | RFC 9728 PRM + `WWW-Authenticate` |
| `withSupabase({ auth: 'user' })` | Library | Verifica JWT (JWKS asimètric); client RLS |
| Gate `client_id` + grant + flags | **PiMed** | Rebutja session JWT; tenancy; kill switch |
| Branca API key | **PiMed** | S2S; no coberta pel scaffold |
| `registerXTools` / `jsonResult` | Library | Convenció de tools; **sense** admin client |

**Prerequisits:** CLI ≥ 2.117; `[functions.mcp] verify_jwt = false`; signing keys ES256/RS256; `[auth.oauth_server] enabled = true` + `allow_dynamic_registration = true`.

**Custom domain:** si el resource no és `*.supabase.co`, fixar `MCP_AUTH_ISSUER` a l’issuer real del projecte (`https://<ref>.supabase.co/auth/v1`).

## 4) Modes d’autenticació

### 4.1 External OAuth (producte MCP públic)

1. Sense token → `401` + PRM (middleware Library).
2. DCR + consent; usuari tria tenant/site permesos → `mcp_client_grants`.
3. Després de `withSupabase`: **exigir `jwtClaims.client_id`**; si manca → 401.
4. Comprovar grant + flags + membresia; tools amb client user-scoped.

### 4.2 API key (S2S)

- Format: `mcp_live_<…>` / `mcp_test_<…>` (regex **abans** de BD).
- Hash a BD; binding `tenant_id` / `site_id?` / `allowed_tools`.
- Branca d’auth pròpia (no és el path `auth: 'user'` de la Library).

### 4.3 Embedded (Library) — fora de l’MCP públic PiMed

La Library documenta reutilitzar el **session JWT** des d’un backend de confiança per agents embebits.  
**Decisió PiMed:** no habilitar aquest mode a l’endpoint MCP públic. Agents del producte → pla de function calling / BFF intern.

### 4.4 Prohibit a l’endpoint públic

- Session JWT (amb o sense `X-Tenant-Id`).
- Qualsevol Bearer sense `client_id` al path OAuth.
- `supabaseAdmin` compartit amb tools.

**Caveats (Makerkit + docs Supabase):**

- `resource` (RFC 8707) ignorat; `aud` = `"authenticated"`.
- Sense scopes custom → tenancy via grants.
- Re-auth auto-approve → UI connected apps / revoke obligatòria.
- OAuth tokens sovint `aal1` → MFA pot buidar resultats; política explícita.
- `withSupabase({ auth: 'user' })` **accepta** session i OAuth; el gate `client_id` és **obligatori** a PiMed.

## 5) Flux de request

1. WAF: IP/geo, rate limit, TLS.
2. Pre-auth: mètode, mida body (p.ex. 64 KB), format credencial, rate limit distribuït.
3. Pipeline Library (PRM / verify user JWT) **o** branca API key.
4. Gate PiMed (`client_id` / key hash / flags / grant).
5. Rate limit de negoci.
6. Tool SQL scoped; timeout 5–10 s; caps de files/bytes (hardening).
7. `mcp_usage_logs` (async/best-effort).

## 6) Rate limiting (3 capes)

| Capa | On | Què |
|------|-----|-----|
| 1 | WAF | IP, burst |
| 2 | Upstash/Redis o WAF fingerprint | Pre-auth |
| 3 | Quotes tenant / user / key | Hora/dia |

## 7) Errors apresos a evitar

1. Rate limit després de N queries d’auth.  
2. Lookup SQL per qualsevol string amb prefix `mcp_`.  
3. Body sense límit; **resposta** sense límit de files/bytes.  
4. Filtrar `site_id` en memòria.  
5. CORS `*`.  
6. Secrets amb fallback.  
7. `last_used_at` UPDATE síncron per request.  
8. Confiar només en `withSupabase` sense gate `client_id`.  
9. Passar `tenant_id` com a argument de tool.  
10. Copiar tools **write** del tutorial Library al MVP.  
11. Copiar fitxers del registry JSON en lloc de `shadcn add`.

## 8) Tools

- MVP **read-only**; allowlist revisada.  
- Mòduls `registerXTools(server, context)`; context: `supabase`, `userClaims`, `jwtClaims` — **no** admin.  
- Arguments Zod estrictes; `jsonResult` / `runtimeErrorResult` (Library).  
- Errors de negoci in-band (`isError`), no throw de protocol.

## 9) Config runtime

| Variable | Notes |
|----------|--------|
| `MCP_SERVER_FORCE_DISABLED` | Kill switch |
| `MCP_API_KEY_SECRET` | Hash keys (prod) |
| `MCP_AUTH_ISSUER` | Si custom domain |
| `MCP_SERVER_NAME` / `MCP_SERVER_DESCRIPTION` | Library `.env` |
| `MAX_BODY_BYTES` | p.ex. 64 KB |
| `MCP_CORS_ALLOW_ORIGINS` | Allowlist |
| Upstash/WAF secrets | Rate limit capa 2 |

## 10) Portals

### admin-portal
Flags globals + overrides; kill switch; ús cross-tenant.

### tenant-portal
Settings MCP; política usuaris; Consent (+ picker tenant/site); connected apps / revoke; API keys; ús.

## 11) Què aporta Library vs PiMed

| Library / SELECT | PiMed |
|------------------|--------|
| Edge MCP + PRM + user client RLS | Grants multi-tenant + picker |
| DCR + Consent block | Gate `client_id` (external-only) |
| Convenció tools / whoami | API keys S2S |
| | Flags, usage, WAF, audit, read-only allowlist, caps |
