# MCP Server — Pla mestre d’execució (agent IA)

> **Rol:** única font de veritat de l’ordre d’implementació i del treball pendent  
> **Creat:** 2026-09-15 · **Actualitzat:** 2026-10-13 (Library headless MCP + SELECT 2026)  
> **Pla:** [`README.md`](./README.md) · estat: [`STATUS.md`](./STATUS.md) · acceptació: [`04-acceptance-and-gates.md`](./04-acceptance-and-gates.md)  
> **Fase activa:** **MCP-0** Disseny i threat model  
> **Anterior:** — (pla documental)

---

## Disciplina (obligatòria per a l’agent)

1. Llegir **aquest fitxer** i [`STATUS.md`](./STATUS.md) a l’**inici de cada conversa** d’implementació.
2. Abans del primer codi MCP: llegir [Library headless MCP](https://supabase.com/library/docs/headless/mcp.md).
3. Treballar **només** la fase activa, o un ítem de backlog acordat **explícitament** per l’usuari.
4. No reobrir decisions de [`README.md`](./README.md) § «Decisions tancades» sense documentar-ho al changelog.
5. Preferir editar la migració font mentre no hi hagi producció.
6. En tancar un epic: STATUS ✅/⚠️ → registre aquí → avançar fase activa → criteris de [`04-acceptance-and-gates.md`](./04-acceptance-and-gates.md).
7. Cicle de vida → `data.audit_logs`.
8. No commit/push tret que l’usuari ho demani.
9. No tools write al MVP; no session JWT a l’endpoint públic; no `supabaseAdmin` al ToolContext.
10. Instal·lar el bloc amb **shadcn**, no enganxar fitxers des del registry JSON.

### Prompt de continuació (fases PiMed)

```
Continua el pla MCP a docs/plans/mcp_server/.
Llegeix EXECUTION.md + STATUS.md. Implementa només la fase activa.
Al acabar: actualitza STATUS, registre d'EXECUTION i criteris d'acceptació.
```

### Prompt bootstrap Library (+ capa PiMed)

Usar quan s’obri MCP-3/MCP-4 (primer cop que es toquen fitxers `supabase/functions/mcp`):

```
Help me add MCP Server from Supabase Library to this monorepo.
Read https://supabase.com/library/docs/headless/mcp.md first.
Inspect project structure; reuse existing Supabase setup.
Prefer `npx shadcn@latest add @supabase/mcp` (and OAuth Consent block) over copying registry JSON.
Then follow docs/plans/mcp_server/EXECUTION.md: only the active phase; PiMed layers
(client_id gate, tenant grants, API keys S2S, flags, read-only allowlist) on top of the Library block.
Do not allow session JWTs on the public MCP endpoint; do not add supabaseAdmin to ToolContext.
```

El prompt Library **instal·la el bloc**; aquest fitxer **ordena les fases PiMed**. Es combinen; no es substitueixen.

---

## Ordre real

| Ordre | Epic | Estat | Nota |
|------:|------|-------|------|
| 1 | **MCP-0** Disseny / threat model / allowlist tools | ❌ | **Fase activa** |
| 2 | **MCP-1** DDL + RLS + purge | ❌ | |
| 3 | **MCP-2** Feature flags + kill switch + helper efectiu | ❌ | |
| 4 | **MCP-4** Edge: `shadcn @supabase/mcp` + pre-auth PiMed | ❌ | Bootstrap Library |
| 5 | **MCP-5** Auth API key S2S | ❌ | Tall A |
| — | *Gate Tall A → B* | ❌ | Key + tool dummy + aïllament |
| 6 | **MCP-3** OAuth Server + Consent block + DCR ON | ❌ | |
| 7 | **MCP-6** Gate `client_id` + grants + flags | ❌ | Tall B |
| — | *Gate Tall B → C* | ❌ | OAuth E2E |
| 8 | **MCP-7** Tools read-only MVP | ❌ | |
| 9 | **MCP-8** tenant-portal UI | ❌ | |
| 10 | **MCP-9** admin-portal UI | ❌ | Tall C |
| — | *Gate Tall C → D* | ❌ | |
| 11 | **MCP-10** audit_logs + runbook + alertes | ❌ | |
| 12 | **MCP-11** WAF + rate limit distribuït + load test | ❌ | |
| 13 | **MCP-12** Canary + Go/No-Go | ❌ | Tall D |

Nota: MCP-3 va després de MCP-5 a l’ordre operatiu (Tall A = S2S primer). DDL (MCP-1) ja inclou `mcp_client_grants`.

---

## Fase activa: MCP-0 — Disseny

### Objectiu
Tancar el contracte abans de migracions: riscos, URL, tools públiques, números de load test, prerequisits Library.

### Tasques concretes (checklist agent)

- [ ] Releer [`01-architecture-and-security.md`](./01-architecture-and-security.md) i [`02-data-model.md`](./02-data-model.md).
- [ ] Confirmar prerequisits: CLI ≥ 2.117; pla de migració a JWT asimètric; sense `[auth.oauth_server]` avui → caldrà a MCP-3.
- [ ] Escriure threat model curt (annex o secció a `01-…`): IDOR, confused deputy (session JWT), key stuffing, DoS body/resposta, DCR abuse.
- [ ] Proposar allowlist MVP (1–3 tools **read-only**) amb columnes i notes GDPR; OK humà si cal. **No** `search_contacts` massiu sense DPIA.
- [ ] Fixar shape d’URL del resource (`functions/v1/mcp` vs proxy `/mcp` + tenant path).
- [ ] Fixar llindars load test (RPS, error rate, p95) per Gate MCP-11.
- [ ] Confirmar: **DCR ON** + monitoring/revoke (no OFF fins canary).
- [ ] Confirmar: MCP públic = external OAuth + API keys; embedded session = fora d’abast.

### Criteri de tancament
Gate 0 de [`04-acceptance-and-gates.md`](./04-acceptance-and-gates.md) complet.

### Següent
MCP-1 DDL.

---

## Guia ràpida per fase (referència)

### MCP-1
Migracions segons [`02-data-model.md`](./02-data-model.md); RLS grants; índexs `site_id` NULL correctes; purge usage.

### MCP-2
Seeds flags `mcp_*`; helper efectiu; kill switch.

### MCP-4
1. `npx shadcn@latest add @supabase/mcp` (no copiar JSON).  
2. `[functions.mcp] verify_jwt = false`.  
3. Excloure `supabase/functions/**` als tsconfig dels apps si cal.  
4. `deno task check`; serve amb `.env` (`MCP_SERVER_NAME`, …).  
5. Capa PiMed: body limit, pre-auth rate limit, sense tools write.

### MCP-5
API keys: secret un cop; hash; tests aïllament; branca auth al costat del pipeline user.

### MCP-3
`[auth.oauth_server]` + DCR ON; instal·lar **OAuth Consent** Library i adaptar a Vite (`tenant-portal`); Site URL; `supabase config push`.

### MCP-6
Gate `client_id`; grants; flags; tests: session JWT → 401; grant wrong tenant → 403.  
Revoke també via grants OAuth de Supabase quan es revoqui al portal.

### MCP-7
Només allowlist read-only; `registerXTools`; context sense admin; caps files/bytes; tests aïllament.

### MCP-8 / MCP-9
UI i18n; connected apps; usage; flags admin.

### MCP-10 … MCP-12
Audit + runbook; WAF/Upstash; canary; Go/No-Go. **No** hostejar a Compute.

---

## Registre de treball

| Data | Epic | Què s’ha fet | Què ha quedat pendent |
|------|------|--------------|------------------------|
| 2026-09-15 | — | Paquet documental pla MCP; decisions auth híbrida | MCP-0 |
| 2026-10-13 | — | Actualització documental: Library headless MCP + SELECT 2026 (bootstrap shadcn, DCR ON, gate `client_id`, prompt combinat) | MCP-0 |
