import { useEffect, useMemo, useState } from 'react'
import { Link, useNavigate, useSearchParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { PageShell } from '@/components/layout/PageShell'
import { InspectorSheet } from '@/components/layout/InspectorSheet'
import { ListViewToggle } from '@/components/layout/ListViewToggle'
import { FilterChips } from '@/components/layout/FilterChips'
import { useListViewMode } from '@/hooks/useListViewMode'
import { useListDensity } from '@/hooks/useListDensity'
import { SalesDocCard } from './SalesDocCard'
import {
  listSalesInvoicesPage,
  type SalesCollectionStatus,
  type SalesInvoiceListRow,
  type SalesListCursor,
} from '../api/commercialFlowService'
import { centsToEuros } from '../utils/paymentReceipt'
import { SalesDataTable, type SalesDataTableColumn } from './SalesDataTable'

const moneyFmt = new Intl.NumberFormat('ca-ES', {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
})

const PAGE_SIZE = 50
const PAGE_KEY = 'sales.invoices'

function collectionLabel(
  status: string,
  t: (key: string, fallback: string) => string,
): string {
  if (status === 'paid') return t('projects.sales.collection_paid', 'Cobrat')
  if (status === 'partial') return t('projects.sales.collection_partial', 'Parcial')
  return t('projects.sales.collection_pending', 'Pendent de cobrar')
}

function collectionTone(status: string): 'pending' | 'partial' | 'paid' | 'neutral' {
  if (status === 'paid') return 'paid'
  if (status === 'partial') return 'partial'
  if (status === 'pending') return 'pending'
  return 'neutral'
}

/** Hub list for /sales/invoices — list_sales_invoices_page + SalesDataTable. */
export function InvoicesPage() {
  const { t } = useTranslation(['projects', 'common'])
  const navigate = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()
  const q = searchParams.get('q') ?? ''
  const collectionParam = searchParams.get('collection')
  const [selected, setSelected] = useState<string[]>([])
  const [sortKey, setSortKey] = useState<string | null>('issued_at')
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('desc')
  const [cursorStack, setCursorStack] = useState<Array<SalesListCursor | null>>([null])
  const [cursorPage, setCursorPage] = useState(0)
  const [inspectId, setInspectId] = useState<string | null>(null)

  const { mode, setMode, effectiveMode } = useListViewMode(PAGE_KEY, 'table')
  const { density, setDensity } = useListDensity(PAGE_KEY, 'compact')

  const collectionStatus: SalesCollectionStatus[] | null =
    collectionParam === 'pending' || collectionParam === 'partial' || collectionParam === 'paid'
      ? [collectionParam]
      : null

  const filters = useMemo(
    () => ({
      q: q.trim().length >= 2 ? q.trim() : null,
      collectionStatus,
      sort: (sortKey === 'doc_number' || sortKey === 'total' ? sortKey : 'issued_at') as
        | 'issued_at'
        | 'doc_number'
        | 'total',
      dir: sortDir,
      cursor: cursorStack[cursorPage] ?? null,
      limit: PAGE_SIZE,
    }),
    [q, collectionStatus, sortKey, sortDir, cursorStack, cursorPage],
  )

  const query = useQuery({
    queryKey: ['sales_invoices', filters],
    queryFn: () => listSalesInvoicesPage(filters),
  })

  const items = query.data?.items ?? []
  const totalCount = query.data?.totalCount ?? 0
  const hasMore = Boolean(query.data?.hasMore)
  const inspected = items.find((row) => row.id === inspectId) ?? null

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === 'Escape' && inspectId) {
        event.preventDefault()
        setInspectId(null)
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [inspectId])

  const columns = useMemo<SalesDataTableColumn<SalesInvoiceListRow>[]>(
    () => [
      {
        id: 'doc_number',
        header: t('projects.sales.tab_invoices', 'Factures'),
        sortable: true,
        cell: (row) => (
          <Link to={`/sales/invoices/${row.id}`} className="font-semibold hover:underline">
            {row.doc_number ?? row.id.slice(0, 8)}
          </Link>
        ),
      },
      {
        id: 'issued_at',
        header: t('projects.collections.issued_on', 'Data'),
        sortable: true,
        cell: (row) =>
          row.issued_on ||
          (row.issued_at ? new Date(row.issued_at).toLocaleDateString('ca-ES') : '—'),
      },
      {
        id: 'client',
        header: t('projects.quotes.client', 'Client'),
        cell: (row) => row.client_display_name || '—',
      },
      {
        id: 'delivery_count',
        header: '#DN',
        className: 'tabular-nums',
        cell: (row) => row.delivery_count,
      },
      {
        id: 'document_status',
        header: t('projects.sales.document', 'Document'),
        cell: (row) => <Badge variant="outline">{row.document_status}</Badge>,
      },
      {
        id: 'collection',
        header: t('projects.sales.collection', 'Cobrament'),
        cell: (row) => collectionLabel(row.collection_status, t),
      },
      {
        id: 'total',
        header: t('projects.commercial.total', 'Total'),
        className: 'text-right tabular-nums',
        sortable: true,
        cell: (row) => `${moneyFmt.format(centsToEuros(row.total_cents))} €`,
      },
      {
        id: 'remaining',
        header: t('projects.collections.remaining', 'Pendent'),
        className: 'text-right tabular-nums',
        cell: (row) => `${moneyFmt.format(centsToEuros(row.remaining_cents))} €`,
      },
      {
        id: 'review',
        header: t('projects.sales.review', 'Revisió'),
        cell: (row) => row.review_status || 'pending',
      },
      {
        id: 'export',
        header: t('projects.sales.export', 'Export'),
        cell: (row) => row.export_status || 'none',
      },
    ],
    [t],
  )

  function updateParam(key: string, value: string) {
    const next = new URLSearchParams(searchParams)
    if (!value) next.delete(key)
    else next.set(key, value)
    setCursorStack([null])
    setCursorPage(0)
    setSearchParams(next, { replace: true })
  }

  const filterChips = [
    ...(q.trim()
      ? [
          {
            key: 'q',
            label: q.trim(),
            onRemove: () => updateParam('q', ''),
          },
        ]
      : []),
    ...(collectionParam
      ? [
          {
            key: 'collection',
            label: collectionLabel(collectionParam, t),
            onRemove: () => updateParam('collection', ''),
          },
        ]
      : []),
  ]

  const inspector = inspected ? (
    <InspectorSheet
      title={inspected.doc_number ?? inspected.id.slice(0, 8)}
      subtitle={inspected.client_display_name || '—'}
      badges={
        <>
          <Badge variant="outline">{inspected.document_status}</Badge>
          <Badge variant="secondary">{collectionLabel(inspected.collection_status, t)}</Badge>
        </>
      }
      fields={[
        {
          label: t('projects.commercial.total', 'Total'),
          value: `${moneyFmt.format(centsToEuros(inspected.total_cents))} €`,
        },
        {
          label: t('projects.collections.remaining', 'Pendent'),
          value: `${moneyFmt.format(centsToEuros(inspected.remaining_cents))} €`,
        },
        {
          label: '#DN',
          value: String(inspected.delivery_count),
        },
        {
          label: t('projects.collections.issued_on', 'Data'),
          value:
            inspected.issued_on ||
            (inspected.issued_at
              ? new Date(inspected.issued_at).toLocaleDateString('ca-ES')
              : '—'),
        },
      ]}
      onClose={() => setInspectId(null)}
      footer={
        <>
          <Button
            type="button"
            size="sm"
            onClick={() => void navigate(`/sales/invoices/${inspected.id}`)}
          >
            {t('common:list.open_record', 'Obrir fitxa')}
          </Button>
          {inspected.remaining_cents > 0 && inspected.document_status === 'issued' ? (
            <Button
              type="button"
              size="sm"
              variant="outline"
              onClick={() => void navigate(`/sales/invoices/${inspected.id}?collect=1`)}
            >
              {t('projects.sales.collect_invoice', 'Cobrar factura')}
            </Button>
          ) : null}
        </>
      }
    />
  ) : null

  const toolbar = (
    <div className="space-y-2">
      <div className="flex flex-wrap items-center gap-2">
        <Input
          value={q}
          onChange={(e) => updateParam('q', e.target.value)}
          placeholder={t('projects.quotes.search', 'Cerca…')}
          className="max-w-xs"
        />
        <ListViewToggle
          mode={mode}
          onModeChange={setMode}
          density={density}
          onDensityChange={setDensity}
          showDensity={effectiveMode === 'table'}
        />
      </div>
      <FilterChips
        chips={filterChips}
        clearAllLabel={t('common:list.clear_filters', 'Netejar filtres')}
        onClearAll={() => {
          updateParam('q', '')
          updateParam('collection', '')
        }}
      />
    </div>
  )
  return (
    <PageShell
      bare
      toolbar={toolbar}
      inspector={inspector}
      inspectorOpen={Boolean(inspectId)}
      onInspectorClose={() => setInspectId(null)}
    >
      <div className="space-y-4">
        {query.isLoading ? (
          <div className="space-y-2" aria-busy>
            {[1, 2, 3, 4, 5].map((i) => (
              <div key={i} className="h-10 animate-pulse rounded-md bg-muted/60" />
            ))}
          </div>
        ) : null}
        {query.error ? (
          <p className="text-sm text-destructive" role="alert">
            {query.error instanceof Error
              ? query.error.message
              : t('projects.collections.load_failed', 'Error en carregar')}
          </p>
        ) : null}

        {!query.isLoading && effectiveMode === 'table' ? (
          <SalesDataTable
            columns={columns}
            rows={items}
            getRowId={(row) => row.id}
            density={density}
            activeRowId={inspectId}
            onRowActivate={(row) => setInspectId(row.id)}
            selectedIds={selected}
            onToggleRow={(row) =>
              setSelected((cur) =>
                cur.includes(row.id) ? cur.filter((id) => id !== row.id) : [...cur, row.id],
              )
            }
            onToggleAll={(checked) => setSelected(checked ? items.map((r) => r.id) : [])}
            sortKey={sortKey}
            sortDir={sortDir}
            onSort={(columnId) => {
              setCursorStack([null])
              setCursorPage(0)
              if (sortKey === columnId) {
                setSortDir((d) => (d === 'asc' ? 'desc' : 'asc'))
              } else {
                setSortKey(columnId)
                setSortDir('desc')
              }
            }}
            countLabel={t('common:list.showing_count', 'Mostrant {{shown}} de {{total}}', {
              shown: items.length,
              total: totalCount,
            })}
            bulkBar={
              <div className="flex items-center gap-2 rounded-lg border border-border bg-muted/30 px-3 py-1.5 text-sm">
                {t('projects.sales.selected_count', '{{count}} seleccionats', {
                  count: selected.length,
                })}
              </div>
            }
            rowActions={(row) => [
              {
                key: 'peek',
                label: t('projects.commercial.view', 'Veure'),
                onSelect: () => setInspectId(row.id),
              },
              {
                key: 'open',
                label: t('common:list.open_record', 'Obrir fitxa'),
                onSelect: () => {
                  void navigate(`/sales/invoices/${row.id}`)
                },
              },
              ...(row.remaining_cents > 0 && row.document_status === 'issued'
                ? [
                    {
                      key: 'collect',
                      label: t('projects.sales.collect_invoice', 'Cobrar factura'),
                      onSelect: () => {
                        void navigate(`/sales/invoices/${row.id}?collect=1`)
                      },
                    },
                  ]
                : []),
            ]}
            empty={
              <p className="rounded-xl border border-dashed border-border p-8 text-center text-sm text-muted-foreground">
                {t('projects.collections.invoices_empty', 'No hi ha factures amb aquests filtres.')}
              </p>
            }
          />
        ) : null}

        {!query.isLoading && effectiveMode === 'cards' ? (
          items.length === 0 ? (
            <p className="rounded-xl border border-dashed border-border p-8 text-center text-sm text-muted-foreground">
              {t('projects.collections.invoices_empty', 'No hi ha factures amb aquests filtres.')}
            </p>
          ) : (
            <ul className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
              {items.map((row) => (
                <li key={row.id}>
                  <SalesDocCard
                    title={row.doc_number ?? row.id.slice(0, 8)}
                    subtitle={row.client_display_name || '—'}
                    amount={`${moneyFmt.format(centsToEuros(row.total_cents))} €`}
                    amountHint={
                      row.remaining_cents > 0
                        ? `${t('projects.collections.remaining', 'Pendent')} ${moneyFmt.format(centsToEuros(row.remaining_cents))} €`
                        : undefined
                    }
                    tone={collectionTone(row.collection_status)}
                    active={inspectId === row.id}
                    onClick={() => setInspectId(row.id)}
                    badges={
                      <>
                        <Badge variant="outline">{row.document_status}</Badge>
                        <Badge
                          variant={row.collection_status === 'paid' ? 'default' : 'secondary'}
                        >
                          {collectionLabel(row.collection_status, t)}
                        </Badge>
                      </>
                    }
                    meta={
                      <>
                        {row.issued_on ||
                          (row.issued_at
                            ? new Date(row.issued_at).toLocaleDateString('ca-ES')
                            : '—')}
                        {row.delivery_count > 0 ? ` · ${row.delivery_count} DN` : null}
                      </>
                    }
                  />
                </li>
              ))}
            </ul>
          )
        ) : null}

        {cursorPage > 0 || hasMore ? (
          <div className="flex items-center justify-between gap-2">
            <Button
              type="button"
              variant="outline"
              size="sm"
              disabled={cursorPage <= 0}
              onClick={() => setCursorPage((p) => Math.max(0, p - 1))}
            >
              {t('common.prev', 'Anterior')}
            </Button>
            <span className="text-xs text-muted-foreground">
              {cursorPage + 1}
              {hasMore ? '+' : ''}
            </span>
            <Button
              type="button"
              variant="outline"
              size="sm"
              disabled={!hasMore}
              onClick={() => {
                const next = query.data?.nextCursor
                if (!next) return
                setCursorStack((stack) => {
                  const trimmed = stack.slice(0, cursorPage + 1)
                  return [...trimmed, next]
                })
                setCursorPage((p) => p + 1)
              }}
            >
              {t('common.next', 'Següent')}
            </Button>
          </div>
        ) : null}
      </div>
    </PageShell>
  )
}
