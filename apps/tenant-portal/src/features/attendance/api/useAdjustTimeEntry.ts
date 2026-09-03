import { useMutation, useQueryClient } from '@tanstack/react-query'
import { adjustTimeEntry, type AdjustTimeEntryParams } from '../api/attendanceService'
import { attendanceKeys } from '../api/attendanceKeys'

export function useAdjustTimeEntry(siteId: string | null) {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: (params: AdjustTimeEntryParams) => adjustTimeEntry(params),
    onSuccess: (_result, params) => {
      void queryClient.invalidateQueries({
        queryKey: ['attendance', 'day-detail', params.employee_id, params.work_date],
      })
      void queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
    },
  })
}
