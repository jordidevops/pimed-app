import { NavLink, Navigate, Outlet, useLocation } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Wallet } from 'lucide-react'
import { PageShell } from '@/components/layout/PageShell'
import { underlineTabClass } from '@/components/layout/UnderlineTabs'
import { ScrollableTabBar } from '@/components/ui/scrollable-tab-bar'
import { usePermission } from '@/hooks/usePermission'
import { passesGate, useNavGateContext } from '@/features/sidebar-nav'

type SalesTab = {
  key: string
  to: string
  labelKey: string
  fallback: string
  end?: boolean
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
      <div className="app-content px-4 py-6">
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
      key: 'summary',
      to: '/sales',
      labelKey: 'projects.sales.tab_summary',
      fallback: 'Resum',
      end: true,
    },
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
    tabs.find((tab) =>
      tab.end
        ? location.pathname === tab.to
        : location.pathname === tab.to || location.pathname.startsWith(`${tab.to}/`),
    )?.key ?? tabs[0]?.key

  if (isDetail) {
    return <Outlet />
  }

  return (
    <PageShell
      flush
      title={t('projects.sales.title', 'Comercial')}
      subtitle={t(
        'projects.sales.subtitle',
        'Pressupostos, albarans, factures i comptabilitat.',
      )}
      icon={<Wallet className="h-5 w-5" aria-hidden />}
      tabs={
        <ScrollableTabBar
          activeKey={activeTab}
          aria-label={t('projects.sales.title', 'Comercial')}
          className="border-b border-border"
        >
          {tabs.map((tab) => (
            <NavLink
              key={tab.key}
              to={tab.to}
              end={tab.end}
              data-tab-key={tab.key}
              className={({ isActive }) => underlineTabClass(isActive)}
            >
              {t(tab.labelKey, tab.fallback)}
            </NavLink>
          ))}
        </ScrollableTabBar>
      }
    >
      <Outlet />
    </PageShell>
  )
}
