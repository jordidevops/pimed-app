# MCP — Acceptació i gates

## Llegenda de gates

Un tall no es tanca sense passar el gate. Un epic no es marca ✅ a [`STATUS.md`](./STATUS.md) sense els criteris de la seva fila.

---

## Gate 0 — Abans de codi (MCP-0)

- [ ] Threat model escrit (mínim: IDOR, confused deputy, key stuffing, DoS).
- [ ] Allowlist de tools públiques MVP acordada (≤ 5).
- [ ] Decisions tancades del [`README.md`](./README.md) sense excepcions silencioses.

---

## Criteris per epic

### MCP-1 DDL
- [ ] Migracions apliquen en net; RLS ON a taules noves exposades.
- [ ] Grants: agent amb `client_id` no pot SELECT/INSERT grants.
- [ ] Índexs de keys i usage presents.

### MCP-2 Flags
- [ ] Amb `mcp_enabled=false` global, qualsevol request MCP denegada.
- [ ] Override tenant OFF denega tot i quan global ON.
- [ ] Submode oauth OFF denega OAuth però pot deixar API keys si estan ON (i viceversa).

### MCP-3 OAuth AS + consent
- [ ] Metadata PRM accessible sense auth.
- [ ] Consent tria només tenants/sites permesos per política.
- [ ] Deny no crea grant; approve crea grant auditat.
- [ ] Re-auth auto-approve: connected apps pot revocar.

### MCP-4 Skeleton
- [ ] Body > límit → 413/400 abans de parsejar tot.
- [ ] CORS no és `*`.
- [ ] Stateless: dues requests seguides en “instàncies” diferents no depenen de memòria compartida de sessió MCP.

### MCP-5 API keys
- [ ] Secret visible un sol cop; BD només hash.
- [ ] Format invàlid no toca BD (o mètrica pre-auth).
- [ ] Key revocada / expirada → 401.
- [ ] Key d’un tenant no llegeix dades d’un altre (prova d’aïllament).

### MCP-6 OAuth runtime
- [ ] Session JWT sense `client_id` → 401.
- [ ] Token altre issuer → 401.
- [ ] Grant tenant A + URL tenant B → 403.
- [ ] Usuari fora allowlist/rols → no consent / 403.
- [ ] Membresia perduda → 403 tot i grant existent.

### MCP-7 Tools
- [ ] Cap tool write al catàleg públic MVP.
- [ ] Cap argument `tenantId`/`siteId` controlat pel model.
- [ ] Test automatitzat: usuari/key tenant A no veu files tenant B.
- [ ] Timeout tool controlat.

### MCP-8 tenant-portal
- [ ] Sense flag efectiu, UI MCP amagada o disabled.
- [ ] Crear/revocar key; llistar grants; veure ús propi.
- [ ] Canvis de settings generen `audit_logs`.

### MCP-9 admin-portal
- [ ] Toggle global + override per tenant + submodes.
- [ ] Vista ús agregada per tenant (oauth vs api_key).
- [ ] Kill switch documentat i operable.

### MCP-10 Audit + ops
- [ ] Events de cicle de vida a `data.audit_logs` (sense secrets).
- [ ] Runbook amb disable tenant, rotate `MCP_API_KEY_SECRET`, revocar grant massiu.
- [ ] Alertes mínimes configurades (o checklist staging).

### MCP-11 WAF + load
- [ ] Proxy `MCP_PUBLIC_URL` estable.
- [ ] Rate limit capa 2 **no** només in-memory Edge.
- [ ] Load test multi-tenant: sense cross-tenant leak; latència/error acceptables (definir números a MCP-0).

### MCP-12 Canary
- [ ] 1–3 tenants, 24–72 h sense incident P1.
- [ ] Checklist Go/No-Go completa (secció següent).

---

## Gate Tall A → B

Skeleton + API key + 1 tool dummy en staging; aïllament verificat; OAuth encara pot estar OFF.

## Gate Tall B → C

OAuth end-to-end amb un client real (p.ex. MCP Inspector / Claude); grants + revocació OK.

## Gate Tall C → D

Portals usables; audit events; allowlist tools reals (no dummy).

## Gate producció (Go / No-Go)

**No-Go** si falta qualsevol:

- [ ] WAF/proxy en enforce
- [ ] `MCP_API_KEY_SECRET` robust sense fallback
- [ ] Flags default OFF; canary explícit
- [ ] Alertes + runbook
- [ ] Prova aïllament tenant/site registrada
- [ ] Load test acceptat
- [ ] JWT sessió rebutjat per test

**Go controlat:** canary → monitoratge → lots progressius.
