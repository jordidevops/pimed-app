import { useTranslation } from 'react-i18next'
import { Loader2, Play, Square } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { useWorkLog } from '@/features/projects/api/useWorkLog'
import { useProjectWorkLogSummary } from '@/features/projects/api/useProjectWorkLogSummary'
import { formatElapsedSeconds } from '@/lib/dateLocal'
import { cn } from '@/lib/utils'

interface ProjectPunchStripProps {
  projectId: string
  className?: string
  /** When true, start punch is blocked (visit closed / on_hold / cancelled). */
  locked?: boolean
}

export function ProjectPunchStrip({ projectId, className, locked = false }: ProjectPunchStripProps) {
  const { t } = useTranslation(['projects', 'field-service'])
  const { toast } = useToast()
  const summary = useProjectWorkLogSummary(projectId)
  const {
    openLog,
    openLogInOtherProject,
    isCheckingOpenLogInOtherProject,
    isStarting,
    isStopping,
    isCapturingGeo,
    startWorkLog,
    stopWorkLog,
  } = useWorkLog(projectId)

  const busy = isStarting || isStopping || isCapturingGeo || summary.isLoading
  const blockedElsewhere = !!openLogInOtherProject?.id
  const isOpen = summary.isOpen

  async function onStart() {
    if (locked) return
    try {
      const result = await startWorkLog()
      await summary.refetch()
      toast({
        description: result.mode === 'offline'
          ? t('projects.worklog.toast_start_offline', 'Inici desat en local (offline)')
          : t('projects.worklog.toast_start_online', 'Fitxatge iniciat'),
      })
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Error'
      toast({
        variant: 'destructive',
        description: msg.includes('work_log_blocked_visit_closed')
          ? t('field-service:punch.blocked_closed', 'La visita està tancada; no es pot fitxar.')
          : msg,
      })
    }
  }

  async function onStop() {
    try {
      const result = await stopWorkLog()
      await summary.refetch()
      toast({
        description: result.mode === 'offline'
          ? t('projects.worklog.toast_stop_offline', 'Aturada desada en local (offline)')
          : t('projects.worklog.toast_stop_online', 'Fitxatge aturat'),
      })
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Error'
      toast({ variant: 'destructive', description: msg })
    }
  }

  const displayTime = isOpen ? summary.sessionSeconds : summary.totalSeconds
  const timeLabel = isOpen
    ? t('field-service:detail.punch_elapsed', 'Temps en curs')
    : t('field-service:detail.punch_total', 'Temps treballat')

  return (
    <div
      className={cn(
        'mb-4 flex items-center gap-3 rounded-2xl border border-border bg-card p-3 shadow-sm',
        className,
      )}
    >
      {!isOpen ? (
        <Button
          type="button"
          size="icon"
          className="h-14 w-14 shrink-0 rounded-full bg-green-600 text-white hover:bg-green-700 shadow-md"
          onClick={onStart}
          disabled={locked || busy || isCheckingOpenLogInOtherProject || blockedElsewhere}
          aria-label={t('field-service:fab.start', 'Iniciar visita')}
          title={
            locked
              ? t('field-service:punch.blocked_closed', 'La visita està tancada; no es pot fitxar.')
              : undefined
          }
        >
          {busy ? <Loader2 className="h-6 w-6 animate-spin" /> : <Play className="h-6 w-6 ml-0.5" />}
        </Button>
      ) : (
        <Button
          type="button"
          size="icon"
          variant="destructive"
          className="h-14 w-14 shrink-0 rounded-full shadow-md"
          onClick={onStop}
          disabled={busy}
          aria-label={t('projects.worklog.stop', 'Aturar')}
        >
          {busy ? <Loader2 className="h-6 w-6 animate-spin" /> : <Square className="h-5 w-5" />}
        </Button>
      )}

      <div className="min-w-0 flex-1">
        <p className="text-2xl font-bold tabular-nums tracking-tight text-foreground">
          {formatElapsedSeconds(displayTime)}
        </p>
        <p className="text-sm text-muted-foreground">{timeLabel}</p>
        {locked && !isOpen && (
          <p className="mt-1 text-xs text-muted-foreground">
            {t('field-service:punch.blocked_closed', 'La visita està tancada; no es pot fitxar.')}
          </p>
        )}
        {blockedElsewhere && !isOpen && (
          <p className="mt-1 text-xs text-amber-700 dark:text-amber-400 line-clamp-2">
            {t(
              'projects.worklog.other_project_open',
              "Ja tens un fitxatge obert al projecte {{project}}.",
              { project: openLogInOtherProject?.project_name ?? '—' },
            )}
          </p>
        )}
      </div>

      {isOpen && summary.totalSeconds > summary.sessionSeconds && (
        <div className="text-right text-xs text-muted-foreground shrink-0">
          <p className="font-medium text-foreground tabular-nums">
            {formatElapsedSeconds(summary.totalSeconds)}
          </p>
          <p>{t('field-service:detail.punch_total_short', 'Total obra')}</p>
        </div>
      )}
    </div>
  )
}
