import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import {
  Bar,
  CartesianGrid,
  ComposedChart,
  Legend,
  Line,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { useSectorLabel } from '@/hooks/useSectorLabel'
import {
  getSalesDashboardOverview,
  type SalesDashboardAttentionItem,
  type SalesDashboardAttentionReason,
} from '../api/commercialFlowService'
import { centsToEuros } from '../utils/paymentReceipt'

const moneyFmt = new Intl.NumberFormat('ca-ES', {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
})

function attentionHref(item: SalesDashboardAttentionItem): string {
  if (item.kind === 'quote_prepare') return `/sales/quotes/${item.id}`
  return `/sales/agreements?view=${item.id}`
}

export function SalesDashboardPage() {
  const { t } = useTranslation('projects')
  const [year, setYear] = useState(() => new Date().getFullYear())
  const agreementsLabel = useSectorLabel(
    'agreement_plural',
    t('projects.agreements.title', 'Acords comercials'),
  )
  const agreementSingular = useSectorLabel(
    'agreement',
    t('projects.agreements.title_one', 'Acord comercial'),
  )

  const overviewQuery = useQuery({
    queryKey: ['sales_dashboard_overview', year],
    queryFn: () => getSalesDashboardOverview(year),
  })

  const overview = overviewQuery.data
  const cash = overview?.cash
  const agreements = overview?.agreements
  const loading = overviewQuery.isLoading

  const yearOptions = useMemo(() => {
    const current = new Date().getFullYear()
    return [current, current - 1, current - 2]
  }, [])

  const chartData = useMemo(
    () =>
      (overview?.series.months ?? []).map((m) => ({
        month: t(`projects.sales.month_${m.month}`, String(m.month)),
        quotes: m.quotesIssued,
        deliveryNotes: m.deliveryNotesIssued,
        invoicedEuros: centsToEuros(m.invoicedCents),
        invoicedCents: m.invoicedCents,
      })),
    [overview?.series.months, t],
  )

  const yearTotals = useMemo(() => {
    const months = overview?.series.months ?? []
    return {
      quotes: months.reduce((sum, m) => sum + m.quotesIssued, 0),
      deliveryNotes: months.reduce((sum, m) => sum + m.deliveryNotesIssued, 0),
      invoicedCents: months.reduce((sum, m) => sum + m.invoicedCents, 0),
    }
  }, [overview?.series.months])

  const cashCards = [
    {
      key: 'to_invoice',
      to: '/sales/delivery-notes?billing=to_invoice',
      label: t('projects.sales.kpi_to_invoice', 'Per facturar'),
      hint: t('projects.sales.kpi_to_invoice_hint', 'Albarans pendents de facturar'),
      value: loading
        ? '…'
        : `${cash?.toInvoiceCount ?? 0} · ${moneyFmt.format(centsToEuros(cash?.toInvoiceCents ?? 0))} €`,
    },
    {
      key: 'pending_collection',
      to: '/sales/invoices?collection=pending',
      label: t('projects.sales.kpi_pending_collection', 'Pendent de cobrament'),
      hint: t('projects.sales.kpi_pending_collection_hint', 'Import pendent de cobrament'),
      value: loading
        ? '…'
        : `${moneyFmt.format(centsToEuros(cash?.pendingCollectionCents ?? 0))} €`,
    },
    {
      key: 'pending_quotes',
      to: '/sales/quotes?status=issued',
      label: t('projects.sales.kpi_pending_quotes', 'Pressupostos pendents'),
      hint: t('projects.sales.kpi_pending_quotes_hint', 'Pressupostos sense resposta'),
      value: loading ? '…' : String(cash?.pendingQuotesCount ?? 0),
    },
  ]

  const signatureTotal =
    (agreements?.signature.draft ?? 0) +
    (agreements?.signature.pending ?? 0) +
    (agreements?.signature.signed ?? 0)
  const lifecycleTotal =
    (agreements?.lifecycle.active ?? 0) +
    (agreements?.lifecycle.suspended ?? 0) +
    (agreements?.lifecycle.finished ?? 0)
  const isAgreementsEmpty =
    !loading &&
    signatureTotal === 0 &&
    lifecycleTotal === 0 &&
    (agreements?.needsPrepareCount ?? 0) === 0

  function reasonLabel(reason: SalesDashboardAttentionReason): string {
    switch (reason) {
      case 'needs_prepare':
        return t('projects.sales.attention_needs_prepare', 'Cal preparar acord')
      case 'pending_signature':
        return t('projects.sales.attention_pending_signature', 'Pendent de firma')
      case 'draft':
        return t('projects.sales.attention_draft', 'Esborrany')
      case 'expiring':
        return t('projects.sales.attention_expiring', 'A caducar')
      case 'suspended':
        return t('projects.sales.attention_suspended', 'Suspès')
      default:
        return reason
    }
  }

  return (
    <div className="app-list-column space-y-6">
      <Tabs defaultValue="ops">
        <TabsList>
          <TabsTrigger value="ops">
            {t('projects.sales.dashboard_tab_ops', 'Operativa')}
          </TabsTrigger>
          <TabsTrigger value="stats">
            {t('projects.sales.dashboard_tab_stats', 'Estadístiques')}
          </TabsTrigger>
        </TabsList>

        <TabsContent value="ops" className="space-y-6">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <p className="text-sm text-muted-foreground">
              {t('projects.sales.dashboard_year', 'Resum de l’exercici {{year}}', { year })}
            </p>
            <label className="flex items-center gap-2 text-xs text-muted-foreground">
              {t('projects.sales.dashboard_year_select', 'Any')}
              <select
                className="h-9 rounded-md border border-input bg-background px-2 text-sm text-foreground"
                value={year}
                onChange={(event) => setYear(Number(event.target.value))}
              >
                {yearOptions.map((y) => (
                  <option key={y} value={y}>
                    {y}
                  </option>
                ))}
              </select>
            </label>
          </div>

          {overviewQuery.isError ? (
            <p className="text-sm text-destructive" role="alert">
              {t('projects.collections.load_failed', 'Error en carregar')}
            </p>
          ) : null}

          <div className="grid gap-3 sm:grid-cols-3">
            {cashCards.map((kpi) => (
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

          <section className="space-y-4 rounded-xl border border-border bg-card p-4">
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div>
                <h2 className="text-base font-semibold text-foreground">{agreementsLabel}</h2>
                <p className="text-xs text-muted-foreground">
                  {t(
                    'projects.sales.agreements_card_hint',
                    'Cues de formalització i vigència (tot el tenant, ara).',
                  )}
                </p>
              </div>
              <Link
                to="/sales/agreements"
                className="text-sm font-medium text-primary hover:underline"
              >
                {t('projects.sales.agreements_view_all', 'Veure tots')}
              </Link>
            </div>

            {isAgreementsEmpty ? (
              <p className="text-sm text-muted-foreground">
                {t(
                  'projects.sales.agreements_empty',
                  'Encara no hi ha acords ni pressupostos acceptats amb formalització separada. Un pressupost amb mode «pressupost signat» no genera fila aquí.',
                )}
              </p>
            ) : (
              <>
                <div className="space-y-2">
                  <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
                    {t('projects.sales.agreements_formalization_queue', 'Cua de formalització')}
                  </p>
                  <div className="flex flex-wrap gap-2">
                    {(agreements?.needsPrepareCount ?? 0) > 0 ? (
                      <Link
                        to="/sales/quotes?status=accepted"
                        className="rounded-md border border-primary/40 bg-primary/10 px-3 py-2 text-sm font-medium text-foreground hover:bg-primary/15"
                      >
                        {t('projects.sales.agreements_needs_prepare', 'Cal preparar')}
                        {': '}
                        <span className="tabular-nums">{agreements?.needsPrepareCount ?? 0}</span>
                      </Link>
                    ) : (
                      <span className="rounded-md border border-border px-3 py-2 text-sm text-muted-foreground">
                        {t('projects.sales.agreements_needs_prepare', 'Cal preparar')}
                        {': '}
                        <span className="tabular-nums">0</span>
                      </span>
                    )}
                    <Link
                      to="/sales/agreements?signature=none"
                      className="rounded-md border border-border px-3 py-2 text-sm hover:bg-accent"
                    >
                      {t('projects.sales.agreements_sig_draft', 'Esborrany')}
                      {': '}
                      <span className="tabular-nums">{agreements?.signature.draft ?? 0}</span>
                    </Link>
                    <Link
                      to="/sales/agreements?signature=pending"
                      className="rounded-md border border-border px-3 py-2 text-sm hover:bg-accent"
                    >
                      {t('projects.sales.agreements_sig_pending', 'Pendent de firma')}
                      {': '}
                      <span className="tabular-nums">{agreements?.signature.pending ?? 0}</span>
                    </Link>
                  </div>
                </div>

                <div className="space-y-2">
                  <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
                    {t('projects.sales.agreements_lifecycle', 'Vigència')}
                  </p>
                  <div className="flex flex-wrap gap-2">
                    <Link
                      to="/sales/agreements?validity=active"
                      className="rounded-md border border-border px-3 py-2 text-sm hover:bg-accent"
                    >
                      {t('projects.sales.agreements_life_active', 'Actius')}
                      {': '}
                      <span className="tabular-nums">{agreements?.lifecycle.active ?? 0}</span>
                    </Link>
                    <Link
                      to="/sales/agreements?validity=expiring"
                      className="rounded-md border border-border px-3 py-2 text-sm hover:bg-accent"
                    >
                      {t('projects.sales.agreements_life_expiring', 'A caducar')}
                      {': '}
                      <span className="tabular-nums">{agreements?.lifecycle.expiring ?? 0}</span>
                    </Link>
                    <Link
                      to="/sales/agreements?status=suspended"
                      className="rounded-md border border-border px-3 py-2 text-sm hover:bg-accent"
                    >
                      {t('projects.sales.agreements_life_suspended', 'Suspesos')}
                      {': '}
                      <span className="tabular-nums">{agreements?.lifecycle.suspended ?? 0}</span>
                    </Link>
                  </div>
                </div>

                <div className="space-y-2">
                  <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
                    {t('projects.sales.agreements_attention', 'Cal revisar')}
                  </p>
                  {(agreements?.attention.length ?? 0) === 0 ? (
                    <p className="text-sm text-muted-foreground">
                      {t('projects.sales.agreements_attention_empty', 'Cap element urgent.')}
                    </p>
                  ) : (
                    <ul className="divide-y divide-border rounded-md border border-border">
                      {(agreements?.attention ?? []).map((item) => (
                        <li key={`${item.kind}-${item.id}-${item.reason}`}>
                          <Link
                            to={attentionHref(item)}
                            className="flex flex-wrap items-baseline justify-between gap-2 px-3 py-2 text-sm hover:bg-accent/50"
                          >
                            <span className="min-w-0">
                              <span className="font-medium text-foreground">
                                {item.clientName || agreementSingular}
                              </span>
                              <span className="text-muted-foreground"> · {item.label}</span>
                            </span>
                            <span className="shrink-0 text-xs text-muted-foreground">
                              {reasonLabel(item.reason)}
                            </span>
                          </Link>
                        </li>
                      ))}
                    </ul>
                  )}
                </div>
              </>
            )}
          </section>

          <div className="space-y-2">
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
              {t('projects.sales.dashboard_shortcuts', 'Accés ràpid')}
            </p>
            <div className="flex flex-wrap gap-2">
              <Link
                to="/sales/agreements"
                className="rounded-md border border-border px-3 py-1.5 text-sm hover:bg-accent"
              >
                {agreementsLabel}
              </Link>
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
        </TabsContent>

        <TabsContent value="stats" className="space-y-6">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <p className="text-sm text-muted-foreground">
              {t(
                'projects.sales.stats_subtitle',
                'Volum mensual de pressupostos, albarans i facturació ({{year}}).',
                { year },
              )}
            </p>
            <label className="flex items-center gap-2 text-xs text-muted-foreground">
              {t('projects.sales.dashboard_year_select', 'Any')}
              <select
                className="h-9 rounded-md border border-input bg-background px-2 text-sm text-foreground"
                value={year}
                onChange={(event) => setYear(Number(event.target.value))}
              >
                {yearOptions.map((y) => (
                  <option key={y} value={y}>
                    {y}
                  </option>
                ))}
              </select>
            </label>
          </div>

          {overviewQuery.isError ? (
            <p className="text-sm text-destructive" role="alert">
              {t('projects.collections.load_failed', 'Error en carregar')}
            </p>
          ) : null}

          <div className="h-72 w-full rounded-xl border border-border bg-card p-3">
            {loading ? (
              <p className="p-4 text-sm text-muted-foreground">…</p>
            ) : (
              <ResponsiveContainer width="100%" height="100%">
                <ComposedChart data={chartData}>
                  <CartesianGrid strokeDasharray="3 3" className="stroke-muted" />
                  <XAxis dataKey="month" tick={{ fontSize: 11 }} />
                  <YAxis
                    yAxisId="count"
                    allowDecimals={false}
                    tick={{ fontSize: 11 }}
                    width={36}
                  />
                  <YAxis
                    yAxisId="money"
                    orientation="right"
                    tick={{ fontSize: 11 }}
                    width={48}
                    tickFormatter={(v) => moneyFmt.format(Number(v))}
                  />
                  <Tooltip
                    formatter={(value, name) => {
                      if (value === null || value === undefined) return '—'
                      if (name === t('projects.sales.stats_invoiced', 'Facturat (€)')) {
                        return `${moneyFmt.format(Number(value))} €`
                      }
                      return String(value)
                    }}
                  />
                  <Legend />
                  <Bar
                    yAxisId="count"
                    dataKey="quotes"
                    name={t('projects.sales.stats_quotes', 'Pressupostos')}
                    fill="hsl(var(--primary))"
                    radius={[3, 3, 0, 0]}
                  />
                  <Bar
                    yAxisId="count"
                    dataKey="deliveryNotes"
                    name={t('projects.sales.stats_delivery_notes', 'Albarans')}
                    fill="hsl(var(--muted-foreground))"
                    radius={[3, 3, 0, 0]}
                  />
                  <Line
                    yAxisId="money"
                    type="monotone"
                    dataKey="invoicedEuros"
                    name={t('projects.sales.stats_invoiced', 'Facturat (€)')}
                    stroke="hsl(var(--chart-2, var(--primary)))"
                    strokeWidth={2}
                    dot={false}
                  />
                </ComposedChart>
              </ResponsiveContainer>
            )}
          </div>

          <div className="grid gap-3 sm:grid-cols-3">
            <div className="rounded-xl border border-border px-4 py-3">
              <p className="text-xs text-muted-foreground">
                {t('projects.sales.stats_year_quotes', 'Pressupostos emesos')}
              </p>
              <p className="mt-1 text-2xl font-semibold tabular-nums">
                {loading ? '…' : yearTotals.quotes}
              </p>
            </div>
            <div className="rounded-xl border border-border px-4 py-3">
              <p className="text-xs text-muted-foreground">
                {t('projects.sales.stats_year_delivery_notes', 'Albarans emesos')}
              </p>
              <p className="mt-1 text-2xl font-semibold tabular-nums">
                {loading ? '…' : yearTotals.deliveryNotes}
              </p>
            </div>
            <div className="rounded-xl border border-border px-4 py-3">
              <p className="text-xs text-muted-foreground">
                {t('projects.sales.stats_year_invoiced', 'Facturat')}
              </p>
              <p className="mt-1 text-2xl font-semibold tabular-nums">
                {loading
                  ? '…'
                  : `${moneyFmt.format(centsToEuros(yearTotals.invoicedCents))} €`}
              </p>
            </div>
          </div>
        </TabsContent>
      </Tabs>
    </div>
  )
}
