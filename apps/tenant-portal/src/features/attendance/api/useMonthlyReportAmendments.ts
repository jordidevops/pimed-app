import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { invalidateEntityTimelineCaches } from '@/features/entity-timeline/api/invalidateEntityTimelineCaches'
import {
  fetchMonthlyReportAmendments,
  monthlyReportAmendmentsQueryKey,
  registerMonthlyReportAmendment,
  type RegisterMonthlyAmendmentInput,
} from './monthlyReportAmendmentService'

export function useMonthlyReportAmendments(
  employeeId: string | null | undefined,
  year: number,
  month: number,
  enabled = true,
) {
  return useQuery({
    queryKey: monthlyReportAmendmentsQueryKey(employeeId ?? '', year, month),
    queryFn: () => fetchMonthlyReportAmendments(employeeId!, year, month),
    enabled: !!employeeId && enabled,
    staleTime: 30_000,
  })
}

export function useRegisterMonthlyReportAmendment(
  employeeId: string,
  year: number,
  month: number,
) {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: (input: Omit<RegisterMonthlyAmendmentInput, 'employeeId' | 'year' | 'month'>) =>
      registerMonthlyReportAmendment({ ...input, employeeId, year, month }),
    onSuccess: async () => {
      await Promise.all([
        queryClient.invalidateQueries({
          queryKey: monthlyReportAmendmentsQueryKey(employeeId, year, month),
        }),
        invalidateEntityTimelineCaches(queryClient, 'employee', employeeId),
      ])
    },
  })
}
