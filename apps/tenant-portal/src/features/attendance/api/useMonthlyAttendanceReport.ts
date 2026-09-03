import { useQuery } from '@tanstack/react-query'
import {
  exportAttendanceMonth,
  fetchMonthlyReportStatus,
} from './monthlyReportService'

export function monthlyReportQueryKey(employeeId: string, year: number, month: number) {
  return ['attendance', 'monthly-report', employeeId, year, month] as const
}

export function useMonthlyAttendanceReport(
  employeeId: string | null | undefined,
  year: number,
  month: number,
  enabled = true,
) {
  return useQuery({
    queryKey: monthlyReportQueryKey(employeeId ?? '', year, month),
    queryFn: async () => {
      const [status, exportData] = await Promise.all([
        fetchMonthlyReportStatus(employeeId!, year, month),
        exportAttendanceMonth(employeeId!, year, month),
      ])
      return { status, export: exportData }
    },
    enabled: enabled && !!employeeId && year > 0 && month >= 1 && month <= 12,
    staleTime: 30_000,
  })
}
