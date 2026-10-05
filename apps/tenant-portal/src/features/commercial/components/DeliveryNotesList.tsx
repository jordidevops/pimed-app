import { useEffect, useMemo, useRef, useState } from 'react'
import { Link, Navigate, useLocation, useNavigate, useSearchParams } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Search } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Badge } from '@/components/ui/badge'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import { useIsFieldService, useSectorLabel } from '@/hooks/useSectorLabel'
import { useListViewMode } from '@/hooks/useListViewMode'
import { useListDensity } from '@/hooks/useListDensity'
import { PageShell } from '@/components/layout/PageShell'
import { InspectorSheet } from '@/components/layout/InspectorSheet'
import { ListViewToggle } from '@/components/layout/ListViewToggle'
import { FilterChips } from '@/components/layout/FilterChips'
import { SalesDocCard } from './SalesDocCard'
import { passesGate, useNavGateContext } from '@/features/sidebar-nav'
import { ClientFilterControl } from '@/features/contacts/components/ClientFilterControl'
import { generateClientOpId } from '@/features/attendance/api/clientOpId'
import { localDateIso, localDayRange } from '@/lib/dateLocal'
import {
  commercialDocumentOrderPath,
  listDeliveryNotesPage,
  listDocumentPayments,
  listExternalInvoicesPage,
  listPaymentsForDocuments,
  listSalesDeliveryNotesPage,
  issueInvoiceFromDeliveryNotes,
  previewNextDocumentNumber,
  recordInvoicePayment,
  type DeliveryNoteListRow,
  type ExternalInvoiceListRow,
  type SalesBillingStatus,
  type SalesDeliveryNoteListRow,
  type SalesListCursor,
} from '../api/commercialFlowService'
import { commercialErrorMessage } from '../utils/commercialErrorMessage'
import { centsToEuros } from '../utils/paymentReceipt'
import { CollectPaymentDialog } from './CollectPaymentDialog'
import { CommercialDocumentShareSheet } from './CommercialDocumentShareSheet'
import { CommercialDocumentView } from './CommercialDocumentView'
import { CommercialNativeSignDialog } from './CommercialNativeSignDialog'
import { PaymentReceiptSheet } from './PaymentReceiptSheet'
import { RectifyDeliveryNoteDialog } from './RectifyDeliveryNoteDialog'
import { SalesDataTable, type SalesDataTableColumn } from './SalesDataTable'

const moneyFmt = new Intl.NumberFormat('ca-ES', {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
})

const STATUS_GROUPS = ['open', 'pending', 'partial', 'paid', 'all'] as const
const BILLING_CHIPS: Array<{ value: SalesBillingStatus | 'all'; labelKey: string; labelDefault: string }> = [
  { value: 'all', labelKey: 'projects.quotes.filter_all', labelDefault: 'Tots' },
  { value: 'to_invoice', labelKey: 'projects.sales.billing_to_invoice', labelDefault: 'Per facturar' },
  { value: 'invoiced', labelKey: 'projects.sales.billing_invoiced', labelDefault: 'Facturat' },
  { value: 'rectified', labelKey: 'projects.sales.billing_rectified', labelDefault: 'Rectificat' },
]
const PAGE_SIZE = 50

type StatusGroup = (typeof STATUS_GROUPS)[number]

function collectionFilterFromStatusGroup(
  statusGroup: StatusGroup,
): Array<'pending' | 'partial' | 'paid'> | null {
  if (statusGroup === 'open') return ['pending', 'partial']
  if (statusGroup === 'pending' || statusGroup === 'partial' || statusGroup === 'paid') {
    return [statusGroup]
  }
  return null
}

function billingLabelForSalesRow(
  status: SalesBillingStatus | string,
  t: (key: string, fallback: string) => string,
): string {
  if (status === 'rectified') return t('projects.sales.billing_rectified', 'Rectificat')
  if (status === 'invoiced') return t('projects.sales.billing_invoiced', 'Facturat')
  if (status === 'draft_invoice') return t('projects.sales.billing_draft', 'En esborrany')
  return t('projects.sales.billing_to_invoice', 'Per facturar')
}

/** Adapt sales RPC rows to the legacy list shape used by collect/select actions. */
function salesRowToLegacy(row: SalesDeliveryNoteListRow): DeliveryNoteListRow {
  return {
    id: row.id,
    doc_number: row.doc_number,
    client_id: row.client_id,
    client_display_name: row.client_display_name,
    project_id: row.project_id,
    project_name: row.project_name,
    document_status: row.document_status,
    billing_status: row.billing_status,
    collection_status:
      row.billing_status === 'rectified'
        ? 'rectified'
        : (row.collection_status as DeliveryNoteListRow['collection_status']),
    total: Number(row.total ?? 0),
    total_cents: Number(row.total_cents ?? 0),
    direct_paid_cents: 0,
    inherited_paid_cents: 0,
    advance_applied_cents: 0,
    paid_cents: Number(row.paid_cents ?? 0),
    remaining_cents: Number(row.remaining_cents ?? 0),
    issued_at: row.issued_at,
    created_at: row.created_at,
    external_invoice_id: row.invoice_id,
    external_invoice_ref: row.invoice_doc_number,
    supersedes_id: null,
    superseded_by_id: null,
    superseded_by_number: null,
  }
}

function rowBillingStatus(row: DeliveryNoteListRow): SalesBillingStatus | 'to_invoice' {
  if (row.billing_status) return row.billing_status
  if (row.collection_status === 'rectified') return 'rectified'
  if (row.external_invoice_id || row.external_invoice_ref) return 'invoiced'
  return 'to_invoice'
}

function canSelectForInvoice(row: DeliveryNoteListRow, selectedClientId: string | null): boolean {
  const active =
    row.collection_status !== 'rectified' && row.document_status !== 'cancelled'
  return (
    active &&
    rowBillingStatus(row) === 'to_invoice' &&
    (!selectedClientId || row.client_id === selectedClientId)
  )
}

function canCollectOrRectifyDn(row: DeliveryNoteListRow): boolean {
  const billing = rowBillingStatus(row)
  if (billing === 'draft_invoice' || billing === 'invoiced' || billing === 'rectified') {
    return false
  }
  return row.document_status !== 'cancelled'
}

