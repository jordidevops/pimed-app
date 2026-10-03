import { NavLink, Navigate, Outlet, useLocation } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Wallet } from 'lucide-react'
import { Tabs, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { usePermission } from '@/hooks/usePermission'
import { passesGate, useNavGateContext } from '@/features/sidebar-nav'

type SalesTab = {
  key: string
  to: string
  labelKey: string
  fallback: string
}

export function SalesLayout() {
  const { t } = useTranslation('projects')
  const location = useLocation()
  const { ctx, gatesLoading } = useNavGateContext()
  const canViewInvoices = usePermission('invoices.view')
  const canReview = usePermission('invoices.review')
  const canExport = usePermission('invoices.export')
  const canManage = usePermission('invoices.manage')
  const officeAllowed = !gatesLoading && passesGate('isOffice', ctx)
  const salesAllowed = !gatesLoading && (officeAllowed || canViewInvoices || ctx.canViewSales)

  const isDetail =
    /^\/sales\/delivery-notes\/[^/]+/.test(location.pathname) ||
    /^\/sales\/invoices\/[^/]+/.test(location.pathname)

  if (gatesLoading) {
    return (
      <div className="mx-auto max-w-6xl px-4 py-6">
        <p className="text-sm text-muted-foreground">{t('projects.quotes.loading', 'Carregant…')}</p>
      </div>
    )
  }

  if (!salesAllowed) {
    return <Navigate to={ctx.homePath} replace />
  }

  const showAccounting = canReview || canExport || canManage
  const tabs: SalesTab[] = [
    {
      key: 'quotes',
      to: '/sales/quotes',
      labelKey: 'projects.sales.tab_quotes',
      fallback: 'Pressupostos',
    },
    {
      key: 'delivery-notes',
      to: '/sales/delivery-notes',
      labelKey: 'projects.sales.tab_delivery_notes',
      fallback: 'Albarans',
    },
    {
      key: 'invoices',
      to: '/sales/invoices',
      labelKey: 'projects.sales.tab_invoices',
      fallback: 'Factures',
    },
    ...(showAccounting
      ? [
          {
            key: 'accounting',
            to: '/sales/accounting',
            labelKey: 'projects.sales.tab_accounting',
            fallback: 'Comptabilitat',
          } satisfies SalesTab,
        ]
      : []),
  ]

  const activeTab =
    tabs.find((tab) => location.pathname === tab.to || location.pathname.startsWith(`${tab.to}/`))
      ?.to ?? (location.pathname.startsWith('/sales') ? '/sales' : tabs[0]?.to)

  if (isDetail) {
    return <Outlet />
  }

  return (
    <div className="mx-auto flex min-h-full max-w-6xl flex-col gap-6 px-4 py-8">
      <div className="flex shrink-0 flex-wrap items-start gap-3">
        <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-primary/10 text-primary">
          <Wallet className="h-5 w-5" aria-hidden />
        </div>
        <div className="min-w-0 flex-1">
          <h1 className="text-2xl font-bold">{t('projects.sales.title', 'Comercial')}</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            {t(
              'projects.sales.subtitle',
              'Pressupostos, albarans, factures i comptabilitat.',
            )}
          </p>
        </div>
      </div>

      <Tabs value={activeTab === '/sales' ? '' : activeTab} className="shrink-0">
        <TabsList
          className="inline-flex h-auto w-max flex-nowrap gap-1"
          aria-label={t('projects.sales.title', 'Comercial')}
        >
          {tabs.map((tab) => (
            <TabsTrigger key={tab.key} value={tab.to} asChild data-tab-key={tab.to}>
              <NavLink to={tab.to}>{t(tab.labelKey, tab.fallback)}</NavLink>
            </TabsTrigger>
          ))}
        </TabsList>
      </Tabs>

      <div className="min-h-0 flex-1">
        <Outlet />
      </div>
    </div>
  )
}
