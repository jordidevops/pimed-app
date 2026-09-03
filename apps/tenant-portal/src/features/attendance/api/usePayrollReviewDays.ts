import { useQuery } from '@tanstack/react-query'
import { fetchPayrollReviewDays, payrollReviewDaysQueryKey } from './payrollReviewService'

export function usePayrollReviewDays(
  employeeId: string | null | undefined,
  from: string,
  to: string,
  enabled = true,
) {
  return useQuery({
    queryKey: payrollReviewDaysQueryKey(employeeId ?? '', from, to),
    queryFn: () => fetchPayrollReviewDays(employeeId!, from, to),
    enabled: enabled && !!employeeId && !!from && !!to,
    staleTime: 20_000,
  })
}
