import { useEffect, useState, useMemo, useCallback } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { AlertTriangle, Coffee, Loader2, MapPin, Wifi, WifiOff } from 'lucide-react'
import { useAuth } from '@/contexts/AuthContext'
import { useTenant } from '@/contexts/TenantContext'
import { useToast } from '@/hooks/use-toast'
import { supabase } from '@/lib/supabase'
import { hasSeenGeoNotice, setGeoNoticeChoice } from '../api/geoNoticeStorage'
import { useMyEmployee } from '../api/useMyEmployee'
import { useMyAttendanceToday } from '../api/useMyAttendanceToday'
import { useAttendanceRecordPolicy } from '../api/useAttendanceRecordPolicy'
import { useMyPunchSchedule } from '../api/useMyPunchSchedule'
import { useAttendanceGeoEnabled } from '../api/useAttendanceGeoEnabled'
import { usePauseConfigs } from '../api/usePauseConfigs'
import { useAttendanceSync } from '../hooks/useAttendanceSync'
import { useRecordPunch } from '../hooks/useRecordPunch'
import { attendanceDb } from '../db/attendanceDb'
import type { LocalAttendanceOp } from '../db/attendanceDb'
import { PunchActionPanel } from '../components/PunchActionPanel'
import { PauseButtonGroup } from '../components/PauseButtonGroup'
import { RemoteWorkSwitch } from '../components/RemoteWorkSwitch'
import { LocationConsentDialog } from '../components/LocationConsentDialog'
import { AttendanceStatusBadge } from '../components/AttendanceStatusBadge'
import { AnomalyAlert } from '../components/AnomalyAlert'
import { DailyTimeline } from '../components/DailyTimeline'
import { AttendanceTabs } from '../components/AttendanceTabs'
import { PunchDaySchedule } from '../components/PunchDaySchedule'
import { WorkScheduleStatusCard } from '../components/WorkScheduleStatusCard'
import { PunchDiscrepancyDialog } from '../components/PunchDiscrepancyDialog'
import type { PunchRecordedContext } from '../api/punchDiscrepancyService'
import { useSubmitPunchDiscrepancy } from '../api/useSubmitPunchDiscrepancy'
import {
  availableDiscrepancyResolutions,
  detectPunchDiscrepancyHints,
  shouldPromptPunchDiscrepancy,
  type PunchDiscrepancyHint,
  type PunchDiscrepancyResolution,
} from '../utils/punchDiscrepancyUtils'
import { parsePunchDiscrepancyToleranceMinutes } from '../api/punchDiscrepancySettings'
import {
  isLegacyInOutOnly,
  isMobileWorkProfile,
  type ExtendedPunchType,
} from '../utils/punchProfileUi'

