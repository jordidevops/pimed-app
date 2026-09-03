import type { ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { Sentry } from './sentry-client'

function ErrorFallback({
  error,
  resetError,
}: {
  error: unknown
  resetError: () => void
}) {
  const { t } = useTranslation('common')
  const message = error instanceof Error ? error.message : String(error)

  return (
    <div className="min-h-[40vh] flex items-center justify-center p-6">
      <div className="max-w-md rounded-2xl border border-destructive/30 bg-destructive/5 p-6 text-center space-y-4">
        <h1 className="text-lg font-semibold text-destructive">
          {t('errors.unexpectedTitle', 'S\'ha produït un error inesperat')}
        </h1>
        <p className="text-sm text-muted-foreground">{message}</p>
        <button
          type="button"
          onClick={resetError}
          className="inline-flex items-center justify-center rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground"
        >
          {t('errors.tryAgain', 'Torna-ho a provar')}
        </button>
      </div>
    </div>
  )
}

export function ObservabilityErrorBoundary({ children }: { children: ReactNode }) {
  return (
    <Sentry.ErrorBoundary
      fallback={({ error, resetError }) => (
        <ErrorFallback error={error} resetError={resetError} />
      )}
      beforeCapture={(scope) => {
        scope.setTag('feature', 'error-boundary')
      }}
    >
      {children}
    </Sentry.ErrorBoundary>
  )
}
