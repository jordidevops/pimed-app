import { useQuery } from '@tanstack/react-query'
import { useMemo } from 'react'
import { attendanceKeys } from './attendanceKeys'
import {
  addDaysIso,
  fetchResolveWorkDay,
  isNearOrPastScheduleEnd,
  isWorkLaborDay,
  type ResolvedWorkDay,
} from './workDayResolveService'
import { toLocalIsoDate } from './schedulePlannerService'

const UPCOMING_SCAN_DAYS = 14

export interface UseMyPunchScheduleOptions {
  /** Sortida registrada avui → mostrar propers dies. */
  punchedOutToday?: boolean
  /** Timestamp actual (per detectar fi de torn sense sortida). */
  nowMs?: number
}

export function useMyPunchSchedule(
  employeeId: string | null | undefined,
  options?: UseMyPunchScheduleOptions,
) {
  const todayIso = toLocalIsoDate(new Date())
  const nowMs = options?.nowMs ?? Date.now()
  const punchedOutToday = Boolean(options?.punchedOutToday)

  const todayQuery = useQuery({
    queryKey: attendanceKeys.myWorkDay(employeeId ?? '', todayIso),
    queryFn: () => fetchResolveWorkDay(employeeId!, todayIso),
    enabled: !!employeeId,
    staleTime: 5 * 60_000,
  })

  const today = todayQuery.data ?? null

  const showUpcoming = useMemo(() => {
    if (!today) return false
    if (punchedOutToday) return true
    if (isWorkLaborDay(today) && today.intervals.length > 0) {
      return isNearOrPastScheduleEnd(today.intervals, new Date(nowMs))
    }
    return false
  }, [today, punchedOutToday, nowMs])

  const upcomingQuery = useQuery({
    queryKey: attendanceKeys.myWorkDaysUpcoming(employeeId ?? '', todayIso),
    queryFn: async (): Promise<ResolvedWorkDay[]> => {
      const dates = Array.from({ length: UPCOMING_SCAN_DAYS }, (_, i) =>
        addDaysIso(todayIso, i + 1),
      )
      return Promise.all(dates.map((date) => fetchResolveWorkDay(employeeId!, date)))
    },
    enabled: !!employeeId && showUpcoming,
    staleTime: 5 * 60_000,
  })

  const upcoming = useMemo(() => {
    const days = upcomingQuery.data ?? []
    const tomorrow = days[0] ?? null
    const nextWorkDay = days.find((d) => isWorkLaborDay(d)) ?? null
    const nextWorkDayAfterTomorrow =
      days.slice(1).find((d) => isWorkLaborDay(d)) ?? null
    return { tomorrow, nextWorkDay, nextWorkDayAfterTomorrow, all: days }
  }, [upcomingQuery.data])

  return {
    today,
    todayIso,
    upcoming,
    showUpcoming,
    isLoading: todayQuery.isLoading,
    isUpcomingLoading: upcomingQuery.isLoading,
  }
}
