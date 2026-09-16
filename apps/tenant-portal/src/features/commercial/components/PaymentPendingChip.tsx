import { Badge } from '@/components/ui/badge'
import { useTranslation } from 'react-i18next'

interface PaymentPendingChipProps {
  pending: boolean
  className?: string
}

export function PaymentPendingChip({ pending, className }: PaymentPendingChipProps) {
  const { t } = useTranslation('projects')
  if (!pending) return null
  return (
    <Badge
      variant="outline"
      className={`border-amber-400 bg-amber-50 text-amber-800 dark:border-amber-600 dark:bg-amber-950/40 dark:text-amber-200 text-xs ${className ?? ''}`}
    >
      {t('projects.commercial.payment_pending_chip', 'Pendent de cobrar')}
    </Badge>
  )
}
