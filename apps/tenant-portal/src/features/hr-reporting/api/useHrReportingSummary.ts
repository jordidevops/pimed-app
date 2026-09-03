import { useQuery } from '@tanstack/react-query'
import { useTenant } from '@/contexts/TenantContext'
import { getHrReportingSummary } from './hrReportingService'

export function useHrReportingSummary(filters?: {
  asOf?: string | null
  periodDays?: number
  siteId?: string | null
  departmentId?: string | null
}) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: [
      'hr-reporting-summary',
      activeTenant?.id ?? '',
      filters?.asOf ?? '',
      filters?.periodDays ?? 30,
      filters?.siteId ?? '',
      filters?.departmentId ?? '',
    ],
    enabled: !!activeTenant?.id,
    queryFn: () =>
      getHrReportingSummary({
        asOf: filters?.asOf,
        periodDays: filters?.periodDays ?? 30,
        siteId: filters?.siteId,
        departmentId: filters?.departmentId,
      }),
    staleTime: 30_000,
  })
}
