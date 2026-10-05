import { useTranslation } from 'react-i18next'
import { Folder } from 'lucide-react'
import { PageShell } from '@/components/layout/PageShell'
import { useTenant } from '../contexts/TenantContext'
import { FileExplorer } from '../features/storage'

export function FilesPage() {
  const { t } = useTranslation(['storage', 'common'])
  const { activeTenant, tenants, tenantsLoading } = useTenant()

  const shell = {
    title: t('common:nav.files', 'Fitxers'),
    subtitle: t('storage:explorer.page_subtitle', 'Explorador de fitxers'),
    icon: <Folder className="h-5 w-5" aria-hidden />,
  }

  if (tenantsLoading) {
    return (
      <PageShell flush {...shell}>
        <div className="flex h-48 items-center justify-center">
          <div className="h-8 w-8 animate-spin rounded-full border-b-2 border-primary" />
        </div>
      </PageShell>
    )
  }

  if (!activeTenant && tenants.length > 1) {
    return (
      <PageShell flush {...shell}>
        <div className="rounded-2xl border border-amber-200 bg-amber-50 p-6 text-center">
          <p className="text-sm font-medium text-amber-800">
            {t(
              'storage:explorer.select_tenant_hint',
              'Selecciona una organització a la barra lateral per veure els fitxers.',
            )}
          </p>
        </div>
      </PageShell>
    )
  }

  if (!activeTenant) return null

  return (
    <PageShell flush {...shell}>
      <div className="h-[calc(100dvh-var(--app-sticky-chrome,7rem)-5.5rem)] min-h-[24rem]">
        <FileExplorer tenantId={activeTenant.id} />
      </div>
    </PageShell>
  )
}
