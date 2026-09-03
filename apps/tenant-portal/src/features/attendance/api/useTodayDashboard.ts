import { useEffect } from 'react'
import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useAttendanceEffectiveSite } from '../hooks/useAttendanceEffectiveSite'
import { parseWorkIntervals } from './workIntervals'
import type { TodayDashboardRow } from './todayDashboardService'

const POLL_MS = 10_000

function mapRow(raw: Record<string, unknown>): TodayDashboardRow {
  return {
    employee_id: String(raw.employee_id),
    employee_name: String(raw.employee_name ?? ''),
    day_type: String(raw.day_type ?? 'work'),
    work_intervals: parseWorkIntervals(raw.work_intervals),
    expected_start: raw.expected_start ? String(raw.expected_start).slice(0, 5) : null,
    planned_minutes: Number(raw.planned_minutes ?? 0),
    current_state: (raw.current_state as TodayDashboardRow['current_state']) ?? 'unknown',
    last_punch_type: (raw.last_punch_type as string | null) ?? null,
    last_pause_type: (raw.last_pause_type as string | null) ?? null,
    last_punch_at: (raw.last_punch_at as string | null) ?? null,
    last_is_remote: raw.last_is_remote == null ? null : Boolean(raw.last_is_remote),
    geo_lat: raw.geo_lat == null ? null : Number(raw.geo_lat),
    geo_lng: raw.geo_lng == null ? null : Number(raw.geo_lng),
    geo_accuracy_m: raw.geo_accuracy_m == null ? null : Number(raw.geo_accuracy_m),
    first_in_at: (raw.first_in_at as string | null) ?? null,
    worked_minutes: Number(raw.worked_minutes ?? 0),
    anomaly_codes: (raw.anomaly_codes as string[] | null) ?? null,
    needs_review: Boolean(raw.needs_review),
  }
}

async function fetchTodayDashboard(siteId: string): Promise<TodayDashboardRow[]> {
  const { data, error } = await supabase.rpc('get_today_dashboard_rows' as never, {
    p_site_id: siteId,
  } as never)
  if (error) throw new Error(error.message)
  return ((data ?? []) as Record<string, unknown>[]).map(mapRow)
}

export function useTodayDashboard() {
  const { effectiveSiteId } = useAttendanceEffectiveSite()

  const query = useQuery({
    queryKey: ['attendance', 'today-dashboard', effectiveSiteId],
    queryFn: () => fetchTodayDashboard(effectiveSiteId!),
    enabled: !!effectiveSiteId,
    staleTime: 0,
    gcTime: 60_000,
    refetchInterval: POLL_MS,
    refetchIntervalInBackground: false,
    refetchOnWindowFocus: true,
    refetchOnMount: 'always',
  })

  useEffect(() => {
    if (!effectiveSiteId) return

    function onVisible() {
      if (document.visibilityState === 'visible') {
        void query.refetch()
      }
    }

    document.addEventListener('visibilitychange', onVisible)
    const id = window.setInterval(() => {
      if (document.visibilityState === 'visible') {
        void query.refetch()
      }
    }, POLL_MS)

    return () => {
      document.removeEventListener('visibilitychange', onVisible)
      window.clearInterval(id)
    }
  }, [effectiveSiteId, query.refetch])

  return query
}
