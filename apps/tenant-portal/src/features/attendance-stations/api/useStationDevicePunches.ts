import { useQuery } from '@tanstack/react-query'
import {
  fetchStationDevicePunches,
  type FetchStationDevicePunchesParams,
} from './stationHistoryService'

export function stationDevicePunchesQueryKey(params: FetchStationDevicePunchesParams) {
  return [
    'attendance-stations',
    'device-punches',
    params.deviceId,
    params.siteId,
    params.from,
    params.to,
    params.employeeId ?? 'all',
  ] as const
}

export function useStationDevicePunches(
  params: FetchStationDevicePunchesParams | null,
  enabled = true,
) {
  return useQuery({
    queryKey: params
      ? stationDevicePunchesQueryKey(params)
      : (['attendance-stations', 'device-punches', 'idle'] as const),
    queryFn: () => fetchStationDevicePunches(params!),
    enabled: enabled && params != null,
    staleTime: 30_000,
  })
}
