import { NavLink, Navigate, Outlet, useLocation } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Briefcase } from 'lucide-react'
import { Tabs, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { Badge } from '@/components/ui/badge'
import { usePermission } from '@/hooks/usePermission'
import { useTenantFeatures } from '@/features/entity-timeline/api/useTenantFeatures'
import {
  useApplicantDataRequests,
  useJobPostingSummaries,
  useRecruitmentEmailInbox,
  useTenantApplications,
} from '../api/useRecruitment'
import { getCaptureStatus } from '../utils/captureStatus'

type HubTab = {
  key: string
  to: string
  labelKey: string
}

export function RecruitmentLayout() {
  const { t } = useTranslation('recruitment')
  const location = useLocation()
  const canRights = usePermission('recruitment.rights')
  const { data: features, isLoading: featuresLoading } = useTenantFeatures()
  const { data: summaries = [] } = useJobPostingSummaries()
  const { data: applications = [] } = useTenantApplications({})
  const { data: inboxItems = [] } = useRecruitmentEmailInbox('unassigned')
  const { data: rightsPending = [] } = useApplicantDataRequests('pending_review', {
    enabled: canRights,
  })

  if (location.pathname === '/recruitment') {
    return <Navigate to="/recruitment/applications" replace />
  }

  if (featuresLoading) {
    return <div className="flex h-64 items-center justify-center text-muted-foreground">…</div>
  }

  if (features?.recruitment_enabled === false) {
    return (
      <div className="mx-auto max-w-6xl space-y-4 px-4 py-8">
        <h1 className="text-2xl font-bold">{t('title')}</h1>
        <p className="text-muted-foreground">{t('postings.disabled')}</p>
      </div>
    )
  }

  const tabs: HubTab[] = [
    { key: 'applications', to: '/recruitment/applications', labelKey: 'hub.tab_applications' },
    { key: 'postings', to: '/recruitment/postings', labelKey: 'hub.tab_postings' },
    { key: 'inbox', to: '/recruitment/inbox', labelKey: 'hub.tab_inbox' },
    { key: 'analytics', to: '/recruitment/analytics', labelKey: 'hub.tab_analytics' },
    ...(canRights
      ? [{ key: 'rights', to: '/recruitment/rights', labelKey: 'hub.tab_rights' } satisfies HubTab]
      : []),
    { key: 'settings', to: '/recruitment/settings', labelKey: 'hub.tab_settings' },
  ]

  const liveCount = summaries.filter((p) => getCaptureStatus(p, p.public_site_count) === 'live').length
  const appCount = applications.length
  const inboxCount = inboxItems.length
  const rightsCount = rightsPending.length
  const isBoard = location.pathname.startsWith('/recruitment/applications')
  const isDetail = /^\/recruitment\/postings\/[^/]+/.test(location.pathname)

  const activeTab =
    tabs.find((tab) => location.pathname.startsWith(tab.to))?.to ?? '/recruitment/applications'

  if (isDetail) {
    return <Outlet />
  }

  return (
    <div
      className={
        isBoard
          ? 'mx-auto flex min-h-full max-w-none flex-col gap-6 px-4 py-8'
          : 'mx-auto max-w-6xl space-y-6 px-4 py-8'
      }
    >
      <div className="flex shrink-0 flex-wrap items-start gap-3">
        <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-primary/10 text-primary">
          <Briefcase className="h-5 w-5" aria-hidden />
        </div>
        <div className="min-w-0 flex-1">
          <h1 className="text-2xl font-bold">{t('title')}</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            {t('hub.subtitle', {
              applications: appCount,
              live: liveCount,
            })}
          </p>
        </div>
      </div>

      <Tabs value={activeTab} className="shrink-0">
        <TabsList className="flex h-auto flex-wrap gap-1">
          {tabs.map((tab) => (
            <TabsTrigger key={tab.key} value={tab.to} asChild>
              <NavLink to={tab.to} className="relative gap-2">
                {t(tab.labelKey)}
                {tab.key === 'applications' && appCount > 0 && (
                  <Badge variant="secondary" className="h-5 min-w-5 px-1.5 text-xs">
                    {appCount}
                  </Badge>
                )}
                {tab.key === 'postings' && liveCount > 0 && (
                  <Badge
                    variant="outline"
                    className="h-5 border-emerald-200 bg-emerald-50 px-1.5 text-xs text-emerald-800"
                  >
                    {liveCount}
                  </Badge>
                )}
                {tab.key === 'inbox' && inboxCount > 0 && (
                  <Badge variant="destructive" className="h-5 min-w-5 px-1.5 text-xs">
                    {inboxCount}
                  </Badge>
                )}
                {tab.key === 'rights' && rightsCount > 0 && (
                  <Badge variant="destructive" className="h-5 min-w-5 px-1.5 text-xs">
                    {rightsCount}
                  </Badge>
                )}
              </NavLink>
            </TabsTrigger>
          ))}
        </TabsList>
      </Tabs>

      <div className={isBoard ? 'flex min-h-0 flex-1 flex-col' : undefined}>
        <Outlet />
      </div>
    </div>
  )
}
