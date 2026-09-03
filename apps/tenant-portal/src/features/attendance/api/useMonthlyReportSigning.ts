import { useMutation, useQueryClient } from '@tanstack/react-query'
import { monthlyReportQueryKey } from './useMonthlyAttendanceReport'
import type { MonthlyReportExport } from './monthlyReportService'
import {
  startMonthlyReportSigning,
} from './monthlyReportSigningService'
import type { SignDocumentResult } from '@/features/signing/api/signingService'

export function useMonthlyReportSigning(
  employeeId: string,
  year: number,
  month: number,
) {
  const queryClient = useQueryClient()

  return useMutation<
    SignDocumentResult,
    Error,
    {
      tenantId: string
      userId: string
      exportData: MonthlyReportExport
      contentHash?: string | null
      employeeEmail?: string | null
      managerEmail?: string | null
      managerName?: string | null
    }
  >({
    mutationFn: (params) =>
      startMonthlyReportSigning({
        tenantId: params.tenantId,
        userId: params.userId,
        employeeId,
        year,
        month,
        exportData: params.exportData,
        contentHash: params.contentHash,
        employeeEmail: params.employeeEmail,
        managerEmail: params.managerEmail,
        managerName: params.managerName,
      }),
    onSuccess: () => {
      void queryClient.invalidateQueries({
        queryKey: monthlyReportQueryKey(employeeId, year, month),
      })
    },
  })
}
