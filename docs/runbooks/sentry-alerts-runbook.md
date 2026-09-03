# Runbook: Alertes Sentry

**Data:** 2026-06-20  
**Relacionat:** [`docs/plans/Sentry/plan.md`](../plans/Sentry/plan.md) secció 1.4

---

## 1. Projectes

| Entorn | Nom projecte | `environment` tag |
|--------|--------------|---------------------|
| Staging | `pimed-staging` | `staging` |
| Producció | `pimed-prod` | `production` |

DSN via Supabase Secrets: `SENTRY_DSN` (per projecte/ref).

Variable addicional: `ENVIRONMENT=staging|production|local`

---

## 2. Issue alerts (configurar al dashboard Sentry)

### Producció — P1

| Nom | Condició | Acció |
|-----|---------|-------|
| New issue prod | First seen + `environment:production` | Slack `#alerts-prod` + email |
| Regression | Issue status changes to regression | Slack `#alerts-prod` |
| Spike same issue | > 10 events mateix issue en 5 min | Slack (agrupat) |

### Producció — P0

| Nom | Condició | Acció |
|-----|---------|-------|
| Spike feature ai-chat | > 50 events, tag `feature:ai-chat-turn`, 5 min | Slack + revisar guardrails |

---

## 3. Metric alerts

| Nom | Condició | Acció |
|-----|---------|-------|
| EF error rate | Error rate > 5% per transacció, 5 min | Slack |
| ai-chat P95 | P95 > 5s, `feature:ai-chat-turn` | Slack |

---

## 4. Filtres `beforeSend` (no alertar)

- Errors HTTP 4xx esperats (validació, auth)
- `environment:local`
- Missatges que continguin `rate_limit_exceeded` (negoci)

---

## 5. Respostes esperades (SLA intern)

| Prioritat | Temps resposta | Acció |
|-----------|----------------|-------|
| P0 (spike / caiguda) | 30 min | Investigar immediatament |
| P1 (new issue prod) | 2h laboral | Triage + issue Linear/Jira |
| P2 (staging) | Endemà | Backlog |

---

## 6. Prova d'alerta

1. Desplegar `_health` i facade Sentry a staging.
2. Cridar Edge Function de test que faci `captureException(new Error('sentry-smoke-test'), { feature: 'test' })`.
3. Verificar issue a Sentry staging.
4. Confirmar que Slack rep l'alerta (prod només després de validar staging).

---

## 7. Checklist

- [ ] Issue alerts creats a prod
- [ ] Slack integration connectada
- [ ] Weekly report activat per email
- [ ] Smoke test executat a staging
