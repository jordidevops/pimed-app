import { initObservability } from './system-error-tracker'

export function bootstrapObservability(): void {
  const dsn = import.meta.env.VITE_SENTRY_DSN as string | undefined
  const environment =
    (import.meta.env.VITE_APP_ENVIRONMENT as string | undefined) ??
    (import.meta.env.MODE === 'production' ? 'production' : 'local')

  initObservability({
    dsn: dsn?.trim() ?? '',
    environment,
    app: 'tenant-portal',
  })
}
