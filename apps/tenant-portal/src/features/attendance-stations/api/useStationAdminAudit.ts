import { useQuery } from '@tanstack/react-query'
import { listStationAdminAuditLogs } from './stationAdminAuditService'

export function stationAdminAuditQueryKey(deviceId: string) {
  return ['attendance-stations', 'admin-audit', deviceId] as const
}

export function useStationAdminAudit(deviceId: string | null, enabled = true) {
  return useQuery({
    queryKey: deviceId
      ? stationAdminAuditQueryKey(deviceId)
      : (['attendance-stations', 'admin-audit', 'idle'] as const),
    queryFn: () => listStationAdminAuditLogs(deviceId!),
    enabled: enabled && deviceId != null,
    staleTime: 30_000,
  })
}
