# Directrius de gestió d'errors

**Relacionat:** [`plan.md`](plan.md) Fase 5

---

## 1. Quatre destinacions

| Destí | Quan |
|-------|------|
| **HTTP 4xx** | Validació, permisos, límits de negoci esperables |
| **tenant_operation_logs** | Fallades async/integració visibles per manager tenant |
| **Sentry** (`captureException`) | Bugs, infra, excepcions no previstes |
| **audit_logs** | Accions humanes d'èxit — **mai errors** |

---

## 2. Quan usar cada un

```
IF unhandled exception OR infrastructure bug:
  captureException → Sentry
ELSE IF expected business/integration failure:
  OperationLogService.logFailure / logDeadLetter
  IF also infrastructure: captureException
ELSE IF slow external call (> threshold):
  log(warn) + operationLog degraded (via logSuccess + durationMs)
ELSE IF user validation:
  HTTP 4xx — res més
ELSE IF debug/info:
  log() — StructuredLogger
ELSE IF human audit success:
  audit_logs
```

---

## 3. Prohibicions

- Cap `Sentry.capture*` directe — usar facade:
  - Edge Functions: `_shared/observability/system-error-tracker.ts`
  - Frontends: `src/lib/observability` (tenant) o `lib/observability` (admin)
- Cap `console.log/error` directe — usar `structured-logger.ts`
- Cap error operatiu a `audit_logs`
- Cap secret ni PII completa als logs (veure plan secció 5.3)

---

## 4. Convencions

- `feature` = nom de la Edge Function
- `correlation_id` = id estable (email_log_id, job_id, conversation_id)
- Crides externes: `timedCall()` + `durationMs` a operation logs

---

## 5. Imports recomanats (Edge Functions)

```typescript
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log, timedCall, defaultSlowHandler } from "../_shared/observability/structured-logger.ts";
import { createOperationLogService } from "../_shared/observability/operation-log-service.ts";
```

Crida `initObservability()` al inici de `Deno.serve`.

## 6. Imports recomanats (Frontends)

```typescript
// tenant-portal
import { captureException } from '@/lib/observability'

// admin-portal (Client Components)
import { captureException } from '@/lib/observability'
```

Inicialització automàtica al bootstrap (`main.tsx` / `ObservabilityProvider`). Cap `import` de `@sentry/react` fora de `sentry-client.ts`.
