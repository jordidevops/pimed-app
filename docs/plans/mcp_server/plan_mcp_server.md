# Guia MCP — Hardening de producció (referència)

> **Estat:** referència històrica de principis de seguretat.  
> **Pla d’implementació actual (manen les decisions noves):** [`README.md`](./README.md) · [`EXECUTION.md`](./EXECUTION.md) · [`STATUS.md`](./STATUS.md)  
> **Arquitectura actualitzada:** [`01-architecture-and-security.md`](./01-architecture-and-security.md)

Aquest fitxer conserva els **errors apresos** i el checklist de hardening.  
**No** seguir la secció d’auth antiga (JWT secundari): el model vigent és **OAuth usuaris + API keys S2S**.

---

## Principis no negociables

1. Aïllament multi-tenant a **SQL** (`tenant_id` / `site_id` al `WHERE`).
2. Defensa en profunditat: auth + RLS + validació + rate limit + WAF.
3. Fail-closed si falta secret, context o flag.
4. Producció només amb capa edge/WAF.
5. Observabilitat i runbook abans del rollout global.

## Errors típics a evitar

1. Rate limit massa tard (després de queries d’auth).  
2. Lookup SQL per qualsevol string amb prefix de key.  
3. Body sense límit.  
4. Filtrat de `site_id` en memòria.  
5. CORS `*`.  
6. Secrets amb fallback insegur.  
7. Rate limit “in-memory” en Edge multi-instància.  
8. `last_used_at` UPDATE a cada request (hot row).  
9. Acceptar JWT de sessió portal sense `client_id`.

## Auth vigent (resum)

| Mode | Ús |
|------|-----|
| API key `mcp_live_` / `mcp_test_` | Server-to-server |
| OAuth 2.1 + PKCE (`client_id` + grants) | Usuaris app → agents |
| JWT sessió + `X-Tenant-Id` | **Eliminat** |

Detall: [`01-architecture-and-security.md`](./01-architecture-and-security.md).

## Rate limiting

1. WAF  
2. Store distribuït (Upstash/Redis) o regles WAF per fingerprint  
3. Quotes de negoci a BD / settings tenant  

## Observabilitat

- Requests: `mcp_usage_logs`  
- Cicle de vida: `data.audit_logs`  
- Admin: ús cross-tenant; tenant: ús propi  

## Go / No-Go

Veure [`04-acceptance-and-gates.md`](./04-acceptance-and-gates.md).

## Prompt per a l’agent implementador

```
Implementa el servidor MCP seguint docs/plans/mcp_server/EXECUTION.md i STATUS.md.
Només la fase activa. Actualitza STATUS i el registre d'EXECUTION en tancar.
Prioritza seguretat multi-tenant i fail-closed. No acceptis JWT de sessió al MCP.
```
