import { useQuery } from '@tanstack/react-query'
import { fetchSitePunchesInRange, type FetchSitePunchesParams } from './punchExportService'

export function sitePunchesQueryKey(params: FetchSitePunchesParams) {
  return [
    'attendance',
    'site-punches',
    params.siteId,
    params.from,
    params.to,
    params.employeeId ?? 'all',
    params.locationId ?? 'all',
    params.deviceId ?? 'all',
  ] as const
}

export function useSitePunches(
  params: FetchSitePunchesParams | null,
  enabled = true,
) {
  return useQuery({
    queryKey: params
      ? sitePunchesQueryKey(params)
      : (['attendance', 'site-punches', 'disabled'] as const),
    queryFn: () => fetchSitePunchesInRange(params!),
    enabled: enabled && params != null,
    staleTime: 30_000,
  })
}
