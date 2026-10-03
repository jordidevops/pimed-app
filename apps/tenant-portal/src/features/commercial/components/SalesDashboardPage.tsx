import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { getSalesDashboardKpis } from '../api/commercialFlowService'
import { centsToEuros } from '../utils/paymentReceipt'

const moneyFmt = new Intl.NumberFormat('ca-ES', {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
})

export function SalesDashboardPage() {
  const { t } = useTranslation('projects')
  const year = new Date().getFullYear()

  const kpisQuery = useQuery({
    queryKey: ['sales_dashboard_kpis', year],
    queryFn: () => getSalesDashboardKpis(year),
  })

  const kpis = kpisQuery.data
  const loading = kpisQuery.isLoading

  const cards = [
    {
      key: 'to_invoice',
      to: '/sales/delivery-notes?billing=to_invoice',
      label: t('projects.sales.kpi_to_invoice', 'Per facturar'),
      hint: t('projects.sales.kpi_to_invoice_hint', 'Albarans pendents de facturar'),
      value: loading
        ? '…'
        : `${kpis?.toInvoiceCount ?? 0} · ${moneyFmt.format(centsToEuros(kpis?.toInvoiceCents ?? 0))} €`,
    },
    {
      key: 'pending_collection',
      to: '/sales/invoices?collection=pending',
      label: t('projects.sales.kpi_pending_collection', 'Pendent de cobrament'),
      hint: t('projects.sales.kpi_pending_collection_hint', 'Import pendent de cobrament'),
      value: loading
        ? '…'
        : `${moneyFmt.format(centsToEuros(kpis?.pendingCollectionCents ?? 0))} €`,
    },
    {
      key: 'pending_quotes',
      to: '/sales/quotes?status=issued',
      label: t('projects.sales.kpi_pending_quotes', 'Pressupostos pendents'),
      hint: t('projects.sales.kpi_pending_quotes_hint', 'Pressupostos sense resposta'),
      value: loading ? '…' : String(kpis?.pendingQuotesCount ?? 0),
    },
  ]

  return (
    <div className="app-list-column space-y-6">
      <p className="text-sm text-muted-foreground">
        {t('projects.sales.dashboard_year', 'Resum de l’exercici {{year}}', { year })}
      </p>
      {kpisQuery.isError ? (
        <p className="text-sm text-destructive" role="alert">
          {t('projects.collections.load_failed', 'Error en carregar')}
        </p>
      ) : null}
      <div className="grid gap-3 sm:grid-cols-3">
        {cards.map((kpi) => (
          <Link
            key={kpi.key}
            to={kpi.to}
            className="rounded-xl border border-border bg-card px-4 py-3 transition-colors hover:border-primary/40 hover:bg-accent/40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
          >
            <p className="text-xs text-muted-foreground">{kpi.label}</p>
            <p className="mt-1 text-2xl font-semibold tabular-nums">{kpi.value}</p>
            <p className="mt-1 text-xs text-muted-foreground">{kpi.hint}</p>
          </Link>
        ))}
      </div>

      <div className="space-y-2">
        <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
          {t('projects.sales.dashboard_shortcuts', 'Accés ràpid')}
        </p>
        <div className="flex flex-wrap gap-2">
          <Link
            to="/sales/quotes"
            className="rounded-md border border-border px-3 py-1.5 text-sm hover:bg-accent"
          >
            {t('projects.sales.tab_quotes', 'Pressupostos')}
          </Link>
          <Link
            to="/sales/delivery-notes"
            className="rounded-md border border-border px-3 py-1.5 text-sm hover:bg-accent"
          >
            {t('projects.sales.tab_delivery_notes', 'Albarans')}
          </Link>
          <Link
            to="/sales/invoices"
            className="rounded-md border border-border px-3 py-1.5 text-sm hover:bg-accent"
          >
            {t('projects.sales.tab_invoices', 'Factures')}
          </Link>
          <Link
            to="/sales/accounting"
            className="rounded-md border border-border px-3 py-1.5 text-sm hover:bg-accent"
          >
            {t('projects.sales.tab_accounting', 'Comptabilitat')}
          </Link>
        </div>
      </div>
    </div>
  )
}
