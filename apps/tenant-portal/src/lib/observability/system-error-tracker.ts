import type { ErrorContext, MessageLevel } from './context'
import {
  captureSentryException,
  captureSentryMessage,
  initSentryClient,
  setSentryScope,
  type SentryInitConfig,
} from './sentry-client'

let enabled = false

function logToConsole(error: unknown, ctx: ErrorContext): void {
  console.error(
    JSON.stringify({
      level: 'error',
      app: 'tenant-portal',
      feature: ctx.feature,
      tenantId: ctx.tenantId ?? null,
      userId: ctx.userId ?? null,
      message: error instanceof Error ? error.message : String(error),
    }),
  )
}

export function initObservability(config: SentryInitConfig): void {
  enabled = initSentryClient(config)
}

export function setObservabilityScope(scope: {
  userId?: string | null
  tenantId?: string | null
}): void {
  setSentryScope(scope)
}

export function captureException(error: unknown, ctx: ErrorContext): void {
  if (!ctx.feature?.trim()) {
    throw new Error('ErrorContext.feature is required')
  }
  if (enabled) {
    captureSentryException(error, ctx)
    return
  }
  logToConsole(error, ctx)
}

export function captureMessage(message: string, level: MessageLevel, ctx: ErrorContext): void {
  if (!ctx.feature?.trim()) {
    throw new Error('ErrorContext.feature is required')
  }
  if (enabled) {
    captureSentryMessage(message, level, ctx)
  }
}
