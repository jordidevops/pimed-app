# MCP Server — Estat d’implementació

> **Última actualització:** 2026-09-15  
> **Propòsit:** seguir el desenvolupament dels epics MCP i deixar constància honesta del que falta.  
> **Pla:** [`README.md`](./README.md) · backlog [`03-phases-and-backlog.md`](./03-phases-and-backlog.md) · ordre [`EXECUTION.md`](./EXECUTION.md)

## Llegenda

| Símbol | Significat |
|--------|------------|
| ✅ | Fet i usable |
| 🔄 | En curs |
| ❌ | No començat |
| ⚠️ | Parcial |
| 📦 | Diferit |

---

## Resum

**Pla documental creat.** Cap runtime MCP implementat. Fase activa: **MCP-0**.

Auth acordat: OAuth usuaris + API keys S2S; sense JWT sessió. Controls: admin global/per-tenant/submodes + tenant self-serve + usage + `audit_logs`.

---

## Tall A — Esquelet segur (S2S)

| Epic | Nom | Estat | Notes |
|------|-----|-------|-------|
| MCP-0 | Disseny / threat model / allowlist | ❌ | Fase activa |
| MCP-1 | DDL + RLS + purge | ❌ | |
| MCP-2 | Feature flags + kill switch | ❌ | |
| MCP-4 | Edge skeleton Streamable HTTP | ❌ | |
| MCP-5 | Auth API key S2S | ❌ | |

## Tall B — OAuth humà

| Epic | Nom | Estat | Notes |
|------|-----|-------|-------|
| MCP-3 | OAuth Server + consent + PRM | ❌ | |
| MCP-6 | Auth OAuth + grants | ❌ | |

## Tall C — Producte portals + tools

| Epic | Nom | Estat | Notes |
|------|-----|-------|-------|
| MCP-7 | Tools read-only MVP | ❌ | |
| MCP-8 | tenant-portal UI | ❌ | |
| MCP-9 | admin-portal UI | ❌ | |

## Tall D — Producció

| Epic | Nom | Estat | Notes |
|------|-----|-------|-------|
| MCP-10 | audit_logs + runbook + alertes | ❌ | |
| MCP-11 | WAF + rate limit + load test | ❌ | |
| MCP-12 | Canary + Go/No-Go | ❌ | |

---

## Changelog

| Data | Canvi |
|------|-------|
| 2026-09-15 | Creat paquet documental MCP (README, arquitectura, DDL, fases, acceptació, EXECUTION, STATUS). Decisions: OAuth+API keys, sense JWT sessió, jerarquia admin, usage + audit_logs. |
