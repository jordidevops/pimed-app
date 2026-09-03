import { useTranslation } from 'react-i18next'
import { AlertTriangle, Clock, UserX } from 'lucide-react'
import { cn } from '@/lib/utils'
import type { PlannerDiscrepancyType } from '../../api/schedulePlannerFilters'

const CONFIG: Record<
  PlannerDiscrepancyType,
  { icon: typeof AlertTriangle; className: string; labelKey: string; fallback: string }
> = {
  missing_punch: {
    icon: UserX,
    className: 'bg-red-100 text-red-800 border-red-300',
    labelKey: 'schedule_planner.disc_missing_punch',
    fallback: 'Sense fitxatge',
  },
  unexpected_work: {
    icon: AlertTriangle,
    className: 'bg-amber-100 text-amber-900 border-amber-300',
    labelKey: 'schedule_planner.disc_unexpected_work',
    fallback: 'Treball inesperat',
  },
  hours_mismatch: {
    icon: Clock,
    className: 'bg-orange-100 text-orange-900 border-orange-300',
    labelKey: 'schedule_planner.disc_hours_mismatch',
    fallback: 'Hores diferents',
  },
}

interface ScheduleDiscrepancyBadgeProps {
  type: PlannerDiscrepancyType
  compact?: boolean
  className?: string
}

export function ScheduleDiscrepancyBadge({ type, compact, className }: ScheduleDiscrepancyBadgeProps) {
  const { t } = useTranslation('attendance')
  const cfg = CONFIG[type]
  const Icon = cfg.icon

  return (
    <span
      className={cn(
        'inline-flex items-center gap-0.5 rounded border px-1 py-0.5 text-[9px] font-medium leading-none',
        cfg.className,
        className,
      )}
      title={t(cfg.labelKey, cfg.fallback)}
    >
      <Icon className="h-2.5 w-2.5 shrink-0" aria-hidden />
      {!compact && <span>{t(cfg.labelKey, cfg.fallback)}</span>}
    </span>
  )
}

export function DiscrepancyLegend() {
  const { t } = useTranslation('attendance')
  const types: PlannerDiscrepancyType[] = ['missing_punch', 'unexpected_work', 'hours_mismatch']

  return (
    <div className="flex flex-wrap items-center gap-x-4 gap-y-2 text-xs text-muted-foreground">
      <span className="font-medium text-foreground">
        {t('schedule_planner.disc_legend_title', 'Discrepàncies')}:
      </span>
      {types.map((type) => (
        <ScheduleDiscrepancyBadge key={type} type={type} />
      ))}
    </div>
  )
}
