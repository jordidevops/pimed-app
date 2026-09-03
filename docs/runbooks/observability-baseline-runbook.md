# Runbook: Observabilitat baseline (Fase 0)

**Data:** 2026-06-20  
**Relacionat:** [`docs/plans/Sentry/plan.md`](../plans/Sentry/plan.md)

---

## 1. On mirar quan alguna cosa falla

| Símptoma | Primer lloc | Segon lloc |
|----------|-------------|------------|
| Usuari reporta error a la UI | Supabase → Edge Functions → Logs (filtrar per `feature`) | Sentry (issues recents) |
| Email no arriba | `data.email_logs` / worker logs | `/settings/operations` (tenant) quan UI estigui activa |
| IA no respon | Logs `ai-chat-turn` | Sentry + `ai_usage_ledger` |
| Tot lent | Logs `durationMs` / `timedCall` | Supabase → Database → Logs |
| Plataforma caiguda | UptimeRobot alert | `GET /functions/v1/health?check=ready` |

---

## 2. Monitors externs (UptimeRobot / Better Uptime)

Configurar manualment al dashboard del proveïdor:

| Nom | URL | Mètode | Interval | Timeout | Alerta |
|-----|-----|--------|----------|---------|--------|
| Supabase REST | `https://<project-ref>.supabase.co/rest/v1/` | GET | 1 min | 10s | Email + Slack |
| Tenant portal | `https://<domini-app>/` | GET | 1 min | 15s | Email + Slack |
| Admin portal | `https://<domini-admin>/` | GET | 1 min | 15s | Email + Slack |
| Health live | `https://<project-ref>.supabase.co/functions/v1/health?check=live` | GET | 1 min | 5s | Email + Slack |
| Health ready | `https://<project-ref>.supabase.co/functions/v1/health?check=ready` | GET | 1 min | 10s | Keyword `ok` |

**Local dev:** `http://127.0.0.1:54321/functions/v1/health?check=ready`

---

## 3. Alertes natives Supabase (Dashboard)

Project Settings → Alerts (Pro/Team):

| Mètrica | Llindar recomanat |
|---------|-------------------|
| CPU | > 80% durant 5 min |
| Connexions DB | > 80% del pool |
| Storage | > 85% del pla |

---

## 4. Enllaços ràpids per entorn

| Recurs | Local | Staging | Producció |
|--------|-------|---------|-----------|
| Edge Function logs | Studio → Functions | Dashboard Supabase | Dashboard Supabase |
| Database logs | Studio → Logs | Dashboard | Dashboard |
| Sentry | — | projecte staging | projecte prod |
| Health ready | `localhost:54321/functions/v1/health?check=ready` | `<ref>.supabase.co/...` | idem |

Omplir columnes staging/prod quan estiguin definides.

---

## 5. Qui rep alertes

| Tipus | Canal | Responsable |
|-------|-------|-------------|
| Uptime down | Email + Slack `#alerts-prod` | Dev on-duty |
| Sentry P1 (new issue prod) | Slack `#alerts-prod` | Dev lead |
| SLO violat | Revisió manual diària | Dev lead |

---

## 6. `pg_stat_statements`

```sql
SELECT calls, mean_exec_time, query
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 10;
```

Activar extensió si cal: `CREATE EXTENSION IF NOT EXISTS pg_stat_statements;`

---

## 7. Checklist Fase 0

Guia pas a pas: [`fase-0-manual-setup.md`](fase-0-manual-setup.md)  
Script verificació: `node scripts/verify-phase0-observability.mjs`

- [ ] Monitors UptimeRobot creats (REST + portals + health) — staging + prod
- [ ] Alertes Supabase CPU/connexions configurades
- [ ] Projecte Sentry staging + prod creats
- [ ] `SENTRY_DSN` + `ENVIRONMENT` als secrets del projecte (no al repo)
- [ ] Slack `#alerts-prod` connectat a Sentry i UptimeRobot
- [ ] `pg_stat_statements` revisat (top 15)
- [ ] §4 d'aquest runbook omplert amb URLs reals
- [ ] Aquest runbook revisat per l'equip
