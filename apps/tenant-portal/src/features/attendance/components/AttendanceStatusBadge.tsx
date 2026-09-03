import { useTranslation } from 'react-i18next'
import type { CurrentPunchStatus } from '../utils/punchProfileUi'
import { Badge } from '@/components/ui/badge'

interface AttendanceStatusBadgeProps {
  status: CurrentPunchStatus
  activePauseType?: string | null
  isRemote?: boolean
  className?: string
}

const statusConfig: Record<
  CurrentPunchStatus,
  { variant: 'default' | 'secondary' | 'outline' | 'destructive'; pulse?: boolean }
> = {
  working: { variant: 'default', pulse: true },
  on_pause: { variant: 'secondary', pulse: true },
  on_day: { variant: 'outline', pulse: true },
  traveling: { variant: 'secondary', pulse: true },
  outside: { variant: 'outline' },
  unknown: { variant: 'outline' },
}

export function AttendanceStatusBadge({
  status,
  activePauseType,
  isRemote,
  className = '',
}: AttendanceStatusBadgeProps) {
  const { t } = useTranslation('attendance')
  const cfg = statusConfig[status]

  const label =
    status === 'working'
      ? isRemote
        ? t('punch.status_remote', 'Teletreball')
        : t('punch.status_working', 'Treballant')
      : status === 'on_pause'
        ? t('punch.status_pause', 'En pausa') +
          (activePauseType ? ` (${activePauseType})` : '')
        : status === 'on_day'
          ? t('punch.status_on_day', 'Jornada oberta')
          : status === 'traveling'
            ? t('punch.status_traveling', 'En desplaçament')
            : status === 'outside'
              ? t('punch.status_out', 'Fora')
              : t('punch.status_unknown', 'Desconegut')

  return (
    <Badge variant={cfg.variant} className={`gap-1.5 px-3 py-1 text-sm ${className}`}>
      {cfg.pulse && (
        <span className="relative flex h-2 w-2">
          <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-current opacity-50" />
          <span className="relative inline-flex h-2 w-2 rounded-full bg-current" />
        </span>
      )}
      {label}
    </Badge>
  )
}
