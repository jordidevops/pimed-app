import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { MapPin, ChevronRight, Loader2, Pause, Play } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { useToast } from '@/hooks/use-toast'
import { useTodayOrders } from '../api/useTodayOrders'
import { getProjectStatusLabel, getProjectStatusVariant } from '@/features/projects/projectStatus'
import { useWorkLog } from '@/features/projects/api/useWorkLog'
import { formatElapsedSeconds } from '@/lib/dateLocal'
import { cn } from '@/lib/utils'
import { StartVisitFab } from './StartVisitFab'
import { StartVisitDialog } from './StartVisitDialog'
import { FieldOnboardingCard } from './FieldOnboardingCard'
import { FieldStatsRow } from './FieldStatsRow'
import { useFieldSync } from '@/hooks/useFieldSync'
import { useTenant } from '@/contexts/TenantContext'
import { useOnlineStatus } from '@/hooks/useOnlineStatus'
import { countPendingPhotos } from '@/lib/today-cache'
import type { ProjectListItem } from '@/features/projects/api/projectsService'

function formatTime(iso: string | null | undefined): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })
}

function siteLine(order: {
  contact_site_name?: string | null
  contact_site_address?: string | null
  contact_site_city?: string | null
}): string | null {
  const parts = [order.contact_site_name, order.contact_site_address, order.contact_site_city].filter(Boolean)
  return parts.length > 0 ? parts.join(' · ') : null
}

function useLiveElapsed(checkIn: string | null | undefined): number {
  const [seconds, setSeconds] = useState(0)
  useEffect(() => {
    if (!checkIn) {
      setSeconds(0)
      return
    }
    const startMs = new Date(checkIn).getTime()
    const tick = () => setSeconds(Math.max(0, Math.floor((Date.now() - startMs) / 1000)))
    tick()
    const id = window.setInterval(tick, 1000)
    return () => window.clearInterval(id)
  }, [checkIn])
  return seconds
}

