import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Play, Square, Loader2, LocateFixed, WifiOff, Wifi, RefreshCw, AlertTriangle } from 'lucide-react'
import { useToast } from '@/hooks/use-toast'
import { useWorkLog } from '../api/useWorkLog'
import { useProjectWorkLogSummary } from '../api/useProjectWorkLogSummary'
import { useFieldSync } from '@/hooks/useFieldSync'
import { requestFieldDeviceSync } from '@/features/field-service/utils/fieldDeviceSyncEvents'
import { useTenant } from '@/contexts/TenantContext'
import { formatElapsedSeconds } from '@/lib/dateLocal'

interface WorkLogCardProps {
  projectId: string
  /** When true, start punch is blocked (visit closed / on_hold / cancelled). */
  locked?: boolean
}

function getErrorMessage(err: unknown): string {
  if (err instanceof Error) return err.message
  if (typeof err === 'object' && err !== null && 'message' in err) {
    const message = (err as { message?: unknown }).message
    if (typeof message === 'string' && message.trim().length > 0) return message
  }
  return 'Error inesperat'
}

function getWorklogUiErrorMessage(
  message: string,
  t: (key: string, fallback: string, options?: Record<string, unknown>) => string,
): string {
  if (message.startsWith('worklog_already_open_other_project:')) {
    const project = message.replace('worklog_already_open_other_project:', '').trim()
    const fallbackProject = t('projects.worklog.other_project_unknown', 'un altre projecte')
    return t(
      'projects.worklog.other_project_open',
      'Ja tens un fitxatge obert al projecte {{project}}. Tanca\'l abans d\'iniciar-ne un de nou aquí.',
      { project: project || fallbackProject },
    )
  }

  if (message === 'worklog_already_open') {
    return t(
      'projects.worklog.error_already_open',
      'Ja tens un fitxatge obert. Tanca\'l abans d\'iniciar-ne un de nou.',
    )
  }

  if (message.includes('permission denied for table work_logs')) {
    return t(
      'projects.worklog.error_start_forbidden',
      'No s\'ha pogut validar l\'estat de fitxatge. Torna-ho a provar en uns segons.',
    )
  }

  if (message.includes('work_log_blocked_visit_closed')) {
    return t(
      'field-service:punch.blocked_closed',
      'La visita està tancada; no es pot fitxar.',
    )
  }

  return message
}

