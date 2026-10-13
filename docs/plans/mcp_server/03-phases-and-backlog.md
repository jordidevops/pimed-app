# MCP — Fases i backlog

> Ordre operatiu: [`EXECUTION.md`](./EXECUTION.md) · estat: [`STATUS.md`](./STATUS.md)  
> Bootstrap: [Library headless MCP](https://supabase.com/library/docs/headless/mcp)

## Epics

| Epic | Nom | Dependències |
|------|-----|--------------|
| **MCP-0** | Decisions, threat model, allowlist, prerequisits Library (CLI/JWKS) | — |
| **MCP-1** | DDL: settings, keys, grants, usage_logs, índexs, retenció | MCP-0 |
| **MCP-2** | Feature flags + kill switch + avaluació efectiva | MCP-1 |
| **MCP-3** | OAuth Server + Consent Library + DCR ON + Site URL | MCP-1 |
| **MCP-4** | `shadcn @supabase/mcp` + pre-auth PiMed + `verify_jwt=false` | MCP-1, MCP-2 |
| **MCP-5** | Auth API key S2S | MCP-4 |
| **MCP-6** | Gate `client_id` + grants + flags + user-scoped tools | MCP-3, MCP-4 |
| **MCP-7** | Tools read-only MVP + tests aïllament + caps resposta | MCP-5 o MCP-6 |
| **MCP-8** | tenant-portal: settings, keys, connected apps, ús, política | MCP-2, MCP-5, MCP-6 |
| **MCP-9** | admin-portal: flags, ús cross-tenant, kill switch UI | MCP-2, MCP-8 |
| **MCP-10** | audit_logs + runbook + alertes | MCP-8, MCP-9 |
| **MCP-11** | WAF/proxy, rate limit distribuït, load test | MCP-7 |
| **MCP-12** | Canary 1–3 tenants + Go/No-Go | MCP-10, MCP-11 |

## Detall per epic

### MCP-0 — Disseny
- Threat model (IDOR, confused deputy, key stuffing, DoS, DCR abuse).
- Allowlist tools públiques read-only + GDPR.
- Prerequisits: CLI ≥ 2.117, pla JWT asimètric.
- URL shape; llindars load test.
- DCR **ON** (no OFF fins canary).

### MCP-1 — DDL
- Migracions + RLS grants (agents no llegeixen/amplien).
- Índex únic parcial amb `site_id` NULL tractat correctament.
- Purge usage_logs.

### MCP-2 — Flags
- Seeds `mcp_*` disabled.
- Helper `isMcpEffectivelyEnabled(tenant, mode)`.

### MCP-3 — OAuth AS + Consent
- `[auth.oauth_server]` + `allow_dynamic_registration = true`.
- Instal·lar OAuth Consent block (Library); adaptar a Vite `tenant-portal`.
- Site URL = origen del consent; `supabase config push`.
- Monitoring clients registrats + UI revoke.

### MCP-4 — Skeleton (Library first)
- `npx shadcn@latest add @supabase/mcp` — **no** copiar registry JSON.
- `[functions.mcp] verify_jwt = false`.
- `deno task check`; `.env` MCP_SERVER_NAME/DESCRIPTION.
- Pre-auth PiMed (body limit, rate limit).
- **No** Supabase Compute.

### MCP-5 — API keys
- Crear (secret un cop), llistar, revocar.
- Branca auth S2S al costat del pipeline user.

### MCP-6 — OAuth runtime PiMed
- Gate: sense `client_id` → 401 (session JWT rebutjat).
- Grants + flags + membresia.
- Tests confused deputy i cross-tenant.
- Revoke grant portal ⇒ també revoke a AS Supabase quan es pugui.

### MCP-7 — Tools MVP
- Només read-only allowlist; `registerXTools`; sense admin.
- Caps `max_rows` / `max_response_bytes`.
- Zero `tenant_id`/`site_id` com a arguments del model.
- **No** copiar `create_todo` / write del tutorial.

### MCP-8 — tenant-portal
- Settings, keys, connected apps, ús, política usuaris.
- Picker tenant/site al consent (damunt del Consent genèric).

### MCP-9 — admin-portal
- Flags + overrides; ús cross-tenant; kill switch.

### MCP-10 — Audit + ops
- Events `data.audit_logs`; runbook; alertes.

### MCP-11 — Edge prod
- WAF davant URL estable; Upstash; load test.
- `MCP_AUTH_ISSUER` si custom domain.

### MCP-12 — Canary
- 1–3 tenants, 24–72 h; Go/No-Go.

## Fora d’abast / backlog futur

| Ítem | Nota |
|------|------|
| Tools write / propose | Després d’operar read-only |
| Embedded session JWT via MCP | Library ho documenta; PiMed usa xat intern |
| Billing MCP | Sobre usage_logs |
| Hosting Next / Compute | Edge és el default; Compute no per MCP MVP |
| MCP client al xat | Pla IA separat |

## Ordre de talls

1. **Tall A:** MCP-0…MCP-5 (+ tool dummy).  
2. **Tall B:** MCP-3, MCP-6.  
3. **Tall C:** MCP-7…MCP-9.  
4. **Tall D:** MCP-10…MCP-12.