export function DeliveryNotesList({
  clientId: lockedClientId,
  projectId: lockedProjectId,
  embedded = false,
  defaultStatus = 'open',
}: {
  clientId?: string | null
  projectId?: string | null
  embedded?: boolean
  defaultStatus?: StatusGroup
}) {
  const { t } = useTranslation(['projects', 'field-service', 'common'])
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const isFieldService = useIsFieldService()
  const projectLabel = useSectorLabel(
    'project',
    isFieldService
      ? t('field-service:orders.singular', 'OS')
      : t('projects.list.singular', 'Projecte'),
  )
  const { ctx, gatesLoading } = useNavGateContext()
  const isOffice = !gatesLoading && passesGate('isOffice', ctx)
  const projectBase = isFieldService ? '/field/orders' : '/projects'
  const location = useLocation()
  const navigate = useNavigate()
  const isSalesHub = location.pathname.startsWith('/sales')
  const [searchParams, setSearchParams] = useSearchParams()
  const viewParam = !embedded ? searchParams.get('view') : null

  const [localStatus, setLocalStatus] = useState<StatusGroup>(defaultStatus)
  const [localExt, setLocalExt] = useState<'all' | 'yes' | 'no'>('all')
  const [localQ, setLocalQ] = useState('')
  const [localPage, setLocalPage] = useState(1)
  const [localView, setLocalView] = useState<'notes' | 'invoices'>('notes')
  const [localIssuedFrom, setLocalIssuedFrom] = useState('')
  const [localIssuedTo, setLocalIssuedTo] = useState('')
  const [includeRectified, setIncludeRectified] = useState(false)
  const [localBilling, setLocalBilling] = useState<SalesBillingStatus | 'all'>('all')
  const [cursorStack, setCursorStack] = useState<Array<SalesListCursor | null>>([null])
  const [cursorPage, setCursorPage] = useState(0)

  const useSalesList = isSalesHub && !embedded
  const statusGroup = embedded
    ? localStatus
    : STATUS_GROUPS.includes(searchParams.get('status') as StatusGroup)
      ? (searchParams.get('status') as StatusGroup)
      : defaultStatus
  const hasExternalRef = embedded
    ? localExt
    : (['all', 'yes', 'no'] as const).includes(searchParams.get('ext_ref') as 'all' | 'yes' | 'no')
      ? (searchParams.get('ext_ref') as 'all' | 'yes' | 'no')
      : 'all'
  const billingFilter = embedded
    ? localBilling
    : (['all', 'to_invoice', 'invoiced', 'rectified', 'draft_invoice'] as const).includes(
          searchParams.get('billing') as SalesBillingStatus | 'all',
        )
      ? (searchParams.get('billing') as SalesBillingStatus | 'all')
      : 'all'
  const q = embedded ? localQ : (searchParams.get('q') ?? '')
  const issuedFrom = embedded ? localIssuedFrom : (searchParams.get('issued_from') ?? '')
  const issuedTo = embedded ? localIssuedTo : (searchParams.get('issued_to') ?? '')
  const page = embedded ? localPage : Math.max(1, Number(searchParams.get('page') || '1') || 1)
  const surface: 'notes' | 'invoices' = isSalesHub
    ? 'notes'
    : embedded
      ? localView
      : searchParams.get('surface') === 'invoices'
        ? 'invoices'
        : 'notes'
  const clientId = lockedClientId ?? (embedded ? null : searchParams.get('client_id')?.trim() || null)
  const projectId = lockedProjectId ?? (embedded ? null : searchParams.get('project_id')?.trim() || null)

  const [searchDraft, setSearchDraft] = useState(q)
  const [selected, setSelected] = useState<string[]>([])
  const [inspectId, setInspectId] = useState<string | null>(null)
  const { mode: listMode, setMode: setListMode, effectiveMode } = useListViewMode(
    'sales.delivery-notes',
    'table',
  )
  const { density, setDensity } = useListDensity('sales.delivery-notes', 'compact')
  const [collectRow, setCollectRow] = useState<DeliveryNoteListRow | null>(null)
  const [viewDocId, setViewDocId] = useState<string | null>(null)

  useEffect(() => {
    if (embedded || isSalesHub) return
    const view = searchParams.get('view')
    if (view) setViewDocId(view)
  }, [embedded, isSalesHub, searchParams])

  useEffect(() => {
    if (!isSalesHub || !inspectId) return
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === 'Escape') {
        event.preventDefault()
        setInspectId(null)
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [isSalesHub, inspectId])

  const [shareDocId, setShareDocId] = useState<string | null>(null)
  const [signDocId, setSignDocId] = useState<string | null>(null)
  const [receiptPaymentId, setReceiptPaymentId] = useState<string | null>(null)
  const [rectifyDocId, setRectifyDocId] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [invoiceOpen, setInvoiceOpen] = useState(false)
  const [invoiceNumberPreview, setInvoiceNumberPreview] = useState('')
  const [erpReference, setErpReference] = useState('')
  const [invoiceDate, setInvoiceDate] = useState(() => localDateIso())
  const [invoiceTotal, setInvoiceTotal] = useState('')
  const [payInvoice, setPayInvoice] = useState<ExternalInvoiceListRow | null>(null)
  const [payAmount, setPayAmount] = useState('')
  const [payMethod, setPayMethod] = useState('transfer')
  const [payReference, setPayReference] = useState('')
  const issueOpIdRef = useRef<string | null>(null)
  const issueSelectionKeyRef = useRef<string | null>(null)
  const payOpIdRef = useRef<string | null>(null)
  const payIntentKeyRef = useRef<string | null>(null)

  function resetIssueOpId() {
    issueOpIdRef.current = null
    issueSelectionKeyRef.current = null
  }

  function clientOpIdForIssue(deliveryNoteIds: string[]): string {
    const key = [...deliveryNoteIds].sort().join(',')
    if (issueSelectionKeyRef.current !== key || !issueOpIdRef.current) {
      issueSelectionKeyRef.current = key
      issueOpIdRef.current = generateClientOpId()
    }
    return issueOpIdRef.current
  }

  function resetPayOpId() {
    payOpIdRef.current = null
    payIntentKeyRef.current = null
  }

  function clientOpIdForPayment(amountCents: number, method: string, reference: string): string {
    const key = `${amountCents}|${method}|${reference}`
    if (payIntentKeyRef.current !== key || !payOpIdRef.current) {
      payIntentKeyRef.current = key
      payOpIdRef.current = generateClientOpId()
    }
    return payOpIdRef.current
  }

  function resetCursorPaging() {
    setCursorStack([null])
    setCursorPage(0)
  }

  function updateParam(name: string, value: string | null) {
    if (embedded) {
      if (name === 'status' && value && STATUS_GROUPS.includes(value as StatusGroup)) {
        setLocalStatus(value as StatusGroup)
      }
      if (name === 'ext_ref') setLocalExt((value as 'yes' | 'no' | null) ?? 'all')
      if (name === 'billing') {
        setLocalBilling((value as SalesBillingStatus | 'all' | null) ?? 'all')
      }
      if (name === 'q') setLocalQ(value ?? '')
      if (name === 'surface') setLocalView(value === 'invoices' ? 'invoices' : 'notes')
      if (name === 'issued_from') setLocalIssuedFrom(value ?? '')
      if (name === 'issued_to') setLocalIssuedTo(value ?? '')
      if (name === 'page') setLocalPage(Math.max(1, Number(value || '1') || 1))
      else if (name !== 'page') {
        setLocalPage(1)
        resetCursorPaging()
      }
      return
    }
    const next = new URLSearchParams(searchParams)
    if (!value) next.delete(name)
    else next.set(name, value)
    if (name !== 'page') {
      next.delete('page')
      resetCursorPaging()
    }
    setSearchParams(next, { replace: true })
  }

  const noteFilters = useMemo(
    () => ({
      clientId,
      projectId,
      statusGroup,
      hasExternalRef,
      q,
      issuedFrom: issuedFrom ? localDayRange(issuedFrom).from : null,
      issuedTo: issuedTo ? localDayRange(issuedTo).to : null,
      includeRectified,
      limit: PAGE_SIZE,
      offset: (page - 1) * PAGE_SIZE,
    }),
    [clientId, projectId, statusGroup, hasExternalRef, q, issuedFrom, issuedTo, includeRectified, page],
  )

  const salesNoteFilters = useMemo(
    () => ({
      clientId,
      projectId,
      q: q.trim().length >= 2 ? q.trim() : null,
      billingStatus:
        billingFilter === 'all' ? null : ([billingFilter] as SalesBillingStatus[]),
      collectionStatus: collectionFilterFromStatusGroup(statusGroup),
      dateFrom: issuedFrom ? localDayRange(issuedFrom).from : null,
      dateTo: issuedTo ? localDayRange(issuedTo).to : null,
      cursor: cursorStack[cursorPage] ?? null,
      limit: PAGE_SIZE,
    }),
    [
      clientId,
      projectId,
      q,
      billingFilter,
      statusGroup,
      issuedFrom,
      issuedTo,
      cursorStack,
      cursorPage,
    ],
  )

  const notesQuery = useQuery({
    queryKey: ['delivery_notes', noteFilters],
    queryFn: () => listDeliveryNotesPage(noteFilters),
    enabled: surface === 'notes' && !useSalesList,
  })
  const salesNotesQuery = useQuery({
    queryKey: ['sales_delivery_notes', salesNoteFilters],
    queryFn: () => listSalesDeliveryNotesPage(salesNoteFilters),
    enabled: surface === 'notes' && useSalesList,
  })
  const invoicesQuery = useQuery({
    queryKey: ['external_invoices', clientId, projectId, q, page],
    queryFn: () =>
      listExternalInvoicesPage({
        clientId,
        projectId,
        q,
        limit: PAGE_SIZE,
        offset: (page - 1) * PAGE_SIZE,
      }),
    enabled: surface === 'invoices',
  })

  const salesItems = salesNotesQuery.data?.items ?? []
  const items = useSalesList
    ? salesItems.map(salesRowToLegacy)
    : (notesQuery.data?.items ?? [])
  const invoices = invoicesQuery.data?.items ?? []
  const { data: collectPayments = [] } = useQuery({
    queryKey: ['commercial_payments', 'delivery-note', collectRow?.id],
    queryFn: () => listPaymentsForDocuments(collectRow ? [collectRow.id] : []),
    enabled: !!collectRow,
  })
  const totalCount =
    surface === 'notes'
      ? useSalesList
        ? (salesNotesQuery.data?.totalCount ?? 0)
        : (notesQuery.data?.totalCount ?? 0)
      : (invoicesQuery.data?.totalCount ?? 0)
  const totalRemainingCents =
    surface === 'notes'
      ? useSalesList
        ? items.reduce((sum, row) => sum + row.remaining_cents, 0)
        : (notesQuery.data?.totalRemainingCents ?? 0)
      : (invoicesQuery.data?.totalRemainingCents ?? 0)
  const salesHasMore = Boolean(salesNotesQuery.data?.hasMore)
  const totalPages = useSalesList
    ? Math.max(1, cursorPage + 1 + (salesHasMore ? 1 : 0))
    : Math.max(1, Math.ceil(totalCount / PAGE_SIZE))
  const selectedRows = items.filter((row) => selected.includes(row.id))
  const selectedClientId = selectedRows[0]?.client_id ?? null
  const selectedTotalCents = selectedRows.reduce((sum, row) => sum + row.total_cents, 0)
  const typedInvoiceCents = selectedTotalCents
  const inspectedRow = items.find((row) => row.id === inspectId) ?? null

  const salesFilterChips = useSalesList
    ? [
        ...(q.trim()
          ? [{ key: 'q', label: q.trim(), onRemove: () => updateParam('q', null) }]
          : []),
        ...(billingFilter !== 'all'
          ? [
              {
                key: 'billing',
                label: billingLabelForSalesRow(billingFilter, t),
                onRemove: () => updateParam('billing', null),
              },
            ]
          : []),
        ...(statusGroup !== 'open' && statusGroup !== 'all'
          ? [
              {
                key: 'status',
                label:
                  statusGroup === 'pending'
                    ? t('projects.collections.status_pending', 'Pendent')
                    : statusGroup === 'partial'
                      ? t('projects.collections.status_partial', 'Parcial')
                      : t('projects.collections.status_paid', 'Cobrat'),
                onRemove: () => updateParam('status', 'open'),
              },
            ]
          : []),
        ...(clientId
          ? [
              {
                key: 'client',
                label: t('projects.quotes.client', 'Client'),
                onRemove: () => updateParam('client_id', null),
              },
            ]
          : []),
      ]
    : []

  const salesInspector =
    useSalesList && inspectedRow ? (
      <InspectorSheet
        title={inspectedRow.doc_number ?? inspectedRow.id.slice(0, 8)}
        subtitle={
          inspectedRow.client_display_name ||
          t('projects.quotes.unknown_client', 'Sense client')
        }
        badges={
          <>
            <Badge variant="outline">
              {billingLabelForSalesRow(rowBillingStatus(inspectedRow), t)}
            </Badge>
            <Badge variant="secondary">
              {inspectedRow.collection_status === 'paid'
                ? t('projects.sales.collection_paid', 'Cobrat')
                : inspectedRow.collection_status === 'partial'
                  ? t('projects.sales.collection_partial', 'Parcial')
                  : inspectedRow.collection_status === 'rectified'
                    ? t('projects.collections.status_rectified', 'Rectificat')
                    : t('projects.sales.collection_pending', 'Pendent de cobrar')}
            </Badge>
          </>
        }
        fields={[
          {
            label: t('projects.commercial.total', 'Total'),
            value: `${moneyFmt.format(centsToEuros(inspectedRow.total_cents))} €`,
          },
          {
            label: t('projects.collections.remaining', 'Pendent'),
            value: `${moneyFmt.format(centsToEuros(inspectedRow.remaining_cents))} €`,
          },
          {
            label: projectLabel,
            value: inspectedRow.project_id ? (
              <Link
                to={commercialDocumentOrderPath(
                  projectBase,
                  inspectedRow.project_id,
                  'delivery_note',
                )}
                className="text-primary underline-offset-2 hover:underline"
              >
                {inspectedRow.project_name?.trim() || projectLabel}
              </Link>
            ) : (
              inspectedRow.project_name?.trim() || '—'
            ),
          },
          {
            label: t('projects.collections.issued_on', 'Data'),
            value: inspectedRow.issued_at
              ? new Date(inspectedRow.issued_at).toLocaleDateString('ca-ES')
              : '—',
          },
        ]}
        onClose={() => setInspectId(null)}
        footer={
          <>
            <Button
              type="button"
              size="sm"
              onClick={() => void navigate(`/sales/delivery-notes/${inspectedRow.id}`)}
            >
              {t('common:list.open_record', 'Obrir fitxa')}
            </Button>
            {canCollectOrRectifyDn(inspectedRow) && inspectedRow.remaining_cents > 0 ? (
              <Button
                type="button"
                size="sm"
                variant="outline"
                onClick={() => setCollectRow(inspectedRow)}
              >
                {t('projects.commercial.collect', 'Cobrar')}
              </Button>
            ) : null}
            {inspectedRow.collection_status !== 'rectified' &&
            inspectedRow.document_status !== 'cancelled' ? (
              <Button
                type="button"
                size="sm"
                variant="outline"
                onClick={() => setShareDocId(inspectedRow.id)}
              >
                {t('projects.commercial.send', 'Enviar')}
              </Button>
            ) : null}
          </>
        }
      />
    ) : null

  function openInvoiceModal() {
    const issuedOn = localDateIso()
    resetIssueOpId()
    setErpReference('')
    setInvoiceDate(issuedOn)
    setInvoiceTotal(moneyFmt.format(centsToEuros(selectedTotalCents)))
    setInvoiceNumberPreview('')
    setInvoiceOpen(true)
    void previewNextDocumentNumber({ docType: 'invoice', issuedOn })
      .then((next) => setInvoiceNumberPreview(next))
      .catch(() => setInvoiceNumberPreview(''))
  }

  function closeInvoiceModal() {
    setInvoiceOpen(false)
    resetIssueOpId()
  }

  function invalidate() {
    void queryClient.invalidateQueries({ queryKey: ['delivery_notes'] })
    void queryClient.invalidateQueries({ queryKey: ['sales_delivery_notes'] })
    void queryClient.invalidateQueries({ queryKey: ['sales_dashboard_kpis'] })
    void queryClient.invalidateQueries({ queryKey: ['external_invoices'] })
    void queryClient.invalidateQueries({ queryKey: ['sales_invoices'] })
    void queryClient.invalidateQueries({ queryKey: ['project_delivery_summary'] })
    void queryClient.invalidateQueries({ queryKey: ['commercial_documents'] })
  }

  function goNextSalesPage() {
    const next = salesNotesQuery.data?.nextCursor
    if (!next || !salesHasMore) return
    setCursorStack((stack) => {
      const trimmed = stack.slice(0, cursorPage + 1)
      return [...trimmed, next]
    })
    setCursorPage((p) => p + 1)
  }

  function goPrevSalesPage() {
    if (cursorPage <= 0) return
    setCursorPage((p) => p - 1)
  }

  function toggleSelected(row: DeliveryNoteListRow) {
    setSelected((current) => {
      if (current.includes(row.id)) return current.filter((id) => id !== row.id)
      if (selectedClientId && row.client_id !== selectedClientId) return current
      return [...current, row.id]
    })
  }

  async function submitInvoice() {
    const deliveryNoteIds = selectedRows.map((row) => row.id)
    setBusy(true)
    try {
      const result = await issueInvoiceFromDeliveryNotes({
        issuedOn: invoiceDate,
        deliveryNoteIds,
        erpReference: erpReference.trim() || null,
        allocateNumber: true,
        clientOpId: clientOpIdForIssue(deliveryNoteIds),
      })
      toast({
        title: t('projects.collections.invoice_registered', 'Factura registrada'),
        description: erpReference.trim()
          ? t(
              'projects.sales.invoice_with_erp_ref',
              'Número PiMed assignat. Ref. ERP: {{ref}}',
              { ref: erpReference.trim() },
            )
          : t('projects.sales.invoice_number_allocated', 'Número assignat per la sèrie del tenant.'),
      })
      closeInvoiceModal()
      setSelected([])
      invalidate()
      if (isSalesHub && result.id) {
        void navigate(`/sales/invoices/${result.id}`)
      }
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('projects.commercial.error', 'Error comercial'),
        description: commercialErrorMessage(err),
      })
    } finally {
      setBusy(false)
    }
  }

  async function submitInvoicePayment() {
    if (!payInvoice) return
    const amountCents = Math.round(Number(payAmount.replace(',', '.')) * 100)
    const reference = payReference.trim()
    setBusy(true)
    try {
      const payment = await recordInvoicePayment({
        invoiceId: payInvoice.id,
        amountCents,
        method: payMethod,
        reference: reference || null,
        clientOpId: clientOpIdForPayment(amountCents, payMethod, reference),
      })
      setPayInvoice(null)
      resetPayOpId()
      setReceiptPaymentId(payment.paymentId)
      invalidate()
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('projects.commercial.error', 'Error comercial'),
        description: commercialErrorMessage(err),
      })
    } finally {
      setBusy(false)
    }
  }

  const isLoading =
    surface === 'notes'
      ? useSalesList
        ? salesNotesQuery.isLoading
        : notesQuery.isLoading
      : invoicesQuery.isLoading
  const error =
    surface === 'notes'
      ? useSalesList
        ? salesNotesQuery.error
        : notesQuery.error
      : invoicesQuery.error

  const filtersBlock = (
      <div className={useSalesList ? 'space-y-3' : 'space-y-3 rounded-2xl border border-border bg-card p-4'}>
        {!isSalesHub ? (
          <div className="flex flex-wrap gap-2">
            <Button
              type="button"
              size="sm"
              variant={surface === 'notes' ? 'default' : 'outline'}
              onClick={() => updateParam('surface', null)}
            >
              {t('projects.collections.surface_notes', 'Albarans')}
            </Button>
            <Button
              type="button"
              size="sm"
              variant={surface === 'invoices' ? 'default' : 'outline'}
              onClick={() => updateParam('surface', 'invoices')}
            >
              {t('projects.collections.surface_invoices', 'Factures')}
            </Button>
          </div>
        ) : null}
        <div className="flex flex-wrap items-center gap-2">
          <label className="relative block min-w-[12rem] flex-1">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              className="pl-9"
              value={searchDraft}
              onChange={(event) => setSearchDraft(event.target.value)}
              onBlur={() => updateParam('q', searchDraft.trim() || null)}
              onKeyDown={(event) => {
                if (event.key === 'Enter') updateParam('q', searchDraft.trim() || null)
              }}
              placeholder={t('projects.collections.search_placeholder', 'Número, client, OS o factura…')}
            />
          </label>
          {useSalesList ? (
            <ListViewToggle
              mode={listMode}
              onModeChange={setListMode}
              density={density}
              onDensityChange={setDensity}
              showDensity={effectiveMode === 'table'}
            />
          ) : null}
        </div>
        {surface === 'notes' && useSalesList ? (
          <div className="flex flex-wrap gap-2">
            {BILLING_CHIPS.map((chip) => (
              <Button
                key={chip.value}
                type="button"
                size="sm"
                variant={billingFilter === chip.value ? 'default' : 'outline'}
                onClick={() =>
                  updateParam('billing', chip.value === 'all' ? null : chip.value)
                }
              >
                {t(chip.labelKey, chip.labelDefault)}
              </Button>
            ))}
          </div>
        ) : null}
        {useSalesList ? (
          <FilterChips
            chips={salesFilterChips}
            clearAllLabel={t('common:list.clear_filters', 'Netejar filtres')}
            onClearAll={() => {
              updateParam('q', null)
              updateParam('billing', null)
              updateParam('status', 'open')
              updateParam('client_id', null)
              setSearchDraft('')
            }}
          />
        ) : null}
        {surface === 'notes' ? (
          <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
            {!lockedClientId && !embedded ? (
              <ClientFilterControl value={clientId} onChange={(id) => updateParam('client_id', id)} />
            ) : null}
            <label className="flex flex-col gap-1 text-xs text-muted-foreground">
              {t('projects.collections.filter_status', 'Estat cobrament')}
              <select
                className="h-10 rounded-md border border-input bg-background px-3 text-sm"
                value={statusGroup}
                onChange={(event) => updateParam('status', event.target.value)}
              >
                <option value="open">{t('projects.collections.filter_open', 'Oberts')}</option>
                <option value="pending">{t('projects.collections.status_pending', 'Pendent')}</option>
                <option value="partial">{t('projects.collections.status_partial', 'Parcial')}</option>
                <option value="paid">{t('projects.collections.status_paid', 'Cobrat')}</option>
                <option value="all">{t('projects.quotes.filter_all', 'Tots')}</option>
              </select>
            </label>
            {!useSalesList ? (
              <label className="flex flex-col gap-1 text-xs text-muted-foreground">
                {t('projects.collections.filter_ext_ref', 'Factura')}
                <select
                  className="h-10 rounded-md border border-input bg-background px-3 text-sm"
                  value={hasExternalRef}
                  onChange={(event) =>
                    updateParam('ext_ref', event.target.value === 'all' ? null : event.target.value)
                  }
                >
                  <option value="all">{t('projects.quotes.filter_all', 'Tots')}</option>
                  <option value="yes">{t('projects.collections.filter_ext_yes', 'Facturats')}</option>
                  <option value="no">{t('projects.collections.filter_ext_no', 'Sense factura')}</option>
                </select>
              </label>
            ) : null}
            <label className="flex flex-col gap-1 text-xs text-muted-foreground">
              {t('projects.collections.filter_issued_from', 'Des de')}
              <Input
                type="date"
                value={issuedFrom}
                onChange={(event) => updateParam('issued_from', event.target.value || null)}
              />
            </label>
            <label className="flex flex-col gap-1 text-xs text-muted-foreground">
              {t('projects.collections.filter_issued_to', 'Fins a')}
              <Input
                type="date"
                value={issuedTo}
                onChange={(event) => updateParam('issued_to', event.target.value || null)}
              />
            </label>
          </div>
        ) : null}
        {surface === 'notes' && !useSalesList ? (
          <label className="flex items-center gap-2 text-xs text-muted-foreground">
            <input
              type="checkbox"
              checked={includeRectified}
              onChange={(event) => {
                setIncludeRectified(event.target.checked)
                if (!embedded) setLocalPage(1)
              }}
            />
            {t('projects.collections.show_rectified', 'Mostrar rectificats')}
          </label>
        ) : null}
      </div>
  )

  const listBody = (
    <>
      {!embedded && !isSalesHub ? (
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-foreground">
              {t('projects.collections.title', 'Albarans')}
            </h1>
            <p className="mt-1 text-sm text-muted-foreground">
              {t(
                'projects.collections.subtitle',
                'Facturació i cobrament d’albarans des de Comercial.',
              )}
            </p>
          </div>
          <div className="rounded-xl border border-border bg-card px-4 py-3 text-right">
            <p className="text-xs text-muted-foreground">
              {t('projects.collections.total_remaining', 'Pendent filtrat')}
            </p>
            <p className="text-xl font-semibold tabular-nums">
              {moneyFmt.format(centsToEuros(totalRemainingCents))} €
            </p>
            <p className="text-xs text-muted-foreground">
              {surface === 'notes'
                ? t('projects.collections.rows_count', '{{count}} albarans', { count: totalCount })
                : t('projects.collections.invoice_count', '{{count}} factures', { count: totalCount })}
            </p>
          </div>
        </div>
      ) : null}

      {!useSalesList ? filtersBlock : null}

      {selectedRows.length > 0 && isOffice && !isSalesHub ? (
        <div className="flex flex-wrap items-center justify-between gap-2 rounded-xl border border-border bg-muted/30 px-3 py-2">
          <p className="text-sm">
            {t('projects.collections.selected_count', '{{count}} albarans · {{amount}} €', {
              count: selectedRows.length,
              amount: moneyFmt.format(centsToEuros(selectedTotalCents)),
            })}
          </p>
          <Button type="button" size="sm" onClick={openInvoiceModal}>
            {t('projects.collections.register_invoice', 'Registrar factura')}
          </Button>
        </div>
      ) : null}

      {isLoading ? <p className="text-sm text-muted-foreground">{t('projects.quotes.loading', 'Carregant…')}</p> : null}
      {error ? (
        <p className="text-sm text-destructive" role="alert">
          {error instanceof Error ? error.message : t('projects.collections.load_failed', 'Error en carregar')}
        </p>
      ) : null}

      {surface === 'notes' && isSalesHub && !isLoading && effectiveMode === 'table' ? (
        <SalesDataTable
          columns={
            [
              {
                id: 'doc_number',
                header: t('projects.collections.surface_notes', 'Albarans'),
                sortable: true,
                cell: (row) => (
                  <Link to={`/sales/delivery-notes/${row.id}`} className="font-semibold hover:underline">
                    {row.doc_number ?? row.id.slice(0, 8)}
                  </Link>
                ),
              },
              {
                id: 'issued_at',
                header: t('projects.collections.issued_on', 'Data'),
                sortable: true,
                cell: (row) =>
                  row.issued_at
                    ? new Date(row.issued_at).toLocaleDateString('ca-ES')
                    : '—',
              },
              {
                id: 'client',
                header: t('projects.quotes.client', 'Client'),
                cell: (row) =>
                  row.client_display_name || t('projects.quotes.unknown_client', 'Sense client'),
              },
              {
                id: 'project',
                header: t('projects.collections.open_order', 'OS'),
                cell: (row) => row.project_name || '—',
              },
              {
                id: 'billing',
                header: t('projects.sales.billing', 'Facturació'),
                cell: (row) => billingLabelForSalesRow(rowBillingStatus(row), t),
              },
              {
                id: 'collection',
                header: t('projects.sales.collection', 'Cobrament'),
                cell: (row) =>
                  row.collection_status === 'paid'
                    ? t('projects.sales.collection_paid', 'Cobrat')
                    : row.collection_status === 'partial'
                      ? t('projects.sales.collection_partial', 'Parcial')
                      : row.collection_status === 'rectified'
                        ? t('projects.collections.status_rectified', 'Rectificat')
                        : t('projects.sales.collection_pending', 'Pendent de cobrar'),
              },
              {
                id: 'total',
                header: t('projects.commercial.total', 'Total'),
                className: 'text-right tabular-nums',
                cell: (row) => `${moneyFmt.format(centsToEuros(row.total_cents))} €`,
              },
              {
                id: 'invoice',
                header: t('projects.sales.tab_invoices', 'Factura'),
                cell: (row) =>
                  row.external_invoice_id ? (
                    <Link
                      to={`/sales/invoices/${row.external_invoice_id}`}
                      className="hover:underline"
                    >
                      {rowBillingStatus(row) === 'draft_invoice'
                        ? t('projects.sales.billing_draft', 'En esborrany')
                        : (row.external_invoice_ref ?? row.external_invoice_id.slice(0, 8))}
                    </Link>
                  ) : (
                    (row.external_invoice_ref ?? '—')
                  ),
              },
            ] satisfies SalesDataTableColumn<DeliveryNoteListRow>[]
          }
          rows={items}
          getRowId={(row) => row.id}
          density={density}
          activeRowId={inspectId}
          onRowActivate={(row) => setInspectId(row.id)}
          selectedIds={selected}
          onToggleRow={toggleSelected}
          onToggleAll={(checked) =>
            setSelected(
              checked
                ? items
                    .filter((row) => isOffice && canSelectForInvoice(row, selectedClientId))
                    .map((row) => row.id)
                : [],
            )
          }
          canSelectRow={(row) => isOffice && canSelectForInvoice(row, selectedClientId)}
          countLabel={t('common:list.showing_count', 'Mostrant {{shown}} de {{total}}', {
            shown: items.length,
            total: totalCount,
          })}
          bulkBar={
            selectedRows.length > 0 && isOffice ? (
              <Button type="button" size="sm" onClick={openInvoiceModal}>
                {t('projects.sales.bulk_invoice', 'Facturar seleccionats')}
              </Button>
            ) : null
          }
          rowActions={(row) => {
            const active =
              row.collection_status !== 'rectified' && row.document_status !== 'cancelled'
            const canDnMoneyActions = canCollectOrRectifyDn(row)
            return [
              {
                key: 'open',
                label: t('common:list.open_record', 'Obrir fitxa'),
                onSelect: () => {
                  void navigate(`/sales/delivery-notes/${row.id}`)
                },
              },
              ...(active
                ? [
                    {
                      key: 'send',
                      label: t('projects.commercial.send', 'Enviar'),
                      onSelect: () => setShareDocId(row.id),
                    },
                  ]
                : []),
              ...(canDnMoneyActions && row.remaining_cents > 0
                ? [
                    {
                      key: 'collect',
                      label: t('projects.commercial.collect', 'Cobrar'),
                      onSelect: () => setCollectRow(row),
                    },
                  ]
                : []),
              ...(canDnMoneyActions && isOffice
                ? [
                    {
                      key: 'rectify',
                      label: t('projects.commercial.rectify', 'Rectificar'),
                      onSelect: () => setRectifyDocId(row.id),
                    },
                  ]
                : []),
              ...(row.external_invoice_id
                ? [
                    {
                      key: 'invoice',
                      label: t('projects.sales.open_invoice', 'Obrir factura'),
                      onSelect: () => {
                        void navigate(`/sales/invoices/${row.external_invoice_id}`)
                      },
                    },
                  ]
                : []),
            ]
          }}
          empty={
            <p className="rounded-xl border border-dashed border-border p-8 text-center text-sm text-muted-foreground">
              {t('projects.collections.empty', 'No hi ha albarans amb aquests filtres.')}
            </p>
          }
        />
      ) : null}

      {surface === 'notes' && isSalesHub && !isLoading && effectiveMode === 'cards' ? (
        items.length === 0 ? (
          <p className="rounded-xl border border-dashed border-border p-8 text-center text-sm text-muted-foreground">
            {t('projects.collections.empty', 'No hi ha albarans amb aquests filtres.')}
          </p>
        ) : (
          <ul className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            {items.map((row) => {
              const billing = rowBillingStatus(row)
              const tone =
                row.collection_status === 'paid'
                  ? 'paid'
                  : row.collection_status === 'partial'
                    ? 'partial'
                    : billing === 'rectified'
                      ? 'danger'
                      : billing === 'to_invoice'
                        ? 'pending'
                        : 'neutral'
              return (
                <li key={row.id}>
                  <SalesDocCard
                    title={row.doc_number ?? row.id.slice(0, 8)}
                    subtitle={
                      row.client_display_name ||
                      t('projects.quotes.unknown_client', 'Sense client')
                    }
                    amount={`${moneyFmt.format(centsToEuros(row.total_cents))} €`}
                    amountHint={
                      row.remaining_cents > 0
                        ? `${t('projects.collections.remaining', 'Pendent')} ${moneyFmt.format(centsToEuros(row.remaining_cents))} €`
                        : undefined
                    }
                    tone={tone}
                    active={inspectId === row.id}
                    onClick={() => setInspectId(row.id)}
                    badges={
                      <>
                        <Badge variant="outline">{billingLabelForSalesRow(billing, t)}</Badge>
                        <Badge
                          variant={row.collection_status === 'paid' ? 'default' : 'secondary'}
                        >
                          {row.collection_status === 'paid'
                            ? t('projects.sales.collection_paid', 'Cobrat')
                            : row.collection_status === 'partial'
                              ? t('projects.sales.collection_partial', 'Parcial')
                              : t('projects.sales.collection_pending', 'Pendent de cobrar')}
                        </Badge>
                      </>
                    }
                    meta={
                      <>
                        {row.project_name || '—'}
                        {row.issued_at
                          ? ` · ${new Date(row.issued_at).toLocaleDateString('ca-ES')}`
                          : null}
                      </>
                    }
                  />
                </li>
              )
            })}
          </ul>
        )
      ) : null}

      {surface === 'notes' && !isSalesHub && !isLoading && items.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('projects.collections.empty', 'No hi ha albarans amb aquests filtres.')}
        </p>
      ) : null}

      {surface === 'notes' && !isSalesHub && items.length > 0 ? (
        <ul className="space-y-3">
          {items.map((row) => {
            const invoiced = rowBillingStatus(row) !== 'to_invoice'
            const active = row.collection_status !== 'rectified' && row.document_status !== 'cancelled'
            const canSelect = isOffice && canSelectForInvoice(row, selectedClientId)
            const canDnMoneyActions = canCollectOrRectifyDn(row)
            return (
              <li key={row.id} className="space-y-3 rounded-2xl border border-border bg-card p-4">
                <div className="flex flex-wrap items-start justify-between gap-2">
                  <div className="min-w-0 space-y-1">
                    <div className="flex flex-wrap items-center gap-2">
                      {canSelect || selected.includes(row.id) ? (
                        <input
                          type="checkbox"
                          checked={selected.includes(row.id)}
                          onChange={() => toggleSelected(row)}
                          aria-label={row.doc_number ?? row.id}
                        />
                      ) : null}
                      <button
                        type="button"
                        className="font-semibold hover:underline"
                        onClick={() => setViewDocId(row.id)}
                      >
                        {row.doc_number ?? row.id.slice(0, 8)}
                      </button>
                      <Badge variant="outline">
                        {row.collection_status === 'paid'
                          ? t('projects.collections.status_paid', 'Cobrat')
                          : row.collection_status === 'partial'
                            ? t('projects.collections.status_partial', 'Parcial')
                            : row.collection_status === 'rectified'
                              ? t('projects.collections.status_rectified', 'Rectificat')
                              : t('projects.collections.status_pending', 'Pendent')}
                      </Badge>
                    </div>
                    <p className="text-sm text-muted-foreground">
                      {row.client_display_name || t('projects.quotes.unknown_client', 'Sense client')}
                      {row.project_name ? ` · ${row.project_name}` : ''}
                    </p>
                    {invoiced ? (
                      <p className="text-xs text-muted-foreground">
                        {t('projects.collections.included_in_invoice', 'Inclòs a la factura {{ref}}', {
                          ref: row.external_invoice_ref,
                        })}
                      </p>
                    ) : null}
                    {row.superseded_by_number ? (
                      <p className="text-xs text-amber-700 dark:text-amber-300">
                        {t('projects.collections.superseded_by', 'Substituït per {{number}}', {
                          number: row.superseded_by_number,
                        })}
                      </p>
                    ) : null}
                  </div>
                  <div className="text-right text-sm tabular-nums">
                    {invoiced ? (
                      <p className="text-xs text-muted-foreground">
                        {t('projects.collections.remaining_on_invoice', 'El pendent és a la factura')}
                      </p>
                    ) : (
                      <p>
                        {t('projects.collections.remaining', 'Pendent')}{' '}
                        <span className="font-semibold">
                          {moneyFmt.format(centsToEuros(row.remaining_cents))} €
                        </span>
                      </p>
                    )}
                    <p className="text-xs text-muted-foreground">
                      {moneyFmt.format(centsToEuros(row.total_cents))} €
                    </p>
                  </div>
                </div>
                <div className="flex flex-wrap gap-2">
                  <Button type="button" size="sm" variant="outline" onClick={() => setViewDocId(row.id)}>
                    {t('projects.commercial.view', 'Veure')}
                  </Button>
                  {active ? (
                    <Button type="button" size="sm" variant="outline" onClick={() => setShareDocId(row.id)}>
                      {t('projects.commercial.send', 'Enviar')}
                    </Button>
                  ) : null}
                  {active && row.document_status === 'issued' ? (
                    <Button type="button" size="sm" variant="outline" onClick={() => setSignDocId(row.id)}>
                      {t('projects.commercial.sign_delivery', 'Signar conformitat')}
                    </Button>
                  ) : null}
                  {canDnMoneyActions && row.remaining_cents > 0 ? (
                    <Button type="button" size="sm" onClick={() => setCollectRow(row)}>
                      {t('projects.commercial.collect', 'Cobrar')}
                    </Button>
                  ) : null}
                  {canDnMoneyActions && isOffice ? (
                    <Button
                      type="button"
                      size="sm"
                      variant="outline"
                      onClick={() => setRectifyDocId(row.id)}
                    >
                      {t('projects.commercial.rectify', 'Rectificar')}
                    </Button>
                  ) : null}
                  <Button
                    type="button"
                    size="sm"
                    variant="outline"
                    onClick={() => {
                      void listDocumentPayments(row.id).then((payments) => {
                        const target = payments[0]
                        if (target) setReceiptPaymentId(target.id)
                      })
                    }}
                  >
                    {t('projects.commercial.send_receipt', 'Enviar comprovant')}
                  </Button>
                  {row.project_id && !lockedProjectId ? (
                    <Button type="button" size="sm" variant="outline" asChild>
                      <Link to={commercialDocumentOrderPath(projectBase, row.project_id, 'delivery_note')}>
                        {t('projects.collections.open_order', 'Obrir OS')}
                      </Link>
                    </Button>
                  ) : null}
                </div>
              </li>
            )
          })}
        </ul>
      ) : null}

      {surface === 'invoices' && !isLoading && invoices.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('projects.collections.invoices_empty', 'No hi ha factures amb aquests filtres.')}
        </p>
      ) : null}
      {surface === 'invoices' && invoices.length > 0 ? (
        <ul className="space-y-3">
          {invoices.map((invoice) => (
            <li key={invoice.id} className="space-y-2 rounded-2xl border border-border bg-card p-4">
              <div className="flex flex-wrap items-start justify-between gap-2">
                <div>
                  <p className="font-semibold">{invoice.invoice_number}</p>
                  <p className="text-sm text-muted-foreground">
                    {invoice.client_display_name} · {(invoice.delivery_numbers ?? []).join(', ') || '—'}
                  </p>
                  {invoice.difference_cents !== 0 ? (
                    <p className="text-xs text-amber-700 dark:text-amber-300">
                      {t('projects.collections.invoice_difference_line', 'Diferència {{amount}} €', {
                        amount: moneyFmt.format(centsToEuros(invoice.difference_cents)),
                      })}
                    </p>
                  ) : null}
                </div>
                <div className="text-right text-sm tabular-nums">
                  <p>
                    {t('projects.collections.remaining', 'Pendent')}{' '}
                    <span className="font-semibold">
                      {moneyFmt.format(centsToEuros(invoice.remaining_cents))} €
                    </span>
                  </p>
                  <p className="text-xs text-muted-foreground">
                    {moneyFmt.format(centsToEuros(invoice.total_cents))} €
                  </p>
                </div>
              </div>
              {invoice.remaining_cents > 0 && isOffice ? (
                <Button
                  type="button"
                  size="sm"
                  onClick={() => {
                    setPayInvoice(invoice)
                    setPayAmount((invoice.remaining_cents / 100).toFixed(2))
                    setPayReference('')
                  }}
                >
                  {t('projects.collections.collect_invoice', 'Cobrar factura')}
                </Button>
              ) : null}
            </li>
          ))}
        </ul>
      ) : null}

      {useSalesList && (cursorPage > 0 || salesHasMore) ? (
        <div className="flex items-center justify-between gap-2">
          <Button
            type="button"
            variant="outline"
            size="sm"
            disabled={cursorPage <= 0}
            onClick={goPrevSalesPage}
          >
            {t('common.prev', 'Anterior')}
          </Button>
          <span className="text-xs text-muted-foreground">
            {t('projects.sales.rows_count', '{{count}} files', { count: totalCount })}
            {' · '}
            {cursorPage + 1}
            {salesHasMore ? '+' : ''}
          </span>
          <Button
            type="button"
            variant="outline"
            size="sm"
            disabled={!salesHasMore}
            onClick={goNextSalesPage}
          >
            {t('common.next', 'Següent')}
          </Button>
        </div>
      ) : null}
      {!useSalesList && totalPages > 1 ? (
        <div className="flex items-center justify-between gap-2">
          <Button type="button" variant="outline" size="sm" disabled={page <= 1} onClick={() => updateParam('page', String(page - 1))}>
            {t('common.prev', 'Anterior')}
          </Button>
          <span className="text-xs text-muted-foreground">{page} / {totalPages}</span>
          <Button type="button" variant="outline" size="sm" disabled={page >= totalPages} onClick={() => updateParam('page', String(page + 1))}>
            {t('common.next', 'Següent')}
          </Button>
        </div>
      ) : null}
    </>
  )

  const dialogs = (
    <>
      {collectRow ? (
        <CollectPaymentDialog
          open
          documentId={collectRow.id}
          documentNumber={collectRow.doc_number}
          remainingCents={collectRow.remaining_cents}
          previousPayments={collectPayments}
          advancePaidCents={collectRow.advance_applied_cents}
          onClose={() => setCollectRow(null)}
          onCollected={(paymentId) => {
            setCollectRow(null)
            setReceiptPaymentId(paymentId)
            invalidate()
          }}
        />
      ) : null}
      {viewDocId ? (
        <CommercialDocumentView
          documentId={viewDocId}
          open
          onClose={() => setViewDocId(null)}
          onChanged={invalidate}
          onShare={() => setShareDocId(viewDocId)}
        />
      ) : null}
      {shareDocId ? (
        <CommercialDocumentShareSheet documentId={shareDocId} open onClose={() => setShareDocId(null)} />
      ) : null}
      {signDocId ? (
        <CommercialNativeSignDialog
          documentId={signDocId}
          action="delivery"
          open
          onClose={() => setSignDocId(null)}
          onCompleted={invalidate}
        />
      ) : null}
      {receiptPaymentId ? (
        <PaymentReceiptSheet paymentId={receiptPaymentId} open onClose={() => setReceiptPaymentId(null)} />
      ) : null}

      <RectifyDeliveryNoteDialog
        documentId={rectifyDocId}
        open={rectifyDocId !== null}
        busy={busy}
        onBusyChange={setBusy}
        onClose={() => setRectifyDocId(null)}
        onCompleted={invalidate}
      />

      <Dialog
        open={invoiceOpen}
        onOpenChange={(open) => {
          if (busy) return
          if (open) openInvoiceModal()
          else closeInvoiceModal()
        }}
      >
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>{t('projects.collections.register_invoice', 'Emmetre factura')}</DialogTitle>
            <DialogDescription>
              {t(
                'projects.sales.issue_invoice_help',
                'PiMed assigna el número de sèrie. La factura fiscal (Verifactu) queda fora d’aquest pas.',
              )}
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-3">
            <div className="space-y-1.5">
              <Label htmlFor="sales-invoice-preview">
                {t('projects.sales.next_number_preview', 'Pròxim número (orientatiu)')}
              </Label>
              <Input
                id="sales-invoice-preview"
                value={invoiceNumberPreview || '…'}
                readOnly
                className="bg-muted"
              />
              <p className="text-xs text-muted-foreground">
                {t(
                  'projects.sales.next_number_preview_help',
                  'No reserva el número. S’assigna en emetre.',
                )}
              </p>
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="sales-erp-ref">
                {t('projects.sales.erp_reference_label', 'Ref. ERP (opcional)')}
              </Label>
              <Input
                id="sales-erp-ref"
                value={erpReference}
                onChange={(event) => setErpReference(event.target.value)}
                placeholder="F-HOLD-014"
                autoComplete="off"
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="sales-invoice-date">
                {t('projects.collections.invoice_date_label', 'Data d’emissió')}
              </Label>
              <Input
                id="sales-invoice-date"
                type="date"
                value={invoiceDate}
                onChange={(event) => {
                  const next = event.target.value
                  setInvoiceDate(next)
                  void previewNextDocumentNumber({ docType: 'invoice', issuedOn: next })
                    .then((n) => setInvoiceNumberPreview(n))
                    .catch(() => setInvoiceNumberPreview(''))
                }}
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="sales-invoice-total">
                {t('projects.collections.invoice_total_label', 'Total (suma dels albarans)')}
              </Label>
              <Input
                id="sales-invoice-total"
                inputMode="decimal"
                value={invoiceTotal}
                readOnly
                className="bg-muted"
              />
              <p className="text-xs text-muted-foreground">
                {t(
                  'projects.collections.invoice_total_help',
                  'Import total dels albarans seleccionats. No es pot editar en aquest pas.',
                )}
              </p>
            </div>
          </div>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={closeInvoiceModal}>
              {t('common.cancel', 'Cancel·lar')}
            </Button>
            <Button
              type="button"
              disabled={busy || typedInvoiceCents < 0 || selectedRows.length === 0}
              onClick={() => void submitInvoice()}
            >
              {t('projects.sales.issue_invoice', 'Emmetre')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog
        open={payInvoice !== null}
        onOpenChange={(open) => {
          if (busy) return
          if (!open) {
            setPayInvoice(null)
            resetPayOpId()
          }
        }}
      >
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>
              {t('projects.collections.collect_invoice', 'Cobrar factura')} {payInvoice?.invoice_number}
            </DialogTitle>
          </DialogHeader>
          <Input inputMode="decimal" value={payAmount} onChange={(event) => setPayAmount(event.target.value)} />
          <select className="h-10 rounded-md border border-input bg-background px-3 text-sm" value={payMethod} onChange={(event) => setPayMethod(event.target.value)}>
            <option value="transfer">{t('projects.commercial.method_transfer', 'Transferència')}</option>
            <option value="card">{t('projects.commercial.method_card', 'Targeta')}</option>
            <option value="cash">{t('projects.commercial.method_cash', 'Efectiu')}</option>
            <option value="bizum">Bizum</option>
          </select>
          <Input value={payReference} onChange={(event) => setPayReference(event.target.value)} placeholder={t('projects.collections.payment_reference', 'Referència')} />
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={() => {
                setPayInvoice(null)
                resetPayOpId()
              }}
            >
              {t('common.cancel', 'Cancel·lar')}
            </Button>
            <Button type="button" disabled={busy} onClick={() => void submitInvoicePayment()}>
              {t('projects.commercial.collect', 'Cobrar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  )

  if (!embedded && isSalesHub && viewParam) {
    return <Navigate to={`/sales/delivery-notes/${viewParam}`} replace />
  }

  if (useSalesList) {
    return (
      <>
        <PageShell
          bare
          toolbar={filtersBlock}
          inspector={salesInspector}
          inspectorOpen={Boolean(inspectId)}
          onInspectorClose={() => setInspectId(null)}
        >
          <div className="space-y-3">{listBody}</div>
        </PageShell>
        {dialogs}
      </>
    )
  }

  return (
    <div
      className={
        embedded ? 'space-y-3' : 'mx-auto max-w-5xl space-y-5 px-4 py-6'
      }
    >
      {listBody}
      {dialogs}
    </div>
  )
}
