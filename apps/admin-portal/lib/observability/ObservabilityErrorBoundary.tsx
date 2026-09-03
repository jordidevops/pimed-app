'use client'

import type { ReactNode } from 'react'
import { Sentry } from '@/lib/observability/sentry-client'

function ErrorFallback({
  error,
  resetError,
}: {
  error: unknown
  resetError: () => void
}) {
  const message = error instanceof Error ? error.message : String(error)

  return (
    <div className="min-h-[40vh] flex items-center justify-center p-6">
      <div className="max-w-md rounded-2xl border border-red-200 bg-red-50 p-6 text-center space-y-4">
        <h1 className="text-lg font-semibold text-red-800">S&apos;ha produït un error inesperat</h1>
        <p className="text-sm text-red-700">{message}</p>
        <button
          type="button"
          onClick={resetError}
          className="inline-flex items-center justify-center rounded-lg bg-indigo-600 px-4 py-2 text-sm font-medium text-white"
        >
          Torna-ho a provar
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
