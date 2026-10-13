# Guia MCP — Hardening de producció (referència)

> **Estat:** referència històrica de principis de seguretat.  
> **Pla d’implementació actual (manen les decisions noves):** [`README.md`](./README.md) · [`EXECUTION.md`](./EXECUTION.md) · [`STATUS.md`](./STATUS.md)  
> **Arquitectura:** [`01-architecture-and-security.md`](./01-architecture-and-security.md)  
> **Bootstrap oficial:** [Library headless MCP](https://supabase.com/library/docs/headless/mcp) — `npx shadcn@latest add @supabase/mcp`

Aquest fitxer conserva els **errors apresos** i el checklist de hardening.  
**No** seguir auth antiga (JWT secundari). Model vigent: **OAuth extern** (`client_id`) + **API keys S2S**.

---

## Principis no negociables

1. Aïllament multi-tenant a **SQL** (`tenant_id` / `site_id` al `WHERE`).
2. Defensa en profunditat: auth + RLS + validació + rate limit + WAF.
3. Fail-closed si falta secret, context, flag o `client_id` (path OAuth).
4. Producció només amb capa edge/WAF (no Compute per MCP MVP).
5. Observabilitat i runbook abans del rollout global.
6. Sense `supabaseAdmin` al ToolContext.

## Errors típics a evitar

1. Rate limit massa tard.  
2. Lookup SQL per qualsevol string amb prefix de key.  
3. Body / resposta sense límit.  
4. Filtrat de `site_id` en memòria.  
5. CORS `*`.  
6. Secrets amb fallback.  
7. Rate limit només in-memory a Edge.  
8. `last_used_at` UPDATE a cada request.  
9. Confiar en `withSupabase({ auth: 'user' })` sense gate `client_id`.  
10. Copiar registry JSON en lloc de `shadcn add`.

## Auth vigent (resum)

| Mode | Ús |
|------|-----|
| API key `mcp_live_` / `mcp_test_` | Server-to-server |
| OAuth 2.1 + PKCE (`client_id` + grants) | Clients MCP externs |
| Session JWT (embedded Library) | **No** a l’endpoint públic |

## Rate limiting / observabilitat / Go-No-Go

Veure [`01-architecture-and-security.md`](./01-architecture-and-security.md) i [`04-acceptance-and-gates.md`](./04-acceptance-and-gates.md).

## Prompt per a l’agent

Preferir el prompt combinat a [`EXECUTION.md`](./EXECUTION.md) (Library + fase activa PiMed). Resum:

```
Llegeix https://supabase.com/library/docs/headless/mcp.md i docs/plans/mcp_server/EXECUTION.md.
Fes només la fase activa. Prefer shadcn @supabase/mcp. Capa PiMed a damunt.
No session JWT al MCP públic. No supabaseAdmin al ToolContext.
```
