# MCP — Fases i backlog

> Ordre operatiu: [`EXECUTION.md`](./EXECUTION.md) · estat: [`STATUS.md`](./STATUS.md)

## Epics

| Epic | Nom | Dependències |
|------|-----|--------------|
| **MCP-0** | Decisions, threat model, contracte d’errors, inventari tools públiques candidatures | — |
| **MCP-1** | DDL: settings, keys, grants, usage_logs, índexs, retenció | MCP-0 |
| **MCP-2** | Feature flags + kill switch + avaluació efectiva (shared) | MCP-1 |
| **MCP-3** | Supabase OAuth Server + consent UI + PRM metadata | MCP-1 |
| **MCP-4** | Edge Function skeleton: Streamable HTTP, pre-auth, body limit, CORS | MCP-1, MCP-2 |
| **MCP-5** | Auth API key (hash, create/revoke RPCs, binding) | MCP-4 |
| **MCP-6** | Auth OAuth (JWKS, client_id, grants check, user-scoped client) | MCP-3, MCP-4 |
| **MCP-7** | Tools/resources read-only MVP (1–3 tools) + tests aïllament | MCP-5 o MCP-6 |
| **MCP-8** | tenant-portal: settings, keys, connected apps, ús, política usuaris | MCP-2, MCP-5, MCP-6 |
| **MCP-9** | admin-portal: flags globals/overrides, ús cross-tenant, kill switch UI | MCP-2, MCP-8 |
| **MCP-10** | audit_logs events + runbook + alertes | MCP-8, MCP-9 |
| **MCP-11** | WAF/proxy producció, rate limit distribuït, load test | MCP-7 |
| **MCP-12** | Canary 1–3 tenants + Go/No-Go | MCP-10, MCP-11 |

## Detall per epic

### MCP-0 — Disseny
- Threat model (IDOR tenant, confused deputy, key stuffing, DoS body).
- Llista **allowlist** de tools públiques (noms + dades exposades + base legal).
- Contracte errors HTTP vs MCP `isError`.
- Decidir URL shape: `/mcp/t/{tenantId}` vs slug; site opcional.

### MCP-1 — DDL
- Migracions amb capçalera de patró RLS real.
- RLS grants (humans sí, agents no).
- Job purge usage_logs (pg_cron o Edge cron).

### MCP-2 — Flags
- Seeds `mcp_*` a `feature_flags` (disabled).
- Helper `isMcpEffectivelyEnabled(tenant, mode)` compartit (Edge + portals si cal).

### MCP-3 — OAuth AS
- `[auth.oauth_server]` a config; asymmetric JWT.
- Ruta consent al tenant-portal; `getAuthorizationDetails` / approve / deny.
- Route `.well-known/oauth-protected-resource/...` (o middleware Edge).
- Registre clients (manual admin o DCR segons decisió producte; default: **sense DCR obert** en prod fins canary).

### MCP-4 — Skeleton MCP
- `WebStandardStreamableHTTPServerTransport` stateless, server per request.
- `verify_jwt = false`; auth interna.
- Health/readiness sense dades.

### MCP-5 — API keys
- RPC/Server Action crear (retorna secret **un cop**), llistar, revocar.
- Lookup prefix+hash; throttled `last_used_at`.

### MCP-6 — OAuth runtime
- Validació token + grant + flags.
- MFA policy documentada i implementada.
- Tests: session JWT → 401; grant altre tenant → 403.

### MCP-7 — Tools MVP
- Exemples típics (ajustar a allowlist): `list_projects`, `get_project`, `search_contacts` — tots scoped.
- Zero arguments `tenant_id`/`site_id` (venen del context).
- Proves SQL/integration d’aïllament multi-tenant.

### MCP-8 — tenant-portal UI
- Settings + política usuaris.
- API keys UX.
- Connected apps (llistar/revocar grants).
- Dashboard ús (agregats).

### MCP-9 — admin-portal UI
- Flags + overrides (com signing/recruitment).
- Vista ús per tenant + drill-down.
- Kill switch / motiu.

### MCP-10 — Audit + ops
- Events a `data.audit_logs`.
- Runbook: incident key leak, disable tenant, rotate secret.
- Alertes: p95, 5xx, 429, DB.

### MCP-11 — Edge prod
- Cloudflare (o equiv.) davant `MCP_PUBLIC_URL`.
- Upstash o WAF rules capa 2.
- Load test multi-tenant.

### MCP-12 — Canary
- 1–3 tenants, 24–72 h, checklist Go/No-Go de [`04-acceptance-and-gates.md`](./04-acceptance-and-gates.md).

## Fora d’abast / backlog futur

| Ítem | Nota |
|------|------|
| Tools write / propose | Després d’operar read-only |
| Billing MCP | Sobre usage_logs |
| DCR obert | Només si producte ho exigeix |
| Hosting Next route en lloc d’Edge | Alternativa si Edge limita SDK |
| MCP client al xat intern | Pla IA separat |

## Ordre recomanat de talls

1. **Tall A — Esquelet segur:** MCP-0…MCP-5 (+ una tool dummy).  
2. **Tall B — OAuth humà:** MCP-3, MCP-6, consent, grants.  
3. **Tall C — Producte portals:** MCP-7…MCP-9.  
4. **Tall D — Producció:** MCP-10…MCP-12.
