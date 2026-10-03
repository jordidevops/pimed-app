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
      label: t('projects.sales.kpi_to_invoice', 'Per facturar'),
      value: loading
        ? '…'
        : `${kpis?.toInvoiceCount ?? 0} · ${moneyFmt.format(centsToEuros(kpis?.toInvoiceCents ?? 0))} €`,
    },
    {
      key: 'pending_collection',
      label: t('projects.sales.kpi_pending_collection', 'Pendent de cobrament'),
      value: loading
        ? '…'
        : `${moneyFmt.format(centsToEuros(kpis?.pendingCollectionCents ?? 0))} €`,
    },
    {
      key: 'pending_quotes',
      label: t('projects.sales.kpi_pending_quotes', 'Pressupostos pendents'),
      value: loading ? '…' : String(kpis?.pendingQuotesCount ?? 0),
    },
  ]

  return (
    <div className="space-y-4">
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
          <div key={kpi.key} className="rounded-xl border border-border bg-card px-4 py-3">
            <p className="text-xs text-muted-foreground">{kpi.label}</p>
            <p className="mt-1 text-2xl font-semibold tabular-nums">{kpi.value}</p>
          </div>
        ))}
      </div>
    </div>
  )
}
