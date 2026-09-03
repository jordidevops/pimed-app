import { Link, useParams } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useTenant } from '@/contexts/TenantContext'
import { usePublicPortalEffective } from '@/features/portal-entitlements'
import { usePublicSiteFull } from '@/features/public-portal/api/usePublicSite'
import { ContentEditor } from '../components/ContentEditor'
import { ModuleNotEnabledScreen } from '../components/ModuleNotEnabledScreen'

export function PublicContentEditorPage() {
  const { t } = useTranslation('tenant-content')
  const { id } = useParams<{ id: string }>()
  const { activeTenant, activeRole, tenantScopeReady } = useTenant()
  const tenantId = tenantScopeReady ? activeTenant?.id ?? null : null
  const { effective, isLoading: entLoading } = usePublicPortalEffective(tenantId)
  const { data: site, isLoading: siteLoading } = usePublicSiteFull(tenantId)
  const canManage = activeRole === 'owner' || activeRole === 'manager'
  const isNew = !id

  const pageEditorLocales = site?.supported_locales?.length
    ? site.supported_locales
    : [site?.default_locale ?? 'es']
  const pageEditorDefaultLocale = site?.default_locale ?? pageEditorLocales[0] ?? 'es'

  if (!activeTenant || entLoading || siteLoading) {
    return (
      <div className="flex justify-center py-20">
        <div className="animate-spin h-8 w-8 border-b-2 border-primary rounded-full" />
      </div>
    )
  }

  if (effective === false) {
    return <ModuleNotEnabledScreen channel="public" />
  }

  return (
    <div className="max-w-4xl mx-auto px-4 py-8 space-y-4">
      <Link to="/public-portal?tab=pages" className="text-sm text-muted-foreground hover:text-primary">
        ← {t('tenant_content.nav.back_list', 'Tornar a la llista')}
      </Link>
      <h1 className="text-2xl font-bold">
        {isNew
          ? t('tenant_content.editor.new_public', 'Nova pàgina web')
          : t('tenant_content.editor.edit', 'Editar contingut')}
      </h1>
      <ContentEditor
        tenantId={activeTenant.id}
        entryContext="public"
        itemId={id}
        canManage={canManage}
        cancelPath="/public-portal?tab=pages"
        defaultPublicSiteId={site?.id ?? undefined}
        supportedLocales={pageEditorLocales}
        defaultLocale={pageEditorDefaultLocale}
      />
    </div>
  )
}
