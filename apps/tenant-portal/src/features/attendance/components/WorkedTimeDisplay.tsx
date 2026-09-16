import { useTranslation } from 'react-i18next'
import type { CurrentPunchStatus } from '../utils/punchProfileUi'
import { formatWorkedCounter, liveWorkedMs, type WorkedPunchLike } from '../utils/liveWorkedTime'
import { cn } from '@/lib/utils'

interface WorkedTimeDisplayProps {
  punches: WorkedPunchLike[]
  status: CurrentPunchStatus
  nowMs: number
  size?: 'compact' | 'hero'
  align?: 'start' | 'end' | 'center'
}

export function WorkedTimeDisplay({
  punches,
  status,
  nowMs,
  size = 'compact',
  align = 'end',
}: WorkedTimeDisplayProps) {
  const { t } = useTranslation('attendance')
  const running = status === 'working'
  const paused = status === 'on_pause'
  const traveling = status === 'traveling'
  const ms = liveWorkedMs(punches, nowMs)
  const label = running
    ? t('punch.status_working', 'Treballant')
    : paused
      ? t('punch.status_pause', 'En pausa')
      : traveling
        ? t('punch.status_traveling', 'En desplaçament')
        : t('punch.worked', 'Treballat')
  const tone = running
    ? 'text-emerald-600 dark:text-emerald-400'
    : paused
      ? 'text-amber-600 dark:text-amber-400'
      : traveling
        ? 'text-violet-600 dark:text-violet-400'
        : 'text-muted-foreground'

  return (
    <div
      className={cn(
        tone,
        align === 'center' && 'text-center',
        align === 'start' && 'text-left',
        align === 'end' && 'text-right',
      )}
      aria-live="polite"
    >
      <div
        className={cn(
          'flex items-center gap-1.5 font-mono font-bold tabular-nums leading-none',
          size === 'hero' ? 'text-3xl tracking-tight sm:text-4xl' : 'text-xl',
          align === 'center' && 'justify-center',
          align === 'end' && 'justify-end',
        )}
      >
        {running && (
          <span className="relative flex h-2 w-2 shrink-0" aria-hidden>
            <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-current opacity-60" />
            <span className="relative inline-flex h-2 w-2 rounded-full bg-current" />
          </span>
        )}
        {paused && (
          <span className="relative flex h-2 w-2 shrink-0" aria-hidden>
            <span className="relative inline-flex h-2 w-2 rounded-full bg-current" />
          </span>
        )}
        {formatWorkedCounter(ms, running)}
      </div>
      <p
        className={cn(
          'mt-1 font-semibold',
          size === 'hero' ? 'text-sm' : 'text-xs',
          running && 'animate-pulse',
        )}
      >
        {label}
      </p>
    </div>
  )
}
