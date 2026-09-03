import { useMutation } from '@tanstack/react-query'
import {
  downloadPayrollExport,
  exportPayrollPeriod,
  type PayrollExportFormat,
  type PayrollExportPayload,
} from './payrollExportService'

export function useExportPayrollPeriod() {
  return useMutation({
    mutationFn: (params: {
      siteId: string
      from: string
      to: string
      employeeId?: string
      format?: PayrollExportFormat
    }) => exportPayrollPeriod(params),
  })
}

export function downloadPayroll(
  payload: PayrollExportPayload,
  format: 'csv' | 'json',
  csvHeaders: Record<string, string>,
): void {
  downloadPayrollExport(payload, format, csvHeaders)
}
