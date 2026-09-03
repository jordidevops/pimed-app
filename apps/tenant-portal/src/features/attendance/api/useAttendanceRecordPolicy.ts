import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import {
  getAttendanceRecordPolicy,
  getCalendarGroupRecordPolicy,
  upsertCalendarGroupRecordPolicy,
} from './recordPolicyService'
import type { AttendanceRecordPolicyV2 } from './recordPolicyTypes'

export const attendanceRecordPolicyQueryKey = (employeeId: string) =>
  ['attendance-record-policy', employeeId] as const

export function useAttendanceRecordPolicy(employeeId: string | undefined) {
  return useQuery({
    queryKey: attendanceRecordPolicyQueryKey(employeeId ?? ''),
    queryFn: () => getAttendanceRecordPolicy(employeeId!),
    enabled: !!employeeId,
  })
}

export function useCalendarGroupRecordPolicy(
  groupId: string | undefined,
  siteId?: string | null,
) {
  return useQuery({
    queryKey: ['calendar-group-record-policy', groupId, siteId ?? null],
    queryFn: () => getCalendarGroupRecordPolicy(groupId!, siteId),
    enabled: !!groupId,
  })
}

export function useUpsertCalendarGroupRecordPolicy() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: upsertCalendarGroupRecordPolicy,
    onSuccess: (_data, vars) => {
      qc.invalidateQueries({
        queryKey: ['calendar-group-record-policy', vars.groupId],
      })
    },
  })
}

export type { AttendanceRecordPolicyV2 }
