import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { useTenant } from '@/contexts/TenantContext'
import { useToast } from '@/hooks/use-toast'
import { attendanceKeys } from './attendanceKeys'
import {
  getWorkShifts,
  createWorkShift,
  updateWorkShift,
  deactivateWorkShift,
  getShiftSlots,
  getMyShiftSlots,
  getSiteEmployees,
  getTenantEmployees,
  getCoverageForPeriod,
  assignShiftSlot,
  bulkDeleteShiftSlots,
  publishShifts,
  preflightPublishShifts,
  type AssignShiftSlotResult,
  type PublishShiftsResult,
  type PreflightPublishResult,
  getSiteHolidays,
  getHolidayCoverageInfo,
  getCalendarHolidays,
  getHolidayCalendars,
  getSiteHolidayCalendarAssignments,
  getTenantHolidayCalendarAssignments,
  getAllTimeDailySummaries,
  assignHolidayCalendarToSite,
  removeHolidayCalendarFromSite,
  assignHolidayCalendarToTenant,
  removeTenantHolidayCalendarAssignment,
  importNagerHolidays,
  createHolidayCalendar,
  deleteHolidayCalendar,
  createHoliday,
  updateHoliday,
  deleteHoliday,
  getSiteHolidayExclusions,
  toggleSiteHolidayExclusion,
  type SiteHolidayExclusion,
  getCalendarGroupWeeklyPattern,
  setCalendarGroupWeeklyDay,
  clearCalendarGroupWeeklyDay,
  getEmployeeWeeklyPattern,
  setEmployeeWeeklyDay,
  clearEmployeeWeeklyDay,
  type WeeklyDayPattern,
} from './shiftsService'

// ─── Work Shifts (templates) ─────────────────────────────────────────────────

export function useWorkShifts() {
  const { selectedSiteId } = useTenant()
  return useQuery({
    queryKey: attendanceKeys.workShifts(selectedSiteId),
    queryFn: () => getWorkShifts(selectedSiteId),
    staleTime: 5 * 60 * 1000,
  })
}

