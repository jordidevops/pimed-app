import { Badge } from '@/components/ui/badge'
import {
  Ban,
  CheckCircle2,
  CircleDashed,
  Clock3,
  FilePenLine,
  Hourglass,
  PenLine,
  XCircle,
  type LucideIcon,
} from 'lucide-react'
import { cn } from '@/lib/utils'
import type { CommercialDocument } from '../api/commercialFlowService'
import {
  effectiveCommercialDocumentStatus,
  pendingCommercialAction,
} from '../utils/pendingCommercialAction'

export type CommercialStatusTone =
  | 'success'
  | 'danger'
  | 'warning'
  | 'info'
  | 'muted'
  | 'pending'

export type CommercialStatusPresentation = {
  key: string
  labelKey: string
  labelFallback: string
  tone: CommercialStatusTone
  Icon: LucideIcon
}

const TONE_CLASS: Record<CommercialStatusTone, string> = {
  success:
    'border-emerald-500/40 bg-emerald-50 text-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-200',
  danger:
    'border-red-500/40 bg-red-50 text-red-800 dark:bg-red-950/40 dark:text-red-200',
  warning:
    'border-amber-500/40 bg-amber-50 text-amber-900 dark:bg-amber-950/40 dark:text-amber-100',
  pending:
    'border-amber-500/40 bg-amber-50 text-amber-900 dark:bg-amber-950/40 dark:text-amber-100',
  info:
    'border-sky-500/40 bg-sky-50 text-sky-900 dark:bg-sky-950/40 dark:text-sky-100',
  muted:
    'border-border bg-muted/60 text-muted-foreground',
}

function statusPresentation(
  status: string,
  docType: CommercialDocument['doc_type'],
): CommercialStatusPresentation {
  switch (status) {
    case 'accepted':
      return {
        key: 'accepted',
        labelKey: 'projects.commercial.status_accepted',
        labelFallback: 'Acceptat',
        tone: 'success',
        Icon: CheckCircle2,
      }
    case 'signed':
      return {
        key: 'signed',
        labelKey: 'projects.commercial.status_signed',
        labelFallback: 'Signat',
        tone: 'info',
        Icon: PenLine,
      }
    case 'rejected':
      return {
        key: 'rejected',
        labelKey: 'projects.commercial.status_rejected',
        labelFallback: 'Refusat',
        tone: 'danger',
        Icon: XCircle,
      }
    case 'expired':
      return {
        key: 'expired',
        labelKey: 'projects.commercial.status_expired',
        labelFallback: 'Caducat',
        tone: 'warning',
        Icon: Clock3,
      }
    case 'cancelled':
      return {
        key: 'cancelled',
        labelKey: 'projects.commercial.status_cancelled',
        labelFallback: 'Anul·lat',
        tone: 'muted',
        Icon: Ban,
      }
    case 'draft':
      return {
        key: 'draft',
        labelKey: 'projects.commercial.status_draft',
        labelFallback: 'Esborrany',
        tone: 'muted',
        Icon: FilePenLine,
      }
    case 'issued':
      if (docType === 'delivery_note') {
        return {
          key: 'issued_delivery',
          labelKey: 'projects.commercial.status_issued_delivery',
          labelFallback: 'Emès',
          tone: 'info',
          Icon: CircleDashed,
        }
      }
      if (docType === 'quote_amendment') {
        return {
          key: 'pending_approval',
          labelKey: 'projects.commercial.status_pending_approval',
          labelFallback: 'Pendent d’aprovació',
          tone: 'pending',
          Icon: Hourglass,
        }
      }
      return {
        key: 'issued',
        labelKey: 'projects.commercial.status_issued',
        labelFallback: 'Pendent de resposta',
        tone: 'pending',
        Icon: Hourglass,
      }
    default:
      return {
        key: status,
        labelKey: `projects.commercial.status_${status}`,
        labelFallback: status,
        tone: 'muted',
        Icon: CircleDashed,
      }
  }
}

/**
 * One primary status badge; optional payment-pending chip only when it adds new info
 * (avoids duplicate «Pendent de resposta» on /quotes).
 */
export function resolveCommercialDocumentBadges(
  doc: Pick<
    CommercialDocument,
    'doc_type' | 'status' | 'valid_until' | 'total'
  >,
  paidCents?: number,
): CommercialStatusPresentation[] {
  const status = effectiveCommercialDocumentStatus(doc)
  const pending = pendingCommercialAction(
    doc as CommercialDocument,
    paidCents,
  )
  const primary = statusPresentation(status, doc.doc_type)

  if (pending?.kind === 'awaiting_payment') {
    return [
      primary,
      {
        key: 'awaiting_payment',
        labelKey: 'projects.commercial.payment_pending_chip',
        labelFallback: 'Pendent de cobrar',
        tone: 'warning',
        Icon: Clock3,
      },
    ]
  }

  // awaiting_response / awaiting_approval are already encoded in the issued status label
  return [primary]
}

interface CommercialDocumentStatusBadgesProps {
  doc: Pick<
    CommercialDocument,
    'doc_type' | 'status' | 'valid_until' | 'total'
  >
  paidCents?: number
  t: (key: string, fallback: string) => string
  className?: string
}

export function CommercialDocumentStatusBadges({
  doc,
  paidCents,
  t,
  className,
}: CommercialDocumentStatusBadgesProps) {
  const badges = resolveCommercialDocumentBadges(doc, paidCents)
  return (
    <span className={cn('inline-flex flex-wrap items-center gap-1.5', className)}>
      {badges.map((badge) => (
        <Badge
          key={badge.key}
          variant="outline"
          className={cn('gap-1 font-medium', TONE_CLASS[badge.tone])}
        >
          <badge.Icon className="h-3.5 w-3.5 shrink-0" aria-hidden />
          {t(badge.labelKey, badge.labelFallback)}
        </Badge>
      ))}
    </span>
  )
}
