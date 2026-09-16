import type {
  CommercialDocument,
  CommercialPayment,
} from '../../commercial/api/commercialFlowService'
import { allocatedPaidCents } from '../../commercial/utils/paymentAllocation'

export type OrderPhaseTab = 'prepare' | 'do' | 'deliver'

export type OrderPrimaryAction =
  | 'show_quote'
  | 'create_quote'
  | 'start_work'
  | 'resume_work'
  | 'review_close'
  | 'show_delivery'
  | 'collect'
  | 'send_receipt'
  | 'sync_pending'
  | 'review_sync_error'
  | 'done'

export type OperationalState =
  | 'not_started'
  | 'running'
  | 'paused'
  | 'closed'
  | 'cancelled'

export type AuthorizationState =
  | 'missing'
  | 'pending'
  | 'authorized'
  | 'rejected'
  | 'expired'
  | 'inconsistent'

export type DeliveryState =
  | 'not_started'
  | 'delivery_pending'
  | 'payment_pending'
  | 'paid'

export type ReportState = 'not_published' | 'published'
export type OrderLocalCloseState =
  | 'none'
  | 'local_pending'
  | 'action_required'
  | 'synced'

export type WorkflowAnomaly =
  | 'advanced_without_authorization'
  | 'draft_with_recorded_work'
  | 'completed_without_delivery'

export type OrderWorkflow = {
  operationalState: OperationalState
  authorizationState: AuthorizationState
  reportState: ReportState
  deliveryState: DeliveryState
  suggestedTab: OrderPhaseTab
  primaryAction: OrderPrimaryAction
  prepareDone: boolean
  doDone: boolean
  deliverDone: boolean
  authorized: boolean
  visitClosed: boolean
  visitClosedUi: boolean
  localCloseState: OrderLocalCloseState
  hasDelivery: boolean
  paymentPending: boolean
  remainingCents: number
  paidCents: number
  deliveryTotalCents: number
  activeQuoteId: string | null
  reissueFromQuoteId: string | null
  latestDeliveryId: string | null
  latestPaymentId: string | null
  anomalies: WorkflowAnomaly[]
}

