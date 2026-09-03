/**
 * Únic mòdul amb import directe de @sentry/react (admin-portal).
 */
import * as Sentry from '@sentry/react'
import type { ErrorContext } from './context'
import { shouldDropSentryEvent } from './filters'

export type SentryInitConfig = {
  dsn: string
  environment: string
  app: string
}

let initialized = false

function applyScope(scope: Sentry.Scope, ctx: ErrorContext): void {
  scope.setTag('app', 'admin-portal')
  scope.setTag('feature', ctx.feature)
  if (ctx.tenantId) scope.setTag('tenant_id', ctx.tenantId)
  if (ctx.userId) scope.setUser({ id: ctx.userId })
  if (ctx.correlationId) scope.setTag('correlation_id', ctx.correlationId)
  for (const [key, value] of Object.entries(ctx.tags ?? {})) {
    scope.setTag(key, value)
  }
  if (ctx.extra) scope.setExtras(ctx.extra)
}

export function initSentryClient(config: SentryInitConfig): boolean {
  if (initialized || !config.dsn || config.environment === 'local') return false

  Sentry.init({
    dsn: config.dsn,
    environment: config.environment,
    tracesSampleRate: 0.1,
    beforeSend(event, hint) {
      const message = event.exception?.values?.[0]?.value
      if (shouldDropSentryEvent(config.environment, hint.originalException, message)) {
        return null
      }
      return event
    },
  })

  Sentry.setTag('app', config.app)
  initialized = true
  return true
}

export function setSentryScope(scope: { userId?: string | null; tenantId?: string | null }): void {
  if (!initialized) return
  if (scope.userId) Sentry.setUser({ id: scope.userId })
  else Sentry.setUser(null)
  Sentry.setTag('tenant_id', scope.tenantId ?? '')
}

export function captureSentryException(error: unknown, ctx: ErrorContext): void {
  if (!initialized) return
  Sentry.withScope((scope) => {
    applyScope(scope, ctx)
    Sentry.captureException(error)
  })
}

export function captureSentryMessage(
  message: string,
  level: Sentry.SeverityLevel,
  ctx: ErrorContext,
): void {
  if (!initialized) return
  Sentry.withScope((scope) => {
    applyScope(scope, ctx)
    Sentry.captureMessage(message, level)
  })
}

export { Sentry }