export function WorkLogCard({ projectId, locked = false }: WorkLogCardProps) {
  const { t } = useTranslation(['projects', 'field-service'])
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const sync = useFieldSync(activeTenant?.id ?? null, { autoDrain: false })
  const {
    openLog,
    openLogInOtherProject,
    isCheckingOpenLogInOtherProject,
    isLoading,
    isStarting,
    isStopping,
    isCapturingGeo,
    startWorkLog,
    stopWorkLog,
  } = useWorkLog(projectId)
  const summary = useProjectWorkLogSummary(projectId)

  const startBlockedByOtherProject = !!openLogInOtherProject?.id
  const blockedProjectLabel = openLogInOtherProject?.project_name?.trim()
    || openLogInOtherProject?.project_id
    || t('projects.worklog.other_project_unknown', 'un altre projecte')

  const isActionPending = isStarting || isStopping
  const [isRetrying, setIsRetrying] = useState(false)
  const retryTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => {
    if (!isRetrying) return
    if (sync.quarantinedCount === 0 && sync.rejectedCount === 0) {
      if (retryTimeoutRef.current) clearTimeout(retryTimeoutRef.current)
      setIsRetrying(false)
    }
  }, [isRetrying, sync.quarantinedCount, sync.rejectedCount])

  useEffect(() => {
    return () => {
      if (retryTimeoutRef.current) clearTimeout(retryTimeoutRef.current)
    }
  }, [])

  const hasIncident =
    startBlockedByOtherProject
    || !sync.isOnline
    || sync.isSyncing
    || sync.pendingCount > 0
    || sync.rejectedCount > 0
    || sync.quarantinedCount > 0

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
      const msg = getErrorMessage(err)
      toast({ variant: 'destructive', description: getWorklogUiErrorMessage(msg, t) })
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
      const msg = getErrorMessage(err)
      toast({ variant: 'destructive', description: getWorklogUiErrorMessage(msg, t) })
    }
  }

  async function handleRetryFailed() {
    try {
      setIsRetrying(true)
      if (retryTimeoutRef.current) clearTimeout(retryTimeoutRef.current)
      retryTimeoutRef.current = setTimeout(() => setIsRetrying(false), 35_000)

      await sync.retryQuarantined()
      await requestFieldDeviceSync()
    } catch (err) {
      setIsRetrying(false)
      const msg = getErrorMessage(err)
      toast({ variant: 'destructive', description: msg })
    }
  }

  async function handleDiscardFailed() {
    try {
      const removed = await sync.discardFailed()
      if (removed === 0) {
        toast({
          description: t('projects.worklog.discard_empty', 'No hi ha errors pendents per descartar.'),
        })
        return
      }
      toast({
        description: removed > 1
          ? t('projects.worklog.discard_success_plural', '{{count}} operacions amb error descartades de la cua local.', { count: removed })
          : t('projects.worklog.discard_success', '{{count}} operació amb error descartada de la cua local.', { count: removed }),
      })
    } catch (err) {
      const msg = getErrorMessage(err)
      toast({ variant: 'destructive', description: msg })
    }
  }

  const isOpen = !!openLog?.id
  const displaySeconds = isOpen ? summary.sessionSeconds : summary.totalSeconds
  const timeCaption = isOpen
    ? t('projects.worklog.session_elapsed', 'Temps en curs')
    : t('projects.worklog.total_time', 'Temps acumulat')

  function formatIntervalRange(checkIn: string | null, checkOut: string | null): string {
    if (!checkIn) return '—'
    const start = new Date(checkIn).toLocaleString('ca-ES', {
      day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit',
    })
    if (!checkOut) return `${start} → …`
    const end = new Date(checkOut).toLocaleTimeString('ca-ES', {
      hour: '2-digit', minute: '2-digit',
    })
    return `${start} → ${end}`
  }

  return (
    <section className="rounded-xl border border-border p-5 space-y-4">
      <div className="flex items-end justify-between gap-4">
        <div>
          <p className="text-3xl font-bold tabular-nums tracking-tight text-foreground">
            {summary.isLoading ? '—' : formatElapsedSeconds(displaySeconds)}
          </p>
          <p className="text-sm text-muted-foreground">{timeCaption}</p>
        </div>
        {openLog?.id ? (
          <Badge variant="default">{t('projects.worklog.status_open', 'Obert')}</Badge>
        ) : (
          <Badge variant="outline">{t('projects.worklog.status_closed', 'Tancat')}</Badge>
        )}
      </div>

      {isOpen && summary.totalSeconds > summary.sessionSeconds && (
        <p className="text-sm text-muted-foreground">
          {t('projects.worklog.total_on_project', 'Total a l\'obra')}:{' '}
          <span className="font-medium tabular-nums text-foreground">
            {formatElapsedSeconds(summary.totalSeconds)}
          </span>
        </p>
      )}

      <div className="text-sm text-muted-foreground">
        {isLoading && t('projects.worklog.loading', 'Carregant estat...')}
        {!isLoading && openLog?.check_in && (
          <span>
            {t('projects.worklog.started_at', 'Iniciat a')}: {new Date(openLog.check_in).toLocaleString('ca-ES')}
          </span>
        )}
        {!isLoading && !openLog?.id && summary.intervals.length === 0 && (
          <span>{t('projects.worklog.no_open_log', 'No hi ha cap fitxatge obert')}</span>
        )}
      </div>

      {summary.intervals.length > 0 && (
        <div className="space-y-2">
          <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            {t('projects.worklog.intervals_title', 'Intervals')}
          </p>
          <ul className="divide-y divide-border rounded-lg border border-border overflow-hidden">
            {summary.intervals.map((interval, idx) => (
              <li
                key={`${interval.check_in ?? 'x'}-${interval.check_out ?? 'open'}-${idx}`}
                className="flex items-center justify-between gap-3 px-3 py-2 text-sm bg-card"
              >
                <div className="min-w-0">
                  <p className="truncate text-foreground">
                    {formatIntervalRange(interval.check_in, interval.check_out)}
                  </p>
                  {interval.isOpen && (
                    <p className="text-xs text-green-700 dark:text-green-400">
                      {t('projects.worklog.status_open', 'Obert')}
                    </p>
                  )}
                </div>
                <span className="tabular-nums font-medium shrink-0">
                  {formatElapsedSeconds(interval.seconds)}
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}

      {locked && !openLog?.id && (
        <p className="text-xs text-muted-foreground">
          {t('field-service:punch.blocked_closed', 'La visita està tancada; no es pot fitxar.')}
        </p>
      )}

      <div className="flex flex-wrap gap-2">
        {!openLog?.id ? (
          <Button
            size="sm"
            onClick={onStart}
            disabled={locked || isActionPending || isCheckingOpenLogInOtherProject || startBlockedByOtherProject}
            title={
              locked
                ? t('field-service:punch.blocked_closed', 'La visita està tancada; no es pot fitxar.')
                : startBlockedByOtherProject
                  ? t('projects.worklog.start_blocked_other_project_tooltip', 'No pots iniciar: ja tens un fitxatge obert en un altre projecte.')
                  : undefined
            }
          >
            {isActionPending ? <Loader2 className="h-3.5 w-3.5 mr-1 animate-spin" /> : <Play className="h-3.5 w-3.5 mr-1" />}
            {t('projects.worklog.start', 'Iniciar')}
          </Button>
        ) : (
          <Button size="sm" variant="destructive" onClick={onStop} disabled={isActionPending}>
            {isActionPending ? <Loader2 className="h-3.5 w-3.5 mr-1 animate-spin" /> : <Square className="h-3.5 w-3.5 mr-1" />}
            {t('projects.worklog.stop', 'Aturar')}
          </Button>
        )}

        <Button size="sm" variant="outline" disabled>
          <LocateFixed className="h-3.5 w-3.5 mr-1" />
          {isCapturingGeo
            ? t('projects.worklog.geo_capturing', 'Capturant GPS...')
            : t('projects.worklog.geo_ready', 'GPS preparat')}
        </Button>
      </div>

      {hasIncident && (
        <section className="rounded-lg border border-border bg-muted/30 p-3 space-y-2">
          <div className="flex items-center gap-2 text-xs">
            {!sync.isOnline ? (
              <WifiOff className="h-3.5 w-3.5 text-destructive shrink-0" />
            ) : sync.isSyncing ? (
              <RefreshCw className="h-3.5 w-3.5 animate-spin text-muted-foreground shrink-0" />
            ) : (
              <Wifi className="h-3.5 w-3.5 text-green-600 shrink-0" />
            )}

            <span className="text-muted-foreground">
              {t('projects.worklog.sync_status_title', 'Estat de sincronització')}
            </span>

            {sync.pendingCount > 0 && (
              <span className="font-medium text-foreground">
                {sync.pendingCount > 1
                  ? t('projects.worklog.sync_pending_plural', '{{count}} operacions pendents de sincronitzar', { count: sync.pendingCount })
                  : t('projects.worklog.sync_pending', '{{count}} operació pendent de sincronitzar', { count: sync.pendingCount })
                }
              </span>
            )}
          </div>

          {sync.quarantinedCount > 0 ? (
            <div role="alert" className="flex items-start justify-between gap-3 flex-wrap rounded-md border border-destructive/30 bg-destructive/5 px-3 py-2">
              <div className="flex items-start gap-2 text-xs">
                <AlertTriangle className="h-3.5 w-3.5 text-destructive mt-0.5 shrink-0" />
                <div>
                  <p className="font-medium text-destructive">
                    {sync.quarantinedCount > 1
                      ? t('projects.worklog.quarantined_notice_plural', '{{count}} operacions han exhaurit els reintents automàtics.', {
                        count: sync.quarantinedCount,
                      })
                      : t('projects.worklog.quarantined_notice', '{{count}} operació ha exhaurit els reintents automàtics.', {
                        count: sync.quarantinedCount,
                      })
                    }
                  </p>
                  <p className="text-muted-foreground">
                    {t('projects.worklog.quarantined_hint', 'Prem «Reintentar ara» per tornar-ho a intentar manualment.')}
                  </p>
                </div>
              </div>

              <div className="flex items-center gap-3">
                <button
                  type="button"
                  disabled={isRetrying || sync.isSyncing}
                  onClick={() => { void handleRetryFailed() }}
                  className="text-xs font-medium text-destructive hover:underline disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  {isRetrying
                    ? t('projects.worklog.retrying', 'Reintentant…')
                    : t('projects.worklog.retry_cta', 'Reintentar ara')
                  }
                </button>
                <button
                  type="button"
                  disabled={sync.isSyncing}
                  onClick={() => { void handleDiscardFailed() }}
                  className="text-xs font-medium text-muted-foreground hover:underline disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  {t('projects.worklog.discard_cta', 'Descartar errors')}
                </button>
              </div>
            </div>
          ) : startBlockedByOtherProject ? (
            <p role="alert" className="flex items-start gap-2 text-xs rounded-md border border-destructive/30 bg-destructive/5 px-3 py-2 text-destructive">
              <AlertTriangle className="h-3.5 w-3.5 mt-0.5 shrink-0" />
              {t(
                'projects.worklog.other_project_open',
                'Ja tens un fitxatge obert al projecte {{project}}. Tanca\'l abans d\'iniciar-ne un de nou aquí.',
                { project: blockedProjectLabel },
              )}
            </p>
          ) : sync.rejectedCount > 0 ? (
            <p role="status" className="flex items-start gap-2 text-xs rounded-md border border-amber-300/50 bg-amber-50/50 dark:bg-amber-950/20 px-3 py-2 text-muted-foreground">
              <AlertTriangle className="h-3.5 w-3.5 text-amber-600 dark:text-amber-400 mt-0.5 shrink-0" />
              {sync.rejectedCount > 1
                ? t('projects.worklog.rejected_hint_plural', '{{count}} operacions amb error temporal. Es reintentaran automàticament en recuperar connexió.', {
                  count: sync.rejectedCount,
                })
                : t('projects.worklog.rejected_hint', '{{count}} operació amb error temporal. Es reintentarà automàticament en recuperar connexió.', {
                  count: sync.rejectedCount,
                })
              }
            </p>
          ) : !sync.isOnline ? (
            <p role="status" className="flex items-center gap-1.5 text-xs text-amber-600 dark:text-amber-400 px-1">
              <WifiOff className="h-3 w-3 flex-shrink-0" />
              {sync.pendingCount > 0
                ? t('projects.worklog.saved_offline', 'Desat localment, es sincronitzarà en recuperar connexió')
                : t('projects.worklog.offline_warning', 'Fora de línia — les operacions s\'enviaran quan recuperis la connexió')
              }
            </p>
          ) : sync.isSyncing ? (
            <p role="status" className="text-xs text-muted-foreground px-1">
              {t('projects.worklog.syncing', 'Sincronitzant…')}
            </p>
          ) : null}
        </section>
      )}
    </section>
  )
}
