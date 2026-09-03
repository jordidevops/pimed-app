export type MessageLevel = 'fatal' | 'error' | 'warning' | 'info' | 'debug'

export type ErrorContext = {
  feature: string
  tenantId?: string | null
  userId?: string | null
  correlationId?: string
  tags?: Record<string, string>
  extra?: Record<string, unknown>
}

export type ObservabilityScope = {
  userId?: string | null
  tenantId?: string | null
}
