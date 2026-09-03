import { useMemo } from 'react'
import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useSiteAbsences, useAbsenceTypeConfigs } from '../api/useAbsences'
import { madridWorkDate } from '../api/todayDashboardService'

function overlapsToday(startDate: string | null, endDate: string | null, today: string): boolean {
  if (!startDate) return false
  const end = endDate ?? startDate
  return startDate <= today && end >= today
}

export function usePendingAbsencesCount() {
  return useQuery({
    queryKey: ['attendance', 'pending-absences-count'],
    queryFn: async () => {
      const { data, error } = await supabase.rpc(
        'count_pending_absences' as never,
      )
      if (error) throw new Error(error.message)
      return (data as number) ?? 0
    },
    refetchInterval: 60_000,
  })
}

export function useAbsencesTabCounts() {
  const today = madridWorkDate(new Date().toISOString())
  const year = new Date().getFullYear()
  const from = `${year}-01-01`
  const to = `${year + 1}-12-31`

  const { data: absences = [] } = useSiteAbsences(from, to)
  const { data: typeConfigs = [] } = useAbsenceTypeConfigs(true, true)

  return useMemo(() => {
    const typeConfigMap = Object.fromEntries(typeConfigs.map((c) => [c.absence_type, c]))
    const pending = absences.filter((a) => a.status === 'requested').length
    const activeToday = absences.filter(
      (a) => a.status === 'active' && overlapsToday(a.start_date, a.end_date, today),
    ).length
    const activeItToday = absences.filter(
      (a) => a.status === 'active'
        && typeConfigMap[a.absence_type ?? '']?.is_it
        && overlapsToday(a.start_date, a.end_date, today),
    ).length

    return { pending, activeToday, activeItToday }
  }, [absences, typeConfigs, today])
}