export function TodayPage() {
  const { t } = useTranslation(['field-service', 'projects'])
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const isOnline = useOnlineStatus()
  const sync = useFieldSync(activeTenant?.id ?? null)
  const [photoPending, setPhotoPending] = useState(0)
  const [visitDialogOpen, setVisitDialogOpen] = useState(false)
  const [visitOrderId, setVisitOrderId] = useState<string | null>(null)
  const { data, isLoading } = useTodayOrders()
  const orders = data?.items ?? []
  const fromCache = Boolean((data as { fromCache?: boolean } | undefined)?.fromCache)
  const pendingTotal = sync.pendingCount + photoPending

  const { openLogInOtherProject, isCheckingOpenLogInOtherProject } = useWorkLog(null)
  const activeProjectId = openLogInOtherProject?.project_id ?? null
  const {
    stopWorkLog,
    isStopping,
    isCapturingGeo,
    openLog,
  } = useWorkLog(activeProjectId)
  const activeCheckIn = openLog?.check_in ?? openLogInOtherProject?.check_in ?? null
  const elapsedSeconds = useLiveElapsed(activeProjectId ? activeCheckIn : null)
  const canStopNow = !!activeProjectId && !!openLog?.id
  const stopBusy = isStopping || isCapturingGeo || (!!activeProjectId && !openLog?.id)

  useEffect(() => {
    if (!activeTenant?.id) {
      setPhotoPending(0)
      return
    }
    const refresh = () => {
      void countPendingPhotos(activeTenant.id).then(setPhotoPending)
    }
    refresh()
    const id = window.setInterval(refresh, 15_000)
    return () => window.clearInterval(id)
  }, [activeTenant?.id, sync.pendingCount])

  function openStartVisit(order: ProjectListItem, e?: React.MouseEvent) {
    e?.preventDefault()
    e?.stopPropagation()
    if (!order.id || order.status === 'completed' || order.status === 'cancelled') return
    if (activeProjectId) return
    setVisitOrderId(order.id)
    setVisitDialogOpen(true)
  }

  async function handleStopVisit(e?: React.MouseEvent) {
    e?.preventDefault()
    e?.stopPropagation()
    if (!activeProjectId) return
    if (!openLog?.id) return
    try {
      const result = await stopWorkLog()
      toast({
        description: result.mode === 'offline'
          ? t('projects:projects.worklog.toast_stop_offline', 'Aturada desada en local (offline)')
          : t('projects:projects.worklog.toast_stop_online', 'Fitxatge aturat'),
      })
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Error'
      toast({ variant: 'destructive', description: msg })
    }
  }

  if (isLoading) {
    return (
      <div className="flex h-64 items-center justify-center">
        <div className="h-6 w-6 animate-spin rounded-full border-2 border-primary border-t-transparent" />
      </div>
    )
  }

  return (
    <div className="mx-auto max-w-lg space-y-4 px-4 py-6 pb-24">
      <div>
        <h1 className="text-2xl font-bold">{t('field-service:today.title', 'Avui')}</h1>
        <p className="text-sm text-muted-foreground">
          {t('field-service:today.subtitle', 'Les teves visites i ordres d\'avui')}
        </p>
        {!isOnline && (
          <p className="mt-1 text-xs text-muted-foreground">
            {fromCache
              ? t('field-service:today.offline_cache', 'Sense xarxa — mostrant Avui en caché')
              : t('field-service:today.offline', 'Sense xarxa')}
          </p>
        )}
        {pendingTotal > 0 && (
          <p className="mt-1 text-xs text-amber-600">
            {t('field-service:today.open_queue', '{{count}} pendents de sincronitzar', {
              count: pendingTotal,
            })}
          </p>
        )}
      </div>

      <FieldStatsRow />
      <FieldOnboardingCard show={orders.length === 0} />

      {orders.length === 0 ? (
        <div className="rounded-2xl border border-dashed border-border py-12 text-center">
          <p className="text-sm text-muted-foreground">
            {t('field-service:today.empty', 'No tens visites planificades per avui')}
          </p>
          <Button asChild variant="outline" size="sm" className="mt-3">
            <Link to="/field/orders">
              {t('field-service:today.empty_cta', 'Veure totes les ordres')}
            </Link>
          </Button>
        </div>
      ) : (
        <ul className="space-y-3">
          {orders.map((order) => {
            const address = siteLine(order)
            const isActive = !!order.id && order.id === activeProjectId
            const canStart =
              !activeProjectId
              && order.status !== 'completed'
              && order.status !== 'cancelled'
            return (
              <li key={order.id} className="flex items-stretch gap-2">
                <Link
                  to={`/field/orders/${order.id}`}
                  className={cn(
                    'flex min-w-0 flex-1 items-start gap-3 rounded-2xl border bg-card p-4 hover:bg-accent/30 transition-colors min-h-16',
                    isActive ? 'border-green-600/50 bg-green-50/40 dark:bg-green-950/20' : 'border-border',
                  )}
                >
                  <div className="flex-1 min-w-0 space-y-1">
                    <div className="flex items-center gap-2 flex-wrap">
                      <span className="font-semibold text-foreground truncate">
                        {order.name}
                      </span>
                      {isActive ? (
                        <Badge className="bg-green-600 hover:bg-green-600 text-white">
                          {t('field-service:today.working', 'Treballant')}
                          {activeCheckIn ? ` · ${formatElapsedSeconds(elapsedSeconds)}` : ''}
                        </Badge>
                      ) : (
                        <Badge variant={getProjectStatusVariant(order.status)}>
                          {getProjectStatusLabel(t, order.status, { fieldService: true })}
                        </Badge>
                      )}
                    </div>
                    {order.client_display_name && (
                      <p className="text-sm text-muted-foreground truncate">
                        {order.client_display_name}
                      </p>
                    )}
                    {address && (
                      <p className="text-xs text-muted-foreground flex items-center gap-1">
                        <MapPin className="h-3 w-3 shrink-0" />
                        <span className="truncate">{address}</span>
                      </p>
                    )}
                    <p className="text-xs text-muted-foreground">
                      {formatTime(order.planned_start)}
                      {order.planned_end ? ` – ${formatTime(order.planned_end)}` : ''}
                    </p>
                  </div>
                  <ChevronRight className="h-5 w-5 text-muted-foreground mt-1 shrink-0" />
                </Link>
                {isActive && (
                  <Button
                    type="button"
                    size="icon"
                    variant="destructive"
                    className="h-auto min-h-16 w-12 shrink-0 rounded-2xl"
                    aria-label={t('field-service:today.stop_visit', 'Aturar visita')}
                    disabled={stopBusy || !canStopNow || isCheckingOpenLogInOtherProject}
                    onClick={(e) => { void handleStopVisit(e) }}
                  >
                    {stopBusy
                      ? <Loader2 className="h-5 w-5 animate-spin" />
                      : <Pause className="h-5 w-5" />}
                  </Button>
                )}
                {canStart && (
                  <Button
                    type="button"
                    size="icon"
                    variant="outline"
                    className="h-auto min-h-16 w-12 shrink-0 rounded-2xl"
                    aria-label={t('field-service:fab.start', 'Iniciar visita')}
                    onClick={(e) => openStartVisit(order, e)}
                  >
                    <Play className="h-5 w-5" />
                  </Button>
                )}
              </li>
            )
          })}
        </ul>
      )}

      <StartVisitFab orders={orders} activeProjectId={activeProjectId} onStop={() => { void handleStopVisit() }} stopBusy={stopBusy || !canStopNow} />
      <StartVisitDialog
        open={visitDialogOpen}
        onOpenChange={setVisitDialogOpen}
        orders={orders}
        initialOrderId={visitOrderId}
      />
    </div>
  )
}