function newestFirst<T extends { created_at: string }>(rows: T[]): T[] {
  return [...rows].sort(
    (a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime(),
  )
}

function quoteIsEffectivelyExpired(
  document: CommercialDocument,
  nowMs: number,
): boolean {
  if (document.status === 'expired') return true
  return (
    document.status === 'issued' &&
    !!document.valid_until &&
    new Date(document.valid_until).getTime() < nowMs
  )
}

export function commercialDocumentStatus(
  document: CommercialDocument,
  nowMs = Date.now(),
): string {
  return quoteIsEffectivelyExpired(document, nowMs) ? 'expired' : document.status
}

export function deriveOrderWorkflow(input: {
  status: string | null | undefined
  visitClosed: boolean
  localCloseState?: OrderLocalCloseState
  reportPublished: boolean
  documents: CommercialDocument[]
  payments: CommercialPayment[]
  hasWaiver: boolean
  totalWorkSeconds: number
  hasOpenWorkLog: boolean
  receiptHandled?: boolean
  nowMs?: number
}): OrderWorkflow {
  const nowMs = input.nowMs ?? Date.now()
  const localCloseState = input.localCloseState ?? 'none'
  const visitClosedUi =
    input.visitClosed ||
    localCloseState === 'local_pending' ||
    localCloseState === 'action_required' ||
    localCloseState === 'synced'
  const documents = newestFirst(input.documents)
  const baseQuotes = documents.filter((document) => document.doc_type === 'quote')
  const activeQuote =
    baseQuotes.find(
      (document) =>
        document.status === 'issued' &&
        !quoteIsEffectivelyExpired(document, nowMs),
    ) ?? null
  const acceptedQuote =
    baseQuotes.find(
      (document) =>
        document.status === 'accepted' || document.status === 'signed',
    ) ?? null
  const latestQuote = baseQuotes[0] ?? null
  const latestQuoteStatus = latestQuote
    ? commercialDocumentStatus(latestQuote, nowMs)
    : null
  const reissueFromQuote =
    latestQuote &&
    (latestQuoteStatus === 'rejected' ||
      latestQuoteStatus === 'expired' ||
      latestQuoteStatus === 'cancelled')
      ? latestQuote
      : null

  const deliveries = documents.filter(
    (document) => document.doc_type === 'delivery_note',
  )
  const latestDelivery = deliveries[0] ?? null
  const paidCents = latestDelivery
    ? allocatedPaidCents(latestDelivery, documents, input.payments)
    : 0
  const deliveryTotalCents = latestDelivery
    ? Math.round(Number(latestDelivery.total) * 100)
    : 0
  const remainingCents = Math.max(0, deliveryTotalCents - paidCents)
  const deliveryIssued =
    !!latestDelivery &&
    (latestDelivery.status === 'issued' ||
      latestDelivery.status === 'signed' ||
      latestDelivery.status === 'accepted')
  const paymentPending = deliveryIssued && remainingCents > 0
  const fullyPaid =
    deliveryIssued &&
    (deliveryTotalCents === 0 || paidCents >= deliveryTotalCents)
  const latestPayment =
    (latestDelivery
      ? input.payments.filter((payment) => payment.document_id === latestDelivery.id)
      : [])[0] ?? null

  const hasRecordedWork =
    input.totalWorkSeconds > 0 || input.hasOpenWorkLog
  const operationalState: OperationalState =
    input.status === 'cancelled'
      ? 'cancelled'
      : visitClosedUi
        ? 'closed'
        : input.hasOpenWorkLog
          ? 'running'
          : hasRecordedWork
            ? 'paused'
            : 'not_started'

  const authorized = input.hasWaiver || !!acceptedQuote
  const workflowAdvanced =
    hasRecordedWork ||
    visitClosedUi ||
    input.reportPublished ||
    !!latestDelivery ||
    input.payments.length > 0

  let authorizationState: AuthorizationState
  if (authorized) authorizationState = 'authorized'
  else if (workflowAdvanced) {
    authorizationState = 'inconsistent'
  } else if (activeQuote) authorizationState = 'pending'
  else if (latestQuoteStatus === 'rejected') authorizationState = 'rejected'
  else if (latestQuoteStatus === 'expired') authorizationState = 'expired'
  else authorizationState = 'missing'

  let deliveryState: DeliveryState
  if (fullyPaid) deliveryState = 'paid'
  else if (paymentPending) deliveryState = 'payment_pending'
  else if (input.visitClosed && !latestDelivery) deliveryState = 'delivery_pending'
  else deliveryState = 'not_started'

  // Real progress determines the suggested phase. Missing historical data can
  // warn, but never sends delivered work backwards.
  const suggestedTab: OrderPhaseTab =
    visitClosedUi || input.reportPublished || !!latestDelivery
      ? 'deliver'
      : hasRecordedWork || authorized
        ? 'do'
        : 'prepare'

  let primaryAction: OrderPrimaryAction
  if (operationalState === 'cancelled') {
    primaryAction = 'done'
  } else if (localCloseState === 'local_pending' && !input.visitClosed) {
    primaryAction = 'sync_pending'
  } else if (localCloseState === 'action_required' && !input.visitClosed) {
    primaryAction = 'review_sync_error'
  } else if (latestDelivery) {
    if (paymentPending) primaryAction = 'collect'
    else if (fullyPaid && latestPayment && !input.receiptHandled) {
      primaryAction = 'send_receipt'
    } else primaryAction = 'done'
  } else if (input.visitClosed || localCloseState === 'synced') {
    if (activeQuote) primaryAction = 'show_quote'
    else if (!authorized && reissueFromQuote) primaryAction = 'create_quote'
    else if (!authorized) primaryAction = 'show_quote'
    else primaryAction = 'show_delivery'
  } else if (operationalState === 'paused') {
    primaryAction = 'resume_work'
  } else if (operationalState === 'running') {
    primaryAction = 'review_close'
  } else if (!authorized) {
    if (activeQuote) primaryAction = 'show_quote'
    else if (reissueFromQuote) primaryAction = 'create_quote'
    else primaryAction = 'show_quote'
  } else if (operationalState === 'not_started') {
    primaryAction = 'start_work'
  } else {
    primaryAction = 'review_close'
  }

  const anomalies: WorkflowAnomaly[] = []
  if (!authorized && workflowAdvanced) {
    anomalies.push('advanced_without_authorization')
  }
  if (input.status === 'draft' && hasRecordedWork) {
    anomalies.push('draft_with_recorded_work')
  }
  if (input.status === 'completed' && !latestDelivery) {
    anomalies.push('completed_without_delivery')
  }

  return {
    operationalState,
    authorizationState,
    reportState: input.reportPublished ? 'published' : 'not_published',
    deliveryState,
    suggestedTab,
    primaryAction,
    prepareDone: authorized,
    doDone: visitClosedUi,
    deliverDone: fullyPaid,
    authorized,
    visitClosed: input.visitClosed,
    visitClosedUi,
    localCloseState,
    hasDelivery: !!latestDelivery,
    paymentPending,
    remainingCents,
    paidCents,
    deliveryTotalCents,
    activeQuoteId: activeQuote?.id ?? null,
    reissueFromQuoteId: reissueFromQuote?.id ?? null,
    latestDeliveryId: latestDelivery?.id ?? null,
    latestPaymentId: latestPayment?.id ?? null,
    anomalies,
  }
}

export function resolveOrderTab(
  tabParam: string | null,
  fallback: OrderPhaseTab | 'activity',
): OrderPhaseTab | 'activity' {
  switch (tabParam) {
    case 'prepare':
    case 'budget':
      return 'prepare'
    case 'do':
    case 'work':
    case 'punch':
      return 'do'
    case 'deliver':
    case 'bulletin':
      return 'deliver'
    case 'activity':
      return 'activity'
    default:
      return fallback
  }
}

export function tabToSearchParam(
  tab: OrderPhaseTab | 'activity',
): OrderPhaseTab | 'activity' {
  return tab
}
