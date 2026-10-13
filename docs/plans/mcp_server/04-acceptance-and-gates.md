# MCP — Acceptació i gates

## Llegenda de gates

Un tall no es tanca sense passar el gate. Un epic no es marca ✅ a [`STATUS.md`](./STATUS.md) sense els criteris de la seva fila.

---

## Gate 0 — Abans de codi (MCP-0)

- [ ] Threat model escrit (IDOR, confused deputy, key stuffing, DoS, DCR abuse).
- [ ] Allowlist de tools públiques MVP acordada (≤ 5, **read-only**).
- [ ] Decisions tancades del [`README.md`](./README.md) sense excepcions silencioses (incl. DCR ON, external-only, no Compute).
- [ ] Prerequisits Library anotats: CLI ≥ 2.117, pla JWT asimètric.

---

## Criteris per epic

### MCP-1 DDL
- [ ] Migracions apliquen en net; RLS ON a taules noves exposades.
- [ ] Grants: agent amb `client_id` no pot SELECT/INSERT grants.
- [ ] Índexs de keys i usage presents; `site_id` NULL no trenca unicitat activa.

### MCP-2 Flags
- [ ] Amb `mcp_enabled=false` global, qualsevol request MCP denegada.
- [ ] Override tenant OFF denega tot i quan global ON.
- [ ] Submode oauth OFF denega OAuth però pot deixar API keys si estan ON (i viceversa).

### MCP-3 OAuth AS + Consent
- [ ] `[auth.oauth_server]` + DCR ON desplegats (`config push`).
- [ ] Consent accessible a Site URL; deny no crea grant; approve crea grant auditat.
- [ ] Consent tria només tenants/sites permesos (capa PiMed).
- [ ] Client MCP pot registrar-se via DCR (staging).
- [ ] Re-auth auto-approve: connected apps pot revocar.

### MCP-4 Skeleton (Library)
- [ ] Funció instal·lada via `npx shadcn@latest add @supabase/mcp` (no còpia manual del JSON).
- [ ] `verify_jwt = false`; `deno task check` verd.
- [ ] PRM accessible: `/functions/v1/mcp/oauth-protected-resource` (o path equivalent).
- [ ] Body > límit → rebuig abans de parsejar tot.
- [ ] CORS no és `*`.
- [ ] Stateless / server per request.
- [ ] ToolContext **sense** `supabaseAdmin`.

### MCP-5 API keys
- [ ] Secret visible un sol cop; BD només hash.
- [ ] Format invàlid no toca BD (o mètrica pre-auth).
- [ ] Key revocada / expirada → 401.
- [ ] Key d’un tenant no llegeix dades d’un altre.

### MCP-6 OAuth runtime PiMed
- [ ] Session JWT sense `client_id` → **401** (tot i `withSupabase` vàlid).
- [ ] Token altre issuer → 401.
- [ ] Grant tenant A + resource tenant B → 403.
- [ ] Usuari fora allowlist/rols → no consent / 403.
- [ ] Membresia perduda → 403 tot i grant existent.
- [ ] Si custom domain: `authorization_servers` PRM == issuer Auth (`MCP_AUTH_ISSUER`).

### MCP-7 Tools
- [ ] Cap tool write al catàleg públic MVP.
- [ ] Cap argument `tenantId`/`siteId` controlat pel model.
- [ ] Caps de files/bytes de resposta aplicats.
- [ ] Test aïllament multi-tenant automatitzat.
- [ ] Timeout tool controlat.

### MCP-8 tenant-portal
- [ ] Sense flag efectiu, UI MCP amagada o disabled.
- [ ] Crear/revocar key; llistar/revocar grants; veure ús propi.
- [ ] Canvis de settings generen `audit_logs`.

### MCP-9 admin-portal
- [ ] Toggle global + override per tenant + submodes.
- [ ] Vista ús agregada per tenant (oauth vs api_key).
- [ ] Kill switch documentat i operable.

### MCP-10 Audit + ops
- [ ] Events de cicle de vida a `data.audit_logs` (sense secrets).
- [ ] Runbook: disable tenant, rotate secret, revocar grant/key, clients DCR.
- [ ] Alertes mínimes (o checklist staging).

### MCP-11 WAF + load
- [ ] Proxy / URL estable en enforce.
- [ ] Rate limit capa 2 **no** només in-memory Edge.
- [ ] Load test multi-tenant acceptat (números de MCP-0).

### MCP-12 Canary
- [ ] 1–3 tenants, 24–72 h sense incident P1.
- [ ] Checklist Go/No-Go completa.

---

## Gate Tall A → B

Library skeleton + API key + 1 tool dummy; aïllament verificat; OAuth encara pot estar OFF.

## Gate Tall B → C

OAuth E2E amb client real (MCP Inspector / Claude); DCR + consent + gate `client_id`; revocació OK.

## Gate Tall C → D

Portals usables; audit; allowlist tools reals (no dummy).

## Gate producció (Go / No-Go)

**No-Go** si falta qualsevol:

- [ ] WAF/proxy en enforce
- [ ] JWT asimètric en prod
- [ ] `MCP_API_KEY_SECRET` robust sense fallback
- [ ] Flags default OFF; canary explícit
- [ ] Alertes + runbook
- [ ] Prova aïllament tenant/site registrada
- [ ] Load test acceptat
- [ ] Session JWT rebutjat per test automatitzat
- [ ] DCR monitordat / UI revoke operativa

**Go controlat:** canary → monitoratge → lots progressius.
