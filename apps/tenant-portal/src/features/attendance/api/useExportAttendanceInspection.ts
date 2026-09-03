import { useMutation } from '@tanstack/react-query'
import {
  downloadInspectionExport,
  exportAttendanceInspection,
  type InspectionExportPayload,
} from './recordsApprovalService'

export function useExportAttendanceInspection() {
  return useMutation({
    mutationFn: (params: {
      siteId: string
      from: string
      to: string
      employeeId?: string
    }) => exportAttendanceInspection(params),
  })
}

export function downloadInspection(
  payload: InspectionExportPayload,
  format: 'csv' | 'json',
  csvHeaders: Record<string, string>,
): void {
  downloadInspectionExport(payload, format, csvHeaders)
}
