import { useState, useCallback } from 'react'
import { useTranslation } from 'react-i18next'
import { useToast } from '@/hooks/use-toast'
import { queryClient } from '@/lib/react-query'
import {
  recordTimePunch,
  generateClientOpId,
  type RecordPunchParams,
} from '../api/attendanceService'
import { savePunchOpLocally } from '../db/attendanceDb'
import { captureGeoLocation, buildDeviceInfo } from '../api/geoService'
import type { ExtendedPunchType } from '../utils/punchProfileUi'
import type { PauseConfig } from '../api/usePauseConfigs'
import type { PunchRecordedContext } from '../api/punchDiscrepancyService'

interface UseRecordPunchOptions {
  employeeId: string
  tenantId: string
  userId: string
  isOnline: boolean
  geoConsent: boolean
  /** Cascada E4: si false, no es captura ni desa geo. */
  geoEnabled?: boolean
  /** Intenta capturar GPS quan geoEnabled i encara sense consentiment RRHH */
  geoCaptureOptional?: boolean
  isRemote: boolean
  onSuccess: () => void
  onOfflineQueued: () => void
  /** E5: després d'un fitxatge online creat (in/out). */
  onPunchRecorded?: (ctx: PunchRecordedContext) => void
}

export function useRecordPunch({
  employeeId,
  tenantId,
  userId,
  isOnline,
  geoConsent,
  geoEnabled = true,
  geoCaptureOptional = true,
  isRemote,
  onSuccess,
  onOfflineQueued,
  onPunchRecorded,
}: UseRecordPunchOptions) {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const [isLoading, setIsLoading] = useState(false)
  const [isLocating, setIsLocating] = useState(false)

  const executePunch = useCallback(
    async (params: Omit<RecordPunchParams, 'employee_id' | 'client_op_id'>) => {
      if (isLoading) return
      setIsLoading(true)

      const clientOpId = generateClientOpId()
      const occurredAt = new Date().toISOString()

      let geoResult: {
        geo: RecordPunchParams['geo']
        locationPermission: NonNullable<RecordPunchParams['location_permission']>
        geoError: string | null
      } = {
        geo: null,
        locationPermission: 'notrequired',
        geoError: null,
      }

      if (geoEnabled && (geoConsent || geoCaptureOptional)) {
        setIsLocating(true)
        try {
          const captured = await captureGeoLocation()
          geoResult = {
            geo: captured.geo,
            locationPermission: captured.locationPermission,
            geoError: captured.geoError,
          }
        } finally {
          setIsLocating(false)
        }
      }

      const basePayload: RecordPunchParams = {
        ...params,
        employee_id: employeeId,
        client_op_id: clientOpId,
        occurred_at: occurredAt,
        geo: geoResult.geo,
        location_permission: geoResult.locationPermission,
        geo_consent: geoConsent,
        geo_error: geoResult.geoError,
        device_info: buildDeviceInfo(),
        is_remote: params.is_remote ?? isRemote,
        source: 'mobile',
      }

      try {
        if (!isOnline) {
          await savePunchOpLocally({
            client_op_id: clientOpId,
            punch_type: params.punch_type,
            employee_id: employeeId,
            tenant_id: tenantId,
            user_id: userId,
            occurred_at: occurredAt,
            geo: geoResult.geo,
            location_permission: geoResult.locationPermission,
            notes: params.notes ?? null,
            source: 'mobile',
            pause_type: params.pause_type,
            pause_counts_as_work: params.pause_counts_as_work,
            is_remote: basePayload.is_remote,
            geo_consent: geoConsent,
            geo_error: geoResult.geoError,
            device_info: basePayload.device_info,
          })
          toast({
            title: t('punch.offline_queued', 'Fitxatge desat localment'),
            description: t(
              'punch.offline_queued_desc',
              'Es sincronitzarà quan recuperis la connexió.',
            ),
          })
          onOfflineQueued()
          return
        }

        const result = await recordTimePunch(basePayload)
        if (result.success) {
          void queryClient.invalidateQueries({ queryKey: ['attendance', 'today-dashboard'] })
          onSuccess()
          if (
            result.status === 'created'
            && (params.punch_type === 'in' || params.punch_type === 'out')
            && result.punch_id
          ) {
            onPunchRecorded?.({
              punchType: params.punch_type,
              punchId: result.punch_id,
              anomalyCodes: result.anomaly_codes ?? [],
              occurredAt: occurredAt,
              hadGeo: geoResult.geo != null,
              status: result.status,
            })
          }
        } else {
          toast({
            variant: 'destructive',
            title: t('punch.error', 'Error en registrar el fitxatge'),
            description: result.error,
          })
        }
      } catch (err) {
        // EX-05.1: fallada de xarxa → cua amb el mateix client_op_id (estable)
        const isNetwork =
          err instanceof TypeError
          || (err instanceof Error && /failed to fetch|network|offline/i.test(err.message))
        if (isNetwork) {
          try {
            await savePunchOpLocally({
              client_op_id: clientOpId,
              punch_type: params.punch_type,
              employee_id: employeeId,
              tenant_id: tenantId,
              user_id: userId,
              occurred_at: occurredAt,
              geo: geoResult.geo,
              location_permission: geoResult.locationPermission,
              notes: params.notes ?? null,
              source: 'mobile',
              pause_type: params.pause_type,
              pause_counts_as_work: params.pause_counts_as_work,
              is_remote: basePayload.is_remote,
              geo_consent: geoConsent,
              geo_error: geoResult.geoError,
              device_info: basePayload.device_info,
            })
            toast({
              title: t('punch.offline_queued', 'Fitxatge desat localment'),
              description: t(
                'punch.offline_queued_desc',
                'Es sincronitzarà quan recuperis la connexió.',
              ),
            })
            onOfflineQueued()
            return
          } catch {
            // fall through to error toast
          }
        }
        toast({
          variant: 'destructive',
          title: t('punch.error', 'Error en registrar el fitxatge'),
        })
      } finally {
        setIsLoading(false)
      }
    },
    [
      employeeId,
      tenantId,
      userId,
      isOnline,
      geoConsent,
      geoEnabled,
      geoCaptureOptional,
      isRemote,
      isLoading,
      onSuccess,
      onOfflineQueued,
      onPunchRecorded,
      t,
      toast,
    ],
  )

  const punchIn = () => executePunch({ punch_type: 'in', is_remote: isRemote })
  const punchOut = () => executePunch({ punch_type: 'out' })
  const punchDayStart = () => executePunch({ punch_type: 'day_start' })
  const punchDayEnd = () => executePunch({ punch_type: 'day_end' })
  const punchTravelStart = () => executePunch({ punch_type: 'travel_start' })
  const punchTravelEnd = () => executePunch({ punch_type: 'travel_end' })
  const punchByType = (type: ExtendedPunchType) => {
    if (type === 'in') return punchIn()
    if (type === 'out') return punchOut()
    if (type === 'day_start') return punchDayStart()
    if (type === 'day_end') return punchDayEnd()
    if (type === 'travel_start') return punchTravelStart()
    if (type === 'travel_end') return punchTravelEnd()
  }
  const startPause = (config: PauseConfig) =>
    executePunch({
      punch_type: 'break_start',
      pause_type: config.key,
      pause_counts_as_work: config.counts_as_work,
    })
  const endPause = (pauseType: string | null, notes?: string) =>
    executePunch({
      punch_type: 'break_end',
      pause_type: pauseType ?? undefined,
      notes,
    })

  return {
    isLoading,
    isLocating,
    punchIn,
    punchOut,
    punchDayStart,
    punchDayEnd,
    punchTravelStart,
    punchTravelEnd,
    punchByType,
    startPause,
    endPause,
    executePunch,
  }
}
