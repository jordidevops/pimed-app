import { Badge } from '@/components/ui/badge'
import { useTranslation } from 'react-i18next'

interface PaymentPendingChipProps {
  pending: boolean
  /** Remaining is on an external invoice (field cannot collect). */
  pendingOnInvoice?: boolean
  className?: string
}

export function PaymentPendingChip({
  pending,
  pendingOnInvoice = false,
  className,
}: PaymentPendingChipProps) {
  const { t } = useTranslation('projects')
  if (!pending) return null
  return (
    <Badge
      variant="outline"
      className={`border-amber-400 bg-amber-50 text-amber-800 dark:border-amber-600 dark:bg-amber-950/40 dark:text-amber-200 text-xs ${className ?? ''}`}
    >
      {pendingOnInvoice
        ? t('projects.collections.pending_on_invoice_office', 'Pendent a factura — oficina')
        : t('projects.commercial.payment_pending_chip', 'Pendent de cobrar')}
    </Badge>
  )
}
