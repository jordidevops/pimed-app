import { useMutation, useQueryClient } from '@tanstack/react-query'
import { invalidateEntityTimelineCaches } from '@/features/entity-timeline/api/invalidateEntityTimelineCaches'
import { approveAttendanceMonth, confirmAttendanceMonth } from './monthlyReportService'
import { monthlyCloseValidationQueryKey } from './monthlyCloseValidationService'
import { monthlyEmployeeConfirmValidationQueryKey } from './monthlyEmployeeConfirmValidationService'
import { periodEmployeeConfirmValidationQueryKey } from './periodEmployeeConfirmValidationService'
import { confirmAttendancePeriod, monthPeriodStatusQueryKey } from './periodConfirmService'
import { monthlyReportQueryKey } from './useMonthlyAttendanceReport'
import { attendanceKeys } from './attendanceKeys'

export function useConfirmAttendanceMonth() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: (params: { employee_id: string; year: number; month: number }) =>
      confirmAttendanceMonth(params.employee_id, params.year, params.month),
    onSuccess: async (_id, params) => {
      await Promise.all([
        queryClient.invalidateQueries({
          queryKey: monthlyReportQueryKey(params.employee_id, params.year, params.month),
        }),
        queryClient.invalidateQueries({
          queryKey: monthlyEmployeeConfirmValidationQueryKey(
            params.employee_id,
            params.year,
            params.month,
          ),
        }),
        queryClient.invalidateQueries({
          queryKey: monthPeriodStatusQueryKey(params.employee_id, params.year, params.month),
        }),
        queryClient.invalidateQueries({ queryKey: attendanceKeys.all }),
        invalidateEntityTimelineCaches(queryClient, 'employee', params.employee_id),
      ])
    },
  })
}

export function useConfirmAttendancePeriod() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: (params: {
      employee_id: string
      period_from: string
      period_to: string
      calendar_year: number
      calendar_month: number
    }) =>
      confirmAttendancePeriod(
        params.employee_id,
        params.period_from,
        params.period_to,
        params.calendar_year,
        params.calendar_month,
      ),
    onSuccess: async (_id, params) => {
      await Promise.all([
        queryClient.invalidateQueries({
          queryKey: monthlyReportQueryKey(
            params.employee_id,
            params.calendar_year,
            params.calendar_month,
          ),
        }),
        queryClient.invalidateQueries({
          queryKey: monthPeriodStatusQueryKey(
            params.employee_id,
            params.calendar_year,
            params.calendar_month,
          ),
        }),
        queryClient.invalidateQueries({
          queryKey: ['attendance', 'month-period-status-batch'],
        }),
        queryClient.invalidateQueries({
          queryKey: periodEmployeeConfirmValidationQueryKey(
            params.employee_id,
            params.period_from,
            params.period_to,
          ),
        }),
        queryClient.invalidateQueries({
          queryKey: monthlyCloseValidationQueryKey(
            params.employee_id,
            params.calendar_year,
            params.calendar_month,
          ),
        }),
        queryClient.invalidateQueries({
          queryKey: monthlyEmployeeConfirmValidationQueryKey(
            params.employee_id,
            params.calendar_year,
            params.calendar_month,
          ),
        }),
        queryClient.invalidateQueries({ queryKey: attendanceKeys.all }),
        invalidateEntityTimelineCaches(queryClient, 'employee', params.employee_id),
      ])
    },
  })
}

export function useApproveAttendanceMonth() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: (params: { employee_id: string; year: number; month: number }) =>
      approveAttendanceMonth(params.employee_id, params.year, params.month),
    onSuccess: async (_id, params) => {
      await Promise.all([
        queryClient.invalidateQueries({
          queryKey: monthlyReportQueryKey(params.employee_id, params.year, params.month),
        }),
        queryClient.invalidateQueries({
          queryKey: monthlyCloseValidationQueryKey(params.employee_id, params.year, params.month),
        }),
        queryClient.invalidateQueries({
          queryKey: monthPeriodStatusQueryKey(params.employee_id, params.year, params.month),
        }),
        queryClient.invalidateQueries({
          queryKey: ['attendance', 'month-period-status-batch'],
        }),
        queryClient.invalidateQueries({ queryKey: attendanceKeys.all }),
        invalidateEntityTimelineCaches(queryClient, 'employee', params.employee_id),
      ])
    },
  })
}
