import { useTranslation } from 'react-i18next'
import { Eye, MapPin } from 'lucide-react'
import { Button } from '@/components/ui/button'

interface RecordsListActionsProps {
  punchCount: number
  onOpenPunches: () => void
  onOpenDay: () => void
}

export function RecordsListActions({
  punchCount,
  onOpenPunches,
  onOpenDay,
}: RecordsListActionsProps) {
  const { t } = useTranslation('attendance')

  return (
    <div
      className="flex items-center justify-end gap-0.5"
      onClick={(e) => e.stopPropagation()}
      onKeyDown={(e) => e.stopPropagation()}
    >
      {punchCount > 0 && (
        <Button
          type="button"
          variant="ghost"
          size="icon"
          className="h-8 w-8 text-primary hover:text-primary"
          title={t('punch_details.open', 'Veure fitxatges')}
          onClick={onOpenPunches}
        >
          <MapPin className="h-4 w-4" />
        </Button>
      )}
      <Button
        type="button"
        variant="ghost"
        size="icon"
        className="h-8 w-8"
        title={t('payroll_review.row_detail', 'Veure detall del dia')}
        onClick={onOpenDay}
      >
        <Eye className="h-4 w-4" />
      </Button>
    </div>
  )
}
