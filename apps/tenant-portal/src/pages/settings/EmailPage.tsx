import { useTranslation } from 'react-i18next'
import { LockIcon } from 'lucide-react'
import { useTenant } from '../../contexts/TenantContext'
import { EmailSettingsView } from '../../features/email'

export function EmailPage() {
  const { t } = useTranslation('settings')
  const { activeTenant, activeRole } = useTenant()

  if (!activeTenant) return null

  return (
    <div className="space-y-6">
      {activeRole === 'owner' ? (
        <EmailSettingsView tenantId={activeTenant.id} />
      ) : (
        <>
          <div>
            <h2 className="text-lg font-semibold text-foreground">
              {t('tabs.email', 'Correu electrònic')}
            </h2>
          </div>
          <div className="flex items-start gap-3 rounded-xl border border-border bg-muted/50 px-5 py-4">
            <LockIcon className="mt-0.5 h-5 w-5 shrink-0 text-muted-foreground" />
            <div>
              <p className="text-sm font-medium text-foreground">
                {t('email_rbac_locked_title', 'Accés restringit')}
              </p>
              <p className="mt-0.5 text-sm text-muted-foreground">
                {t('email_rbac_locked_desc', 'Només el propietari del tenant pot configurar el correu electrònic.')}
              </p>
            </div>
          </div>
        </>
      )}
    </div>
  )
}
