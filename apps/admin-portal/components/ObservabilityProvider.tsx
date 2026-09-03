'use client'

import { useEffect } from 'react'
import { createSupabaseClient } from '@/lib/supabase/client'
import { ObservabilityErrorBoundary } from '@/lib/observability/ObservabilityErrorBoundary'
import { initObservability, setObservabilityScope } from '@/lib/observability/system-error-tracker'

function bootstrapObservability(): void {
  const dsn = process.env.NEXT_PUBLIC_SENTRY_DSN?.trim() ?? ''
  const environment =
    process.env.NEXT_PUBLIC_APP_ENVIRONMENT?.trim() ??
    (process.env.NODE_ENV === 'production' ? 'production' : 'local')

  initObservability({
    dsn,
    environment,
    app: 'admin-portal',
  })
}

function SentryScopeSync() {
  useEffect(() => {
    bootstrapObservability()

    const supabase = createSupabaseClient()

    const syncUser = async () => {
      const { data } = await supabase.auth.getUser()
      setObservabilityScope({ userId: data.user?.id ?? null, tenantId: null })
    }

    void syncUser()

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((_event, session) => {
      setObservabilityScope({ userId: session?.user?.id ?? null, tenantId: null })
    })

    return () => subscription.unsubscribe()
  }, [])

  return null
}

export function ObservabilityProvider({ children }: { children: React.ReactNode }) {
  return (
    <ObservabilityErrorBoundary>
      <SentryScopeSync />
      {children}
    </ObservabilityErrorBoundary>
  )
}