export function PunchPage() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const { user } = useAuth()
  const { activeTenant, tenantsLoading } = useTenant()

  const { data: myEmployee, isLoading: employeeLoading, error: employeeError } = useMyEmployee()
  const { data: recordPolicy } = useAttendanceRecordPolicy(myEmployee?.id)
  const workProfile = recordPolicy?.work_profile ?? 'fixed_site'
  const legacyInOutOnly = isLegacyInOutOnly(workProfile, recordPolicy?.policy)
  const isMobileProfile = isMobileWorkProfile(workProfile) && !legacyInOutOnly
  const { data: pauseConfigs = [], isLoading: pauseConfigsLoading } = usePauseConfigs()

  const {
    punches,
    lastPunch,
    currentStatus,
    dayState,
    activePauseType,
    openPauseSince,
    hasAnomalies,
    anomalyCodes,
    isRemote: derivedRemote,
    isLoading: todayLoading,
    invalidateToday,
  } = useMyAttendanceToday(myEmployee?.id, {
    workProfile,
    legacyInOutOnly,
  })

  const [isRemote, setIsRemote] = useState(false)
  const [geoConsent, setGeoConsent] = useState(false)
  const [consentDialogOpen, setConsentDialogOpen] = useState(false)
  const [locationRequired, setLocationRequired] = useState(false)
  const [discrepancyToleranceMin, setDiscrepancyToleranceMin] = useState(15)
  const [now, setNow] = useState(() => Date.now())
  const [activePunchType, setActivePunchType] = useState<ExtendedPunchType | null>(null)
  const [discrepancyOpen, setDiscrepancyOpen] = useState(false)
  const [discrepancyPunchId, setDiscrepancyPunchId] = useState<string | null>(null)
  const [discrepancyHints, setDiscrepancyHints] = useState<PunchDiscrepancyHint[]>([])
  const [discrepancyOptions, setDiscrepancyOptions] = useState<PunchDiscrepancyResolution[]>([])
  const submitDiscrepancy = useSubmitPunchDiscrepancy()

  // Actualitzem "now" cada minut per recalcular el timeout de pausa sense reload
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 60_000)
    return () => clearInterval(id)
  }, [])

  useEffect(() => {
    if (!myEmployee?.id) return
    const emp = myEmployee as typeof myEmployee & { location_consent_given?: boolean }
    setGeoConsent(Boolean(emp.location_consent_given))
  }, [myEmployee])

  useEffect(() => {
    if (!activeTenant?.id) return
    let mounted = true
    async function loadSettings() {
      const { data } = await supabase.rpc('get_effective_settings', {
        p_tenant_id: activeTenant!.id,
      })
      if (mounted && data) {
        const settings = data as Record<string, unknown>
        setLocationRequired(Boolean(settings.attendance_location_consent_required))
        setDiscrepancyToleranceMin(parsePunchDiscrepancyToleranceMinutes(settings))
      }
    }
    loadSettings()
    return () => { mounted = false }
  }, [activeTenant?.id])

  const { isOnline, isSyncing, pendingCount, lastSyncedAt, refreshCounts } = useAttendanceSync(
    myEmployee?.id ?? '',
    activeTenant?.id ?? '',
    invalidateToday,
  )

  // Detecció client-side del timeout de pausa
  const pauseTimeoutReached = useMemo(() => {
    if (currentStatus !== 'on_pause' || !openPauseSince) return false
    const activePauseConfig = pauseConfigs.find(c => c.key === activePauseType)
    const maxMin = activePauseConfig?.max_duration_minutes ?? 240
    const elapsedMin = (now - new Date(openPauseSince).getTime()) / 60_000
    return elapsedMin >= maxMin
  }, [currentStatus, openPauseSince, activePauseType, pauseConfigs, now])

  const showPauseNotClosed = anomalyCodes.includes('PAUSE_NOT_CLOSED') || pauseTimeoutReached

  const punchedOutToday =
    lastPunch?.punch_type === 'day_end' ||
    (!isMobileProfile && lastPunch?.punch_type === 'out')

  const {
    today: todaySchedule,
    upcoming,
    showUpcoming,
    isLoading: scheduleLoading,
    isUpcomingLoading,
  } = useMyPunchSchedule(myEmployee?.id, {
    punchedOutToday,
    nowMs: now,
  })

  const { data: geoEnabled = false } = useAttendanceGeoEnabled(myEmployee?.id)

  const handlePunchRecorded = useCallback(
    (ctx: PunchRecordedContext) => {
      if (!ctx.punchId || (ctx.punchType !== 'in' && ctx.punchType !== 'out')) return

      const occurredAt = new Date(ctx.occurredAt)
      const hints = detectPunchDiscrepancyHints({
        punchType: ctx.punchType,
        occurredAt,
        schedule: todaySchedule,
        anomalyCodes: ctx.anomalyCodes,
        hadGeo: ctx.hadGeo,
        toleranceMinutes: discrepancyToleranceMin,
      })

      if (!shouldPromptPunchDiscrepancy(hints, ctx.anomalyCodes)) return

      const options = availableDiscrepancyResolutions({
        hints,
        punchType: ctx.punchType,
        hadGeo: ctx.hadGeo,
        anomalyCodes: ctx.anomalyCodes,
      })

      setDiscrepancyPunchId(ctx.punchId)
      setDiscrepancyHints(hints)
      setDiscrepancyOptions(options)
      setDiscrepancyOpen(true)
    },
    [todaySchedule, discrepancyToleranceMin],
  )

  const { isLoading: punchLoading, isLocating, punchByType, startPause, endPause } = useRecordPunch({
    employeeId: myEmployee?.id ?? '',
    tenantId: activeTenant?.id ?? '',
    userId: user!.id,
    isOnline,
    geoConsent,
    geoEnabled,
    geoCaptureOptional: geoEnabled && !locationRequired,
    isRemote,
    onSuccess: invalidateToday,
    onOfflineQueued: () => {
      invalidateToday()
      refreshCounts()
    },
    onPunchRecorded: handlePunchRecorded,
  })

  useEffect(() => {
    if (!punchLoading) setActivePunchType(null)
  }, [punchLoading])

  async function handleDiscrepancySelect(resolution: PunchDiscrepancyResolution) {
    if (!discrepancyPunchId) return
    await submitDiscrepancy.mutateAsync({
      punchId: discrepancyPunchId,
      resolution,
      context: { hints: discrepancyHints },
    })
    setDiscrepancyOpen(false)
    setDiscrepancyPunchId(null)
    invalidateToday()
  }

  const [pendingOps, setPendingOps] = useState<LocalAttendanceOp[]>([])
  useEffect(() => {
    let mounted = true
    const empId = myEmployee?.id
    const tenantId = activeTenant?.id
    if (!empId || !tenantId) {
      setPendingOps([])
      return () => { mounted = false }
    }
    async function load() {
      const ops = await attendanceDb.attendance_ops
        .filter(
          (op) =>
            op.tenant_id === tenantId &&
            op.employee_id === empId &&
            (op.status === 'pending' || op.status === 'quarantined'),
        )
        .toArray()
      ops.sort((a, b) => (a.created_at ?? '').localeCompare(b.created_at ?? ''))
      if (mounted) setPendingOps(ops)
    }
    load()
    return () => { mounted = false }
  }, [myEmployee?.id, activeTenant?.id, pendingCount, lastSyncedAt])

  async function handleAcceptConsent() {
    const tenantId = activeTenant?.id
    if (tenantId) setGeoNoticeChoice(tenantId, 'accepted')

    try {
      await supabase.rpc(
        // @ts-expect-error RPC added in attendance v2 migration
        'give_location_consent',
        { p_version: '1.0' },
      )
      setGeoConsent(true)
      setConsentDialogOpen(false)
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('geo.consent_error', "No s'ha pogut registrar el consentiment"),
        description: err instanceof Error ? err.message : String(err),
      })
    }
  }

  function handleDeclineConsent() {
    const tenantId = activeTenant?.id
    if (tenantId && !hasSeenGeoNotice(tenantId)) {
      setGeoNoticeChoice(tenantId, 'declined')
    }
    setConsentDialogOpen(false)
  }

  function handlePunchAction(type: ExtendedPunchType) {
    const tenantId = activeTenant?.id
    if (type === 'in' && geoEnabled && tenantId && !hasSeenGeoNotice(tenantId)) {
      setConsentDialogOpen(true)
      return
    }
    setActivePunchType(type)
    punchByType(type)
  }

  if (tenantsLoading || employeeLoading) {
    return (
      <div className="flex h-64 items-center justify-center">
        <div className="h-10 w-10 animate-spin rounded-full border-b-2 border-primary" />
      </div>
    )
  }

  if (!activeTenant) {
    return (
      <div className="mx-auto max-w-lg px-4 py-12 text-center">
        <p className="text-sm text-muted-foreground">
          {t('errors.no_tenant', 'Selecciona una organització per fitxar')}
        </p>
      </div>
    )
  }

  if (employeeError || (!employeeLoading && !myEmployee)) {
    return (
      <div className="mx-auto max-w-lg px-4 py-12">
        <div className="rounded-2xl border border-amber-200 bg-amber-50 p-6 text-center">
          <p className="text-sm font-medium text-amber-800">
            {t('errors.no_employee', "No s'ha trobat cap registre d'empleat associat al teu compte")}
          </p>
        </div>
      </div>
    )
  }

  const showRemote =
    currentStatus === 'outside' ||
    currentStatus === 'working' ||
    currentStatus === 'on_day'
  const showPauses = currentStatus === 'working' || currentStatus === 'on_pause'

  return (
    <div className="mx-auto max-w-lg space-y-8 px-4 py-8">
      <AttendanceTabs />
      <LocationConsentDialog
        open={consentDialogOpen}
        onAccept={handleAcceptConsent}
        onDecline={handleDeclineConsent}
      />
      <PunchDiscrepancyDialog
        open={discrepancyOpen}
        hints={discrepancyHints}
        options={discrepancyOptions}
        isSubmitting={submitDiscrepancy.isPending}
        onSelect={handleDiscrepancySelect}
      />

      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground">{t('title', 'Control horari')}</h1>
          <p className="mt-0.5 text-sm text-muted-foreground">{myEmployee?.full_name}</p>
          <p className="mt-1 text-xs">
            <Link to="/attendance/record?view=month" className="text-primary underline">
              {t('punch.hours_link', 'Com es calculen les meves hores?')}
            </Link>
          </p>
        </div>
        <AttendanceStatusBadge
          status={currentStatus}
          activePauseType={activePauseType}
          isRemote={derivedRemote || isRemote}
        />
      </div>

      <div className="flex items-center gap-2 text-xs">
        {isOnline ? (
          <Wifi className="h-3.5 w-3.5 text-emerald-500" aria-hidden />
        ) : (
          <WifiOff className="h-3.5 w-3.5 text-amber-500" aria-hidden />
        )}
        <span className={isOnline ? 'text-emerald-600' : 'text-amber-600'}>
          {isOnline ? t('sync.status_online', 'Connectat') : t('sync.status_offline', 'Sense connexió')}
        </span>
        {pendingCount > 0 && (
          <span className="ml-2 text-amber-600">
            {t('sync.pending_count_plural', '{{count}} fitxatges pendents', { count: pendingCount })}
          </span>
        )}
        {isSyncing && (
          <span className="ml-2 italic text-muted-foreground">{t('sync.syncing', 'Sincronitzant…')}</span>
        )}
      </div>

      {hasAnomalies && <AnomalyAlert codes={anomalyCodes} />}

      <WorkScheduleStatusCard
        schedule={todaySchedule}
        punches={punches}
        presenceStatus={currentStatus}
        nowMs={now}
      />

      {showPauseNotClosed && openPauseSince && (
        <div className="flex items-start gap-3 rounded-xl border border-red-200 bg-red-50 p-4" role="alert">
          <AlertTriangle className="mt-0.5 h-5 w-5 shrink-0 text-red-500" aria-hidden />
          <div className="flex-1 min-w-0">
            <p className="text-sm font-semibold text-red-800">
              {t('pause.not_closed_title', 'Pausa sense tancar')}
            </p>
            <p className="mt-1 text-xs text-red-700">
              {t('pause.not_closed_desc', 'Pausa oberta des de les {{time}}', {
                time: new Date(openPauseSince).toLocaleTimeString('ca-ES', {
                  hour: '2-digit',
                  minute: '2-digit',
                }),
              })}
            </p>
            <button
              type="button"
              disabled={punchLoading}
              onClick={() => endPause(
                activePauseType,
                t('pause.manual_close_note', 'Tancament manual: pausa no tancada automàticament'),
              )}
              className="mt-3 flex items-center gap-1.5 rounded-md bg-red-700 px-3 py-1.5 text-xs font-semibold text-white hover:bg-red-800 disabled:opacity-60"
            >
              {punchLoading
                ? <Loader2 className="h-3.5 w-3.5 animate-spin" aria-hidden />
                : <Coffee className="h-3.5 w-3.5" aria-hidden />}
              {t('pause.close_manually', 'Tancar pausa manualment')}
            </button>
          </div>
        </div>
      )}

      {showRemote && (currentStatus === 'outside' || currentStatus === 'on_day') && (
        <RemoteWorkSwitch checked={isRemote} disabled={punchLoading} onCheckedChange={setIsRemote} />
      )}

      <PunchDaySchedule
        today={todaySchedule}
        isLoading={scheduleLoading}
        showUpcoming={showUpcoming}
        upcomingDays={upcoming.all}
        isUpcomingLoading={isUpcomingLoading}
      />

      <div className="flex flex-col items-center gap-2 py-4">
        <PunchActionPanel
          currentStatus={currentStatus}
          dayState={dayState}
          isMobileProfile={isMobileProfile}
          legacyInOutOnly={legacyInOutOnly}
          loadingType={activePunchType}
          onPunch={handlePunchAction}
        />
        {isLocating && (
          <p className="flex items-center gap-1.5 text-xs text-muted-foreground">
            <MapPin className="h-3 w-3 opacity-70" aria-hidden />
            {t('punch.locating', 'Obtenint ubicació…')}
          </p>
        )}
      </div>

      {showPauses && (
        pauseConfigsLoading ? (
          <p className="text-center text-xs text-muted-foreground">
            {t('pause.loading', 'Carregant pauses…')}
          </p>
        ) : (
          <PauseButtonGroup
            configs={pauseConfigs}
            activePauseType={activePauseType}
            isLoading={punchLoading}
            onStartPause={startPause}
            onEndPause={() => endPause(activePauseType)}
          />
        )
      )}

      {todayLoading ? (
        <div className="flex justify-center py-4">
          <div className="h-6 w-6 animate-spin rounded-full border-b-2 border-primary" />
        </div>
      ) : (
        <DailyTimeline punches={punches} pendingOps={pendingOps} />
      )}
    </div>
  )
}