export function useCreateWorkShift() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const { selectedSiteId } = useTenant()

  return useMutation({
    mutationFn: (params: {
      name: string
      start_time: string
      end_time: string
      color?: string
      default_role_id?: string | null
    }) => {
      if (!selectedSiteId) throw new Error(t('shifts.no_site', 'Selecciona un centre'))
      return createWorkShift({ site_id: selectedSiteId, ...params })
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
      toast({ title: t('shifts.template_saved', 'Plantilla desada') })
    },
    onError: (err: Error) => {
      toast({
        title: t('shifts.template_save_error', 'Error en desar la plantilla'),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

export function useUpdateWorkShift() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: updateWorkShift,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
      toast({ title: t('shifts.template_saved', 'Plantilla desada') })
    },
    onError: (err: Error) => {
      toast({
        title: t('shifts.template_save_error', 'Error en desar la plantilla'),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

export function useDeactivateWorkShift() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: deactivateWorkShift,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
      toast({ title: t('shifts.template_deactivated', 'Plantilla desactivada') })
    },
    onError: (err: Error) => {
      toast({
        title: t('shifts.template_deactivate_error', 'Error en desactivar la plantilla'),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

// ─── Site Employees ───────────────────────────────────────────────────────────

export function useSiteEmployees() {
  const { selectedSiteId } = useTenant()
  return useQuery({
    queryKey: attendanceKeys.siteEmployees(selectedSiteId ?? ''),
    queryFn: () => getSiteEmployees(selectedSiteId!),
    enabled: !!selectedSiteId,
    staleTime: 5 * 60 * 1000,
  })
}

export function useSiteEmployeesForSite(siteId: string | null | undefined) {
  return useQuery({
    queryKey: attendanceKeys.siteEmployees(siteId ?? ''),
    queryFn: () => getSiteEmployees(siteId!),
    enabled: !!siteId,
    staleTime: 5 * 60 * 1000,
  })
}

/** Tots els empleats actius del tenant, independentment del local seleccionat. */
export function useTenantEmployees() {
  return useQuery({
    queryKey: ['attendance', 'tenant-employees'],
    queryFn: getTenantEmployees,
    staleTime: 5 * 60 * 1000,
  })
}

// ─── Shift Slots (site planner) ───────────────────────────────────────────────

export function useShiftSlots(from: string, to: string) {
  const { selectedSiteId } = useTenant()
  return useQuery({
    queryKey: attendanceKeys.shiftSlots(selectedSiteId ?? '', from, to),
    queryFn: () => getShiftSlots(selectedSiteId!, from, to),
    enabled: !!selectedSiteId && !!from && !!to,
  })
}

// ─── Shift Slots (employee calendar) ─────────────────────────────────────────

export function useMyShiftSlots(employeeId: string | null, from: string, to: string) {
  return useQuery({
    queryKey: attendanceKeys.myShiftSlots(employeeId ?? '', from, to),
    queryFn: () => getMyShiftSlots(employeeId!, from, to),
    enabled: !!employeeId && !!from && !!to,
  })
}

// ─── Coverage (site planner) ─────────────────────────────────────────────────

export function useCoverageForPeriod(from: string, to: string) {
  const { selectedSiteId } = useTenant()
  return useQuery({
    queryKey: attendanceKeys.coverage(selectedSiteId ?? '', from, to),
    queryFn: () => getCoverageForPeriod(selectedSiteId!, from, to),
    enabled: !!selectedSiteId && !!from && !!to,
  })
}

// ─── Assign Shift Slot ────────────────────────────────────────────────────────

function isDuplicateShiftSlotError(err: unknown): boolean {
  if (!err || typeof err !== 'object') return false
  const e = err as { code?: string; message?: string; details?: string }
  if (e.code === '23505') return true
  const text = `${e.message ?? ''} ${e.details ?? ''}`
  return text.includes('idx_shift_slots_no_dup') || text.includes('already exists')
}

export function useAssignShiftSlot() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: assignShiftSlot,
    onSuccess: (data: AssignShiftSlotResult) => {
      queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
      const anomalies = data.anomalies ?? []
      if (anomalies.length > 0) {
        const labels = anomalies.map((code) => {
          if (code === 'SHIFT_OVERLAP') {
            return t('shifts.anomaly_overlap', 'Solapament de torns')
          }
          if (code === 'WEEKLY_HOURS_EXCEEDED') {
            return t('shifts.anomaly_hours', 'Hores setmanals superades')
          }
          return code
        })
        toast({
          title: t('shifts.assign_with_warnings', 'Torn assignat amb avisos'),
          description: labels.join(' · '),
          variant: 'destructive',
        })
        return
      }
      toast({ title: t('shifts.assign_success', 'Torn assignat correctament') })
    },
    onError: (err: Error) => {
      if (isDuplicateShiftSlotError(err)) {
        toast({
          title: t('shifts.assign_duplicate_title', 'Aquest torn ja està assignat'),
          description: t(
            'shifts.assign_duplicate_desc',
            'Aquest empleat ja té la mateixa plantilla aquest dia. Tria una altra plantilla o un altre dia.',
          ),
          variant: 'destructive',
        })
        return
      }
      toast({
        title: t('shifts.assign_error', 'Error en assignar el torn'),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}


// ─── Delete Shift Slots ───────────────────────────────────────────────────────

export function useDeleteShiftSlots() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: bulkDeleteShiftSlots,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
      toast({ title: t('shifts.delete_success', 'Torn eliminat') })
    },
    onError: (err: Error) => {
      toast({
        title: t('shifts.delete_error', 'Error en eliminar el torn'),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

// ─── Publish Shifts ───────────────────────────────────────────────────────────

export function usePreflightPublishShifts() {
  const { selectedSiteId } = useTenant()
  return useMutation({
    mutationFn: (weekStart: string): Promise<PreflightPublishResult> => {
      if (!selectedSiteId) throw new Error('site required')
      return preflightPublishShifts(selectedSiteId, weekStart)
    },
  })
}

export function usePublishShifts() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const { selectedSiteId } = useTenant()

  return useMutation({
    mutationFn: ({
      weekStart,
      warningsAccepted = [],
    }: {
      weekStart: string
      warningsAccepted?: string[]
    }): Promise<PublishShiftsResult> =>
      publishShifts(selectedSiteId!, weekStart, warningsAccepted),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
      const counts = data.diff?.counts
      const diffHint = counts
        ? t('shifts.publish_diff_hint', '+{{added}} / −{{removed}} / ~{{changed}}', {
            added: counts.added,
            removed: counts.removed,
            changed: counts.changed,
          })
        : undefined
      toast({
        title: t('shifts.publish_success', 'Setmana publicada correctament'),
        description: diffHint,
      })
    },
    onError: (err: Error) => {
      toast({
        title: t('shifts.publish_error', 'Error en publicar la setmana'),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

// ─── Site Holidays ────────────────────────────────────────────────────────────

export function useSiteHolidays(siteId: string | null, from: string, to: string) {
  const { selectedTenantId } = useTenant()
  return useQuery({
    queryKey: attendanceKeys.siteHolidays(`${selectedTenantId ?? 'no-tenant'}:${siteId ?? 'none'}`, from, to),
    queryFn: () => getSiteHolidays(selectedTenantId!, siteId, from, to),
    enabled: !!selectedTenantId && !!from && !!to,
    staleTime: 60 * 60 * 1000, // 1 hour — holidays change rarely
  })
}

export function useHolidayCoverage(siteId: string | null) {
  const { selectedTenantId } = useTenant()
  return useQuery({
    queryKey: attendanceKeys.holidayCoverage(`${selectedTenantId ?? 'no-tenant'}:${siteId ?? 'none'}`),
    queryFn: () => getHolidayCoverageInfo(selectedTenantId!, siteId),
    enabled: !!selectedTenantId,
    staleTime: 60 * 60 * 1000,
  })
}

export function useCalendarHolidays(calendarId: string | null, year: number, enabled = true) {
  const from = `${year}-01-01`
  const to = `${year}-12-31`
  return useQuery({
    queryKey: attendanceKeys.calendarHolidays(calendarId ?? '', from, to),
    queryFn: () => getCalendarHolidays(calendarId!, from, to),
    enabled: !!calendarId && enabled,
    staleTime: 5 * 60 * 1000,
  })
}

// ─── Holiday Calendars (setup) ────────────────────────────────────────────────

export function useHolidayCalendars() {
  const { selectedTenantId } = useTenant()
  return useQuery({
    queryKey: attendanceKeys.holidayCalendars(selectedTenantId ?? ''),
    queryFn: () => getHolidayCalendars(selectedTenantId!),
    enabled: !!selectedTenantId,
    staleTime: 5 * 60 * 1000,
  })
}

export function useSiteHolidayCalendarAssignments() {
  const { selectedSiteId } = useTenant()
  return useQuery({
    queryKey: attendanceKeys.siteHolidayCalendarAssignments(selectedSiteId ?? ''),
    queryFn: () => getSiteHolidayCalendarAssignments(selectedSiteId!),
    enabled: !!selectedSiteId,
    staleTime: 5 * 60 * 1000,
  })
}

export function useAssignHolidayCalendar() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const { selectedSiteId } = useTenant()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (calendarId: string) => {
      if (!selectedSiteId) {
        throw new Error(t('setup.site_required', 'Selecciona un centre per assignar el calendari'))
      }
      return assignHolidayCalendarToSite(selectedSiteId, calendarId)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
      toast({ title: t('setup.assign_success', 'Calendari assignat correctament') })
    },
    onError: (err: Error) => {
      toast({
        title: t('setup.assign_error', 'Error en assignar el calendari'),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

export function useRemoveHolidayCalendarFromSite() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: (assignmentId: string) => removeHolidayCalendarFromSite(assignmentId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
      toast({ title: t('setup.remove_success', 'Calendari eliminat del centre') })
    },
    onError: (err: Error) => {
      toast({
        title: t('setup.remove_error', 'Error en eliminar el calendari'),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

// ─── Tenant Holiday Calendar Assignments ─────────────────────────────────────

export function useTenantHolidayCalendarAssignments() {
  const { selectedTenantId } = useTenant()
  return useQuery({
    queryKey: attendanceKeys.tenantHolidayCalendarAssignments(selectedTenantId ?? ''),
    queryFn: () => getTenantHolidayCalendarAssignments(selectedTenantId!),
    enabled: !!selectedTenantId,
    staleTime: 5 * 60 * 1000,
  })
}

export function useAssignHolidayCalendarToTenant() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const { selectedTenantId } = useTenant()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (calendarId: string) => {
      if (!selectedTenantId) {
        throw new Error(t('setup.tenant_required', 'No hi ha tenant actiu'))
      }
      return assignHolidayCalendarToTenant(selectedTenantId, calendarId)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
      toast({ title: t('setup.tenant_assign_success', 'Calendari assignat al tenant') })
    },
    onError: (err: Error) => {
      toast({
        title: t('setup.tenant_assign_error', 'Error en assignar el calendari al tenant'),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

export function useRemoveTenantHolidayCalendarAssignment() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: (assignmentId: string) => removeTenantHolidayCalendarAssignment(assignmentId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
      toast({ title: t('setup.tenant_remove_success', 'Calendari eliminat del tenant') })
    },
    onError: (err: Error) => {
      toast({
        title: t('setup.tenant_remove_error', 'Error en eliminar el calendari del tenant'),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

export function useImportNagerHolidays() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: importNagerHolidays,
    onSuccess: result => {
      queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
      toast({
        title: t('setup.import_success_count', 'Importats {{count}} festius (total {{total}})', {
          count: result.importedCount,
          total: result.totalCount,
        }),
      })
    },
    onError: (err: Error) => {
      toast({
        title: t('setup.import_error', 'Error en importar festius'),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

export function useCreateHolidayCalendar() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: createHolidayCalendar,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
      toast({ title: t('setup.calendar_created', 'Calendari creat') })
    },
    onError: (err: Error) => {
      toast({
        title: t('setup.calendar_error', 'Error en crear el calendari'),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

export function useDeleteHolidayCalendar() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: deleteHolidayCalendar,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
      toast({ title: t('setup.calendar_deleted', 'Calendari eliminat') })
    },
    onError: (err: Error) => {
      toast({
        title: t('setup.calendar_delete_error', 'Error en eliminar el calendari'),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

export function useCreateHoliday() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: createHoliday,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
      toast({ title: t('setup.holiday_saved', 'Festiu desat') })
    },
    onError: (err: Error) => {
      toast({
        title: t('setup.holiday_save_error', 'Error en desar el festiu'),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

export function useUpdateHoliday() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: updateHoliday,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
      toast({ title: t('setup.holiday_saved', 'Festiu desat') })
    },
    onError: (err: Error) => {
      toast({
        title: t('setup.holiday_save_error', 'Error en desar el festiu'),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

export function useDeleteHoliday() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: deleteHoliday,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
      toast({ title: t('setup.holiday_deleted', 'Festiu eliminat') })
    },
    onError: (err: Error) => {
      toast({
        title: t('setup.holiday_delete_error', 'Error en eliminar el festiu'),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

// ─── Weekly Recurring Base (ADR-0003) ─────────────────────────────────────────

export function useCalendarGroupWeeklyPattern(groupId: string | null) {
  return useQuery({
    queryKey: ['attendance', 'calendar-group-weekly-pattern', groupId ?? ''],
    queryFn: () => getCalendarGroupWeeklyPattern(groupId!),
    enabled: !!groupId,
    staleTime: 60 * 1000,
  })
}

export function useSetCalendarGroupWeeklyDay() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: setCalendarGroupWeeklyDay,
    onSuccess: (_, vars) => {
      queryClient.invalidateQueries({
        queryKey: ['attendance', 'calendar-group-weekly-pattern', vars.groupId],
      })
      toast({ title: t('weekly_base.day_saved', 'Dia del patró desat') })
    },
    onError: (err: Error) => {
      toast({
        title: t('weekly_base.day_save_error', 'Error en desar el patró setmanal'),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

export function useClearCalendarGroupWeeklyDay() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: clearCalendarGroupWeeklyDay,
    onSuccess: (_, vars) => {
      queryClient.invalidateQueries({
        queryKey: ['attendance', 'calendar-group-weekly-pattern', vars.groupId],
      })
    },
  })
}

export function useEmployeeWeeklyPattern(employeeId: string | null) {
  return useQuery({
    queryKey: ['attendance', 'employee-weekly-pattern', employeeId ?? ''],
    queryFn: () => getEmployeeWeeklyPattern(employeeId!),
    enabled: !!employeeId,
    staleTime: 60 * 1000,
  })
}

export function useSetEmployeeWeeklyDay() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: setEmployeeWeeklyDay,
    onSuccess: (_, vars) => {
      queryClient.invalidateQueries({
        queryKey: ['attendance', 'employee-weekly-pattern', vars.employeeId],
      })
      toast({ title: t('weekly_base.day_saved', 'Dia del patró desat') })
    },
    onError: (err: Error) => {
      toast({
        title: t('weekly_base.day_save_error', 'Error en desar el patró setmanal'),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

export function useClearEmployeeWeeklyDay() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: clearEmployeeWeeklyDay,
    onSuccess: (_, vars) => {
      queryClient.invalidateQueries({
        queryKey: ['attendance', 'employee-weekly-pattern', vars.employeeId],
      })
    },
  })
}

// ─── All Time Summaries (admin) ───────────────────────────────────────────────

export function useAllTimeDailySummaries(from: string, to: string, employeeId?: string) {
  const { selectedSiteId } = useTenant()
  const resolvedSiteId = selectedSiteId

  return useQuery({
    queryKey: attendanceKeys.allDailySummaries(resolvedSiteId ?? '', from, to, employeeId),
    queryFn: () => getAllTimeDailySummaries(resolvedSiteId!, from, to, employeeId),
    enabled: !!resolvedSiteId && !!from && !!to,
  })
}

export function useAllTimeDailySummariesForSite(
  siteId: string | null,
  from: string,
  to: string,
  employeeId?: string,
) {
  return useQuery({
    queryKey: attendanceKeys.allDailySummaries(siteId ?? '', from, to, employeeId),
    queryFn: () => getAllTimeDailySummaries(siteId!, from, to, employeeId),
    enabled: !!siteId && !!from && !!to,
  })
}

// ─── Site Holiday Exclusions ──────────────────────────────────────────────────

export function useSiteHolidayExclusions() {
  const { selectedSiteId } = useTenant()
  return useQuery({
    queryKey: attendanceKeys.siteHolidayExclusions(selectedSiteId ?? ''),
    queryFn: () => getSiteHolidayExclusions(selectedSiteId!),
    enabled: !!selectedSiteId,
    staleTime: 2 * 60 * 1000,
  })
}

export function useToggleSiteHolidayExclusion() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: toggleSiteHolidayExclusion,
    onMutate: async (params) => {
      const key = attendanceKeys.siteHolidayExclusions(params.siteId)
      await queryClient.cancelQueries({ queryKey: key })
      const previous = queryClient.getQueryData<SiteHolidayExclusion[]>(key)
      queryClient.setQueryData<SiteHolidayExclusion[]>(key, (old) => {
        if (params.isExcluded) {
          return [...(old ?? []), { id: null, site_id: params.siteId, holiday_id: params.holidayId, created_at: null }]
        } else {
          return (old ?? []).filter((e) => e.holiday_id !== params.holidayId)
        }
      })
      return { previous, key }
    },
    onError: (err: Error, _params, context) => {
      if (context) {
        queryClient.setQueryData(context.key, context.previous ?? [])
      }
      toast({
        title: t('setup.holiday_exclusion_error', "Error en canviar l'estat del festiu"),
        description: err.message,
        variant: 'destructive',
      })
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
    },
  })
}
