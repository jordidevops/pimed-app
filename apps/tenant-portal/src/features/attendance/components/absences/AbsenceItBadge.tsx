import { useTranslation } from 'react-i18next'
import { Link } from 'react-router-dom'
import { Badge } from '@/components/ui/badge'
import { cn } from '@/lib/utils'
import type { AbsenceTypeConfig } from '../../api/shiftsService'
import { absenceTypeLabel } from './absenceUiUtils'

interface AbsenceItBadgeProps {
  isIt: boolean
  absenceType: string | null | undefined
  typeConfigMap: Record<string, AbsenceTypeConfig>
  className?: string
  size?: 'xs' | 'sm'
  href?: string
}

export function AbsenceItBadge({
  isIt,
  absenceType,
  typeConfigMap,
  className,
  size = 'sm',
  href,
}: AbsenceItBadgeProps) {
  const { t, i18n } = useTranslation('attendance')
  const lang = i18n.language?.slice(0, 2) ?? 'ca'
  const cfg = absenceType ? typeConfigMap[absenceType] : undefined
  const typeLabel = absenceTypeLabel(cfg, absenceType ?? '', lang)
  const prefix = isIt
    ? t('timesheet.it_short', 'IT')
    : t('payroll_review.absence_badge', 'Absència')
  const text = cfg ? `${prefix}: ${typeLabel}` : prefix

  const badge = (
    <Badge
      variant="outline"
      className={cn(
        size === 'xs' ? 'text-[9px]' : 'text-xs',
        isIt ? 'border-violet-300 text-violet-800' : 'border-sky-300 text-sky-800',
        href && 'transition-colors hover:bg-accent',
        className,
      )}
    >
      {text}
    </Badge>
  )

  if (href) {
    return (
      <Link to={href} className="inline-flex">
        {badge}
      </Link>
    )
  }

  return badge
}
