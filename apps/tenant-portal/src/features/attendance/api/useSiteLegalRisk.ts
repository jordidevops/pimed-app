import { useQuery } from '@tanstack/react-query'
import { fetchSiteLegalRiskEmployees } from './legalCountersService'

export function useSiteLegalRisk(
  siteId: string | null | undefined,
  thresholdPct = 80,
  enabled = true,
) {
  return useQuery({
    queryKey: ['attendance', 'legal-risk', siteId, thresholdPct],
    queryFn: () => fetchSiteLegalRiskEmployees(siteId!, thresholdPct),
    enabled: !!siteId && enabled,
    staleTime: 120_000,
  })
}
