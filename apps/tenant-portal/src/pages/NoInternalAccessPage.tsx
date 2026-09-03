import { useTranslation } from 'react-i18next'
import { ShieldOff } from 'lucide-react'
import { useAuth } from '@/contexts/AuthContext'
import { Button } from '@/components/ui/button'

/**
 * CP-B0: sessió Supabase sense cap tenant_members interna activa.
 * El portal tenant és només per staff; clients usen apps/customer-portal.
 */
export function NoInternalAccessPage() {
  const { t } = useTranslation(['common', 'auth'])
  const { signOut, user } = useAuth()

  return (
    <div className="flex min-h-screen items-center justify-center bg-background px-4">
      <div className="w-full max-w-md rounded-2xl border bg-card p-8 text-center shadow-sm space-y-4">
        <ShieldOff className="mx-auto h-10 w-10 text-muted-foreground" />
        <h1 className="text-xl font-semibold tracking-tight">
          {t('auth.no_internal_access_title', 'Sense accés intern')}
        </h1>
        <p className="text-sm text-muted-foreground">
          {t(
            'auth.no_internal_access_body',
            'Aquest compte no pertany a cap organització com a membre intern. Si ets client, obre l’enllaç del butlletí o inicia sessió al portal de clients.',
          )}
        </p>
        {user?.email && (
          <p className="text-xs text-muted-foreground font-mono">{user.email}</p>
        )}
        <Button type="button" variant="outline" className="w-full" onClick={() => void signOut()}>
          {t('common.sign_out', 'Tancar sessió')}
        </Button>
      </div>
    </div>
  )
}
