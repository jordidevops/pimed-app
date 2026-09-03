import { useMutation, useQueryClient } from '@tanstack/react-query'
import { approveTimeDay } from './recordsApprovalService'
import { attendanceKeys } from './attendanceKeys'

/** Invalida llistes i detall després d'aprovar un dia (sense dependre del site seleccionat). */
function invalidateAfterDayApproval(
  queryClient: ReturnType<typeof useQueryClient>,
  employeeId: string,
  workDate: string,
) {
  void queryClient.invalidateQueries({
    queryKey: ['attendance', 'day-detail', employeeId, workDate],
  })
  void queryClient.invalidateQueries({
    queryKey: ['attendance', 'payroll-review-days', employeeId],
  })
  void queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
}

export function useApproveTimeDay(_siteId?: string | null) {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: (params: { employeeId: string; workDate: string }) =>
      approveTimeDay(params.employeeId, params.workDate),
    onSuccess: (_result, params) => {
      invalidateAfterDayApproval(queryClient, params.employeeId, params.workDate)
    },
  })
}
