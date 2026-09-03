import { useTranslation } from 'react-i18next'
import { useSearchParams } from 'react-router-dom'
import { Tabs, TabsList, TabsTrigger, TabsContent } from '../../../components/ui/tabs'
import { useTenant } from '../../../contexts/TenantContext'
import { usePublicSiteFull, usePublicPortalStatus } from '../api/usePublicSite'
import { usePublicPortalEffective } from '@/features/portal-entitlements'
import { ContentList, PortalModuleUsageCard } from '@/features/tenant-content'
import { PublicPortalActivation } from './PublicPortalActivation'
import { SiteConfigForm } from './SiteConfigForm'
import { DomainManager } from './DomainManager'
import { LeadsTable } from './LeadsTable'
import { AppearanceEditor } from './AppearanceEditor'

/**
 * Pàgina principal del mòdul Portal Públic al tenant-portal.
 *
 * Guard: si `public_portal_enabled = false` → mostra PublicPortalActivation.
 */
export function PublicPortalPage() {
  const { t } = useTranslation('public-portal')
  const [searchParams] = useSearchParams()
  const defaultTab = searchParams.get('tab') === 'pages' ? 'pages' : 'overview'
  const { activeTenant, activeRole, tenantScopeReady } = useTenant()
  const tenantId = activeTenant?.id ?? null
  const scopedTenantId = tenantScopeReady ? tenantId : null

  const { data: site, isLoading: siteLoading } = usePublicSiteFull(scopedTenantId)
  const { data: portalEnabled, isLoading: statusLoading } = usePublicPortalStatus(scopedTenantId)
  const { effective: portalEffective, isLoading: entitlementsLoading } =
    usePublicPortalEffective(scopedTenantId)

  const canManage = activeRole === 'owner' || activeRole === 'manager'

  const isLoading = siteLoading || statusLoading || entitlementsLoading || (!!tenantId && !tenantScopeReady)

  // Loading skeleton
  if (isLoading) {
    return (
      <div className="max-w-4xl mx-auto px-4 py-10 space-y-4">
        <div className="h-8 w-48 bg-muted rounded-xl animate-pulse" />
        <div className="h-4 w-72 bg-muted rounded animate-pulse" />
        <div className="h-40 bg-muted rounded-2xl animate-pulse" />
      </div>
    )
  }

  // No tenant selected
  if (!activeTenant) {
    return (
      <div className="max-w-4xl mx-auto px-4 py-10 text-center text-sm text-muted-foreground">
        {t('public_portal.not_enabled.description', 'Selecciona una organització per gestionar el portal públic.')}
      </div>
    )
  }

  // Guard: portal not effective (pla + toggle admin)
  if (portalEffective === false || portalEnabled === false) {
    return (
      <div className="max-w-4xl mx-auto px-4 py-10">
        <PublicPortalActivation />
      </div>
    )
  }

  return (
    <div className="max-w-4xl mx-auto px-4 py-10">
      {/* Header */}
      <div className="mb-6">
        <h1 className="text-2xl font-bold">{t('public_portal.page_title', 'Portal Públic')}</h1>
        <p className="text-sm text-muted-foreground mt-1">
          {t(
            'public_portal.page_description',
            'Gestiona el teu lloc web públic, dominis i leads captats.',
          )}
        </p>
      </div>

      <Tabs defaultValue={defaultTab} key={defaultTab}>
        <TabsList className="w-full justify-start mb-6">
          <TabsTrigger value="overview">
            {t('public_portal.tabs.overview', 'Resum')}
          </TabsTrigger>
          <TabsTrigger value="pages" disabled={!site?.id}>
            {t('public_portal.tabs.pages', 'Pàgines')}
          </TabsTrigger>
          <TabsTrigger value="domains" disabled={!site?.id}>
            {t('public_portal.tabs.domains', 'Dominis')}
          </TabsTrigger>
          <TabsTrigger value="leads" disabled={!site?.id}>
            {t('public_portal.tabs.leads', 'Leads')}
          </TabsTrigger>
          <TabsTrigger value="appearance" disabled={!site?.id}>
            {t('public_portal.tabs.appearance', 'Apariència')}
          </TabsTrigger>
        </TabsList>

        {/* Overview — site config form */}
        <TabsContent value="overview" className="space-y-6">
          <SiteConfigForm
            site={site ?? null}
            tenantId={tenantId!}
            canManage={canManage}
          />
        </TabsContent>

        <TabsContent value="pages" className="space-y-4">
          {site?.id && (
            <>
              <PortalModuleUsageCard
                tenantId={tenantId!}
                channel="public"
                publicSiteId={site.id}
              />
              <ContentList
                tenantId={tenantId!}
                entryContext="public"
                canManage={canManage}
                publicSiteId={site.id}
                newPath="/public-portal/pages/new"
                editPath={(id) => `/public-portal/pages/${id}/edit`}
              />
            </>
          )}
        </TabsContent>

        {/* Domain manager */}
        <TabsContent value="domains">
          {site?.id && (
            <DomainManager
              tenantId={tenantId!}
              siteId={site.id}
              canManage={canManage}
            />
          )}
        </TabsContent>

        {/* Leads table */}
        <TabsContent value="leads">
          <LeadsTable
            tenantId={tenantId!}
            sites={site ? [site] : []}
            canManage={canManage}
          />
        </TabsContent>

        {/* Appearance editor */}
        <TabsContent value="appearance">
          {site?.id && (
            <AppearanceEditor
              site={site}
              tenantId={tenantId!}
              canManage={canManage}
            />
          )}
        </TabsContent>
      </Tabs>
    </div>
  )
}
