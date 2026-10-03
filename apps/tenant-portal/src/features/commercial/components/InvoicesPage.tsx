import { useMemo, useState } from 'react'
import { Link, useNavigate, useSearchParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import {
  listSalesInvoicesPage,
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

function collectionLabel(
  status: string,
  t: (key: string, fallback: string) => string,
): string {
  if (status === 'paid') return t('projects.sales.collection_paid', 'Cobrat')
  if (status === 'partial') return t('projects.sales.collection_partial', 'Parcial')
  return t('projects.sales.collection_pending', 'Pendent de cobrar')
}

/** Hub list for /sales/invoices — list_sales_invoices_page + SalesDataTable. */
export function InvoicesPage() {
  const { t } = useTranslation('projects')
  const navigate = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()
  const q = searchParams.get('q') ?? ''
  const [selected, setSelected] = useState<string[]>([])
  const [sortKey, setSortKey] = useState<string | null>('issued_at')
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('desc')
  const [cursorStack, setCursorStack] = useState<Array<SalesListCursor | null>>([null])
  const [cursorPage, setCursorPage] = useState(0)

  const filters = useMemo(
    () => ({
      q: q.trim().length >= 2 ? q.trim() : null,
      sort: (sortKey === 'doc_number' || sortKey === 'total' ? sortKey : 'issued_at') as
        | 'issued_at'
        | 'doc_number'
        | 'total',
      dir: sortDir,
      cursor: cursorStack[cursorPage] ?? null,
      limit: PAGE_SIZE,
    }),
    [q, sortKey, sortDir, cursorStack, cursorPage],
  )

  const query = useQuery({
    queryKey: ['sales_invoices', filters],
    queryFn: () => listSalesInvoicesPage(filters),
  })

  const items = query.data?.items ?? []
  const totalCount = query.data?.totalCount ?? 0
  const hasMore = Boolean(query.data?.hasMore)

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

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-lg font-semibold">
          {t('projects.sales.invoices_stub_title', 'Factures')}
        </h2>
        <p className="text-sm text-muted-foreground">
          {t(
            'projects.sales.invoices_stub_subtitle',
            'Factures emeses i pendents de cobrament.',
          )}
        </p>
      </div>

      <div className="flex flex-wrap gap-2">
        <Input
          value={q}
          onChange={(e) => updateParam('q', e.target.value)}
          placeholder={t('projects.quotes.search', 'Cerca…')}
          className="max-w-xs"
        />
      </div>

      {query.isLoading ? (
        <p className="text-sm text-muted-foreground">{t('projects.quotes.loading', 'Carregant…')}</p>
      ) : null}
      {query.error ? (
        <p className="text-sm text-destructive" role="alert">
          {query.error instanceof Error
            ? query.error.message
            : t('projects.collections.load_failed', 'Error en carregar')}
        </p>
      ) : null}

      <SalesDataTable
        columns={columns}
        rows={items}
        getRowId={(row) => row.id}
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
        countLabel={t('projects.sales.rows_count', '{{count}} files', { count: totalCount })}
        bulkBar={
          <div className="flex items-center gap-2 rounded-lg border border-border bg-muted/30 px-3 py-1.5 text-sm">
            {t('projects.sales.selected_count', '{{count}} seleccionats', {
              count: selected.length,
            })}
          </div>
        }
        rowActions={(row) => [
          {
            key: 'open',
            label: t('projects.commercial.view', 'Veure'),
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
          <p className="text-sm text-muted-foreground">
            {t('projects.collections.invoices_empty', 'No hi ha factures amb aquests filtres.')}
          </p>
        }
      />

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
  )
}
