# Fase 0 manual — Sentry + UptimeRobot + Supabase Alerts

**Temps estimat:** 2–4 hores (primera vegada)  
**Cost:** 0 € (plans gratuïts)  
**Relacionat:** [`plan.md`](../plans/Sentry/plan.md) · [`observability-baseline-runbook.md`](observability-baseline-runbook.md) · [`sentry-alerts-runbook.md`](sentry-alerts-runbook.md)

---

## Abans de començar

1. Copia `.supabase-refs.example` → `.supabase-refs` i omple `STAGING_REF` / `PROD_REF`.
2. Tens accés admin als projectes Supabase staging i prod.
3. Compte Sentry (org) i UptimeRobot (o Better Uptime) creats.
4. Canal Slack `#alerts-prod` (o equivalent) creat.

### Verificació local prèvia

```powershell
# Des de l'arrel — health ha de respondre 200
node scripts/verify-phase0-observability.mjs
```

---

## Pas 1 — UptimeRobot (5 monitors per entorn)

Dashboard: [uptimerobot.com/dashboard](https://uptimerobot.com/dashboard) → **Add New Monitor**

Substitueix `<staging-ref>` / `<prod-ref>` pels valors de `.supabase-refs`.

### Staging (repetir bloc sencer amb URLs staging)

| # | Nom del monitor | Tipus | URL | Interval | Timeout | Alert contacts |
|---|-----------------|-------|-----|----------|---------|----------------|
| 1 | `[STG] Supabase REST` | HTTP(s) | `https://<staging-ref>.supabase.co/rest/v1/` | 1 min | 10s | Email + Slack |
| 2 | `[STG] Health live` | HTTP(s) | `https://<staging-ref>.supabase.co/functions/v1/health?check=live` | 1 min | 5s | Email + Slack |
| 3 | `[STG] Health ready` | HTTP(s) | `https://<staging-ref>.supabase.co/functions/v1/health?check=ready` | 1 min | 10s | Email + Slack |
| 4 | `[STG] Tenant portal` | HTTP(s) | URL Vercel staging tenant | 1 min | 15s | Email + Slack |
| 5 | `[STG] Admin portal` | HTTP(s) | URL Vercel staging admin | 1 min | 15s | Email + Slack |

**Monitor #3 (ready):** a UptimeRobot → Advanced → **Keyword exists** → `"status":"ok"` (alerta si 503 o JSON sense ok).

### Producció

Mateixa taula amb prefix `[PROD]` i refs/URLs de producció.

### Integració Slack (UptimeRobot)

1. My Settings → **Alert Contacts** → Add → Slack.
2. Enganxa el webhook al canal `#alerts-prod`.
3. Assigna el contacte als 5 monitors de prod (staging pot usar un canal `#alerts-staging`).

### Prova

1. Desactiva temporalment un monitor staging → rep alerta.
2. Reactiva i confirma **Up**.

---

## Pas 2 — Sentry (2 projectes)

Dashboard: [sentry.io](https://sentry.io) → **Create Project**

| Projecte | Platform | `environment` tag (via secret) |
|----------|----------|--------------------------------|
| `pimed-staging` | Deno (Edge Functions) + React (frontends) | `staging` |
| `pimed-prod` | idem | `production` |

Per cada projecte:

1. **Settings → Client Keys (DSN)** — copia el DSN (no al repo).
2. **Settings → Alerts** — segueix [`sentry-alerts-runbook.md`](sentry-alerts-runbook.md):
   - Issue alert: new issue + `environment:production` → Slack `#alerts-prod`
   - Regression → Slack
   - Spike same issue (>10 events / 5 min)
3. **Settings → Integrations → Slack** — connecta l'org.
4. **Settings → General** — activa **Weekly Report** (email dev lead).

### Secrets Supabase (Edge Functions, per projecte cloud)

```powershell
# Staging
supabase secrets set SENTRY_DSN="https://xxx@oYYY.ingest.sentry.io/ZZZ" --project-ref <staging-ref>
supabase secrets set ENVIRONMENT=staging --project-ref <staging-ref>

# Producció
supabase secrets set SENTRY_DSN="https://..." --project-ref <prod-ref>
supabase secrets set ENVIRONMENT=production --project-ref <prod-ref>
```

### Variables Vercel (frontends React)

| App | Variable | Valor |
|-----|----------|-------|
| tenant-portal | `VITE_SENTRY_DSN` | DSN projecte Sentry (client) |
| tenant-portal | `VITE_APP_ENVIRONMENT` | `staging` / `production` |
| admin-portal | `NEXT_PUBLIC_SENTRY_DSN` | DSN projecte Sentry (client) |
| admin-portal | `NEXT_PUBLIC_APP_ENVIRONMENT` | `staging` / `production` |

En local deixar buit — el facade fa fallback a console.

### Smoke test Sentry (staging, després de desplegar functions)

```powershell
# Crida manual a una EF de prova o health amb error injectat (staging only)
# Verifica issue a Sentry → projecte pimed-staging → environment:staging
```

Checklist detallada: [`sentry-alerts-runbook.md`](sentry-alerts-runbook.md) §7.

---

## Pas 3 — Alertes natives Supabase

Per **cada** projecte (staging + prod):

Dashboard → **Project Settings → Infrastructure → Usage** / **Alerts** (segons pla Pro/Team)

| Alerta | Llindar | Acció |
|--------|---------|-------|
| CPU | > 80% durant 5 min | Email equip |
| Connexions DB | > 80% del pool | Email equip |
| Storage | > 85% del pla | Email equip |

Enllaços directes (substitueix ref):

- Staging logs EF: `https://supabase.com/dashboard/project/<staging-ref>/functions`
- Prod logs EF: `https://supabase.com/dashboard/project/<prod-ref>/functions`
- Database logs: `https://supabase.com/dashboard/project/<ref>/logs/postgres-logs`

---

## Pas 4 — Revisió `pg_stat_statements`

SQL Editor (staging primer, després prod si cal):

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

SELECT
  calls,
  round(mean_exec_time::numeric, 2) AS mean_ms,
  round(total_exec_time::numeric, 2) AS total_ms,
  left(query, 120) AS query_preview
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 15;
```

Documenta queries > 500 ms mitjana a un issue de backlog si cal index.

---

## Pas 5 — Omplir runbook baseline

Actualitza [`observability-baseline-runbook.md`](observability-baseline-runbook.md) §4 amb URLs reals:

| Recurs | Staging | Producció |
|--------|---------|-----------|
| Supabase dashboard | `https://supabase.com/dashboard/project/<staging-ref>` | idem prod |
| Sentry | `https://<org>.sentry.io/projects/pimed-staging/` | `.../pimed-prod/` |
| UptimeRobot | enllaç al dashboard del grup STG | enllaç PROD |
| Tenant portal | URL Vercel | URL Vercel |
| Admin portal | URL Vercel | URL Vercel |

---

## Pas 6 — Verificació final

```powershell
$env:STAGING_REF = "<staging-ref>"
$env:PROD_REF = "<prod-ref>"
$env:TENANT_PORTAL_URL_STAGING = "https://..."
$env:ADMIN_PORTAL_URL_STAGING = "https://..."
# (opcional prod URLs)
node scripts/verify-phase0-observability.mjs
```

---

## Checklist sign-off

Marca quan completat (copia a PR o issue):

- [ ] 5 monitors UptimeRobot **staging** actius
- [ ] 5 monitors UptimeRobot **prod** actius
- [ ] Slack integrat a UptimeRobot (prod)
- [ ] Projecte Sentry `pimed-staging` + DSN als secrets
- [ ] Projecte Sentry `pimed-prod` + DSN als secrets
- [ ] Issue alerts Sentry prod configurades (veure runbook)
- [ ] Slack integrat a Sentry
- [ ] Alertes Supabase CPU/connexions/storage (staging + prod)
- [ ] `pg_stat_statements` revisat (top 15)
- [ ] `observability-baseline-runbook.md` §4 omplert
- [ ] `verify-phase0-observability.mjs` OK local (+ cloud si refs definits)

**Responsable sign-off:** _______________ **Data:** _______________
