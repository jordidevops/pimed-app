import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useMemo } from 'react'
import { attendanceKeys } from './attendanceKeys'
import { getTodayPunches, getTodayEntries } from './attendanceService'
import type { TimePunch, TimeEntry } from './attendanceService'
import {
  computePunchDayState,
  derivePunchUiFromPunches,
  isLegacyInOutOnly,
  type CurrentPunchStatus,
  type PunchDayState,
} from '../utils/punchProfileUi'
import type { WorkProfile } from './recordPolicyTypes'

export type { CurrentPunchStatus, PunchDayState }

export interface AttendanceTodayData {
  punches: TimePunch[]
  entries: TimeEntry[]
  lastPunch: TimePunch | null
  currentStatus: CurrentPunchStatus
  dayState: PunchDayState
  activePauseType: string | null
  openPauseSince: string | null
  hasAnomalies: boolean
  anomalyCodes: string[]
  isRemote: boolean
}

export interface UseMyAttendanceTodayOptions {
  workProfile?: WorkProfile | string | null
  legacyInOutOnly?: boolean
}

export function useMyAttendanceToday(
  employeeId: string | null | undefined,
  options: UseMyAttendanceTodayOptions = {},
) {
  const queryClient = useQueryClient()

  const punchesQuery = useQuery<TimePunch[]>({
    queryKey: attendanceKeys.todayPunches(employeeId ?? ''),
    queryFn: () => getTodayPunches(employeeId!),
    enabled: !!employeeId,
    refetchInterval: 60 * 1000,
    staleTime: 30 * 1000,
  })

  const entriesQuery = useQuery<TimeEntry[]>({
    queryKey: attendanceKeys.todayEntries(employeeId ?? ''),
    queryFn: () => getTodayEntries(employeeId!),
    enabled: !!employeeId,
    refetchInterval: 60 * 1000,
    staleTime: 30 * 1000,
  })

  const data = useMemo<AttendanceTodayData>(() => {
    const punches = punchesQuery.data ?? []
    const entries = entriesQuery.data ?? []
    const workProfile = options.workProfile ?? 'fixed_site'
    const legacy = options.legacyInOutOnly ?? isLegacyInOutOnly(workProfile)
    const derived = derivePunchUiFromPunches(punches, workProfile, legacy)
    const { status, activePauseType, openPauseSince, dayState } = derived
    const lastPunch = punches.length > 0 ? punches[punches.length - 1]! : null

    const allAnomalies = new Set<string>()
    for (const p of punches) {
      for (const code of p.anomaly_codes ?? []) allAnomalies.add(code)
    }
    for (const e of entries) {
      if (e.status === 'anomaly') allAnomalies.add('ENTRY_ANOMALY')
    }

    const anomalyCodes = [...allAnomalies]
    const lastRemote = [...punches].reverse().find((p) => p.punch_type === 'in')
    const dayEnded =
      computePunchDayState(punches) === 'off' && punches.some((p) => p.punch_type === 'day_end')
    const isRemote = Boolean(
      (lastRemote as TimePunch & { is_remote?: boolean })?.is_remote &&
        status !== 'outside' &&
        !dayEnded,
    )

    return {
      punches,
      entries,
      lastPunch,
      currentStatus: status,
      dayState,
      activePauseType,
      openPauseSince,
      hasAnomalies: anomalyCodes.length > 0,
      anomalyCodes,
      isRemote,
    }
  }, [punchesQuery.data, entriesQuery.data, options.workProfile, options.legacyInOutOnly])

  function invalidateToday() {
    if (!employeeId) return
    queryClient.invalidateQueries({ queryKey: attendanceKeys.todayPunches(employeeId) })
    queryClient.invalidateQueries({ queryKey: attendanceKeys.todayEntries(employeeId) })
    queryClient.invalidateQueries({ queryKey: ['attendance', 'my-punches', employeeId] })
    queryClient.invalidateQueries({ queryKey: ['attendance', 'my-entries', employeeId] })
    queryClient.invalidateQueries({ queryKey: ['attendance', 'my-work-day', employeeId] })
    queryClient.invalidateQueries({ queryKey: ['attendance', 'my-work-days-upcoming', employeeId] })
  }

  return {
    ...data,
    isLoading: punchesQuery.isLoading || entriesQuery.isLoading,
    error: punchesQuery.error || entriesQuery.error,
    invalidateToday,
  }
}
