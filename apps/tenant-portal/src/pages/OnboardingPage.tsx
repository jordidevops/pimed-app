import { Navigate } from 'react-router-dom'
import { OnboardingWizard } from '@/features/onboarding'
import { useTenant } from '@/contexts/TenantContext'

/**
 * OnboardingPage — pàgina de configuració inicial (wizard d'onboarding).
 * Accessible via la ruta /onboarding.
 * Fora de l'AppLayout: no té sidebar ni capçalera de l'app.
 * L'AppLayout redirigeix aquí automàticament si el tenant no té sector_profile_id.
 */
export function OnboardingPage() {
  const { activeTenant, tenantsLoading } = useTenant()

  if (tenantsLoading) {
    return null
  }

  const canAccessOnboarding =
    activeTenant !== null &&
    activeTenant.role === 'owner' &&
    activeTenant.sector_profile_id === null

  if (!canAccessOnboarding) {
    return <Navigate to="/dashboard" replace />
  }

  return (
    <div className="min-h-full h-full overflow-y-auto bg-gradient-to-br from-indigo-50 via-white to-purple-50 dark:from-gray-950 dark:via-gray-900 dark:to-indigo-950 flex items-start justify-center pt-12 pb-16 px-4">
      <div className="w-full max-w-2xl">
        {/* Logo / marca */}
        <div className="text-center mb-10">
          <span className="text-3xl font-bold bg-gradient-to-r from-indigo-600 to-purple-600 bg-clip-text text-transparent">
            my-app
          </span>
        </div>

        {/* Wizard container */}
        <div className="bg-card rounded-3xl border border-border/60 shadow-xl p-8 sm:p-10">
          <OnboardingWizard />
        </div>
      </div>
    </div>
  )
}
