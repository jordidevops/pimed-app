import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  createStationPairingCode,
  listAttendanceStations,
  revokeAttendanceStationSecret,
  updateAttendanceStation,
} from './attendanceStationsService'
import {
  bulkRevokeAttendanceStationSecrets,
  bulkUpdateAttendanceStationOps,
  getStationFleetHealth,
} from './stationFleetService'

export function useAttendanceStations() {
  return useQuery({
    queryKey: ['attendance-stations'],
    queryFn: listAttendanceStations,
  })
}

export function useStationFleetHealth(tenantId: string | null | undefined, enabled = true) {
  return useQuery({
    queryKey: ['attendance-stations', 'fleet-health', tenantId ?? ''],
    queryFn: () => getStationFleetHealth(tenantId),
    enabled: enabled && !!tenantId,
    staleTime: 30_000,
    refetchInterval: 60_000,
  })
}

export function useCreateStationPairingCode() {
  return useMutation({
    mutationFn: createStationPairingCode,
  })
}

export function useUpdateAttendanceStation() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: updateAttendanceStation,
    onSuccess: async () => {
      await qc.invalidateQueries({ queryKey: ['attendance-stations'] })
    },
  })
}

export function useBulkUpdateAttendanceStationOps() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: bulkUpdateAttendanceStationOps,
    onSuccess: async () => {
      await qc.invalidateQueries({ queryKey: ['attendance-stations'] })
    },
  })
}

export function useBulkRevokeAttendanceStationSecrets() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: bulkRevokeAttendanceStationSecrets,
    onSuccess: async () => {
      await qc.invalidateQueries({ queryKey: ['attendance-stations'] })
    },
  })
}

export function useRevokeStationSecret() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: revokeAttendanceStationSecret,
    onSuccess: async () => {
      await qc.invalidateQueries({ queryKey: ['attendance-stations'] })
    },
  })
}
