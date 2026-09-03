import { Navigate } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../contexts/AuthContext'
import { LoginForm } from '../features/auth/components/LoginForm'
import { Spinner } from '../components/ui/Spinner'

export function LoginPage() {
  const { t } = useTranslation('common')
  const { session, loading } = useAuth()

  if (loading) {
    return (
      <div className="flex items-center justify-center min-h-screen bg-background">
        <Spinner />
      </div>
    )
  }

  if (session) {
    return <Navigate to="/dashboard" replace />
  }

  return (
    <div className="min-h-full h-full overflow-y-auto bg-linear-to-br from-indigo-50 to-blue-100 dark:from-slate-950 dark:to-slate-900 flex items-center justify-center p-4">
      <div className="w-full max-w-md">
        <div className="text-center mb-8">
          <div className="inline-flex items-center justify-center w-16 h-16 bg-indigo-600 rounded-2xl mb-4 shadow-lg">
            <PortalIcon className="w-9 h-9 text-white" />
          </div>
          <h1 className="text-3xl font-bold text-foreground">
            {t('auth.login.title', 'Portal de Clients')}
          </h1>
          <p className="text-muted-foreground mt-1">
            {t('auth.login.subtitle', 'Gestió de la teva organització')}
          </p>
        </div>
        <LoginForm />
      </div>
    </div>
  )
}

function PortalIcon({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" aria-hidden="true">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 6h16M6 6v12M18 6v12M4 18h16M10 11h4M10 14h4" />
    </svg>
  )
}
