/**
 * Hooks for the Labor Calendar visual editor.
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { useTenant } from '@/contexts/TenantContext'
import { supabase } from '@/lib/supabase'
import { useToast } from '@/hooks/use-toast'
import type { WorkInterval } from './workIntervals'
import { parseWorkIntervals } from './workIntervals'
import { getSiteHolidays, type Holiday } from './shiftsService'

export { type Holiday }

/** Treat empty string as null for optional UUID RPC params. */
export function sanitizeOptionalUuid(value?: string | null): string | null {
  if (value == null || value === '') return null
  return value
}

function resolveUpsertSiteId(
  explicitSiteId: string | null | undefined,
  selectedSiteId: string | null | undefined,
): string | null {
  // undefined = use tenant site selector; null = explicitly tenant-wide / global group scope
  if (explicitSiteId !== undefined) return explicitSiteId
  return selectedSiteId ?? null
}

/** Site scope for group override rows when falling back to tenant site selector. */
export function resolveGroupOverrideSiteId(
  calendarGroupSiteId?: string | null,
  selectedSiteId?: string | null,
): string | null {
  const groupSite = sanitizeOptionalUuid(calendarGroupSiteId)
  if (groupSite) return groupSite
  return sanitizeOptionalUuid(selectedSiteId)
}

export type DayType = 'work' | 'holiday' | 'vacation' | 'leave' | 'undefined'

/** Types assignable on tenant/site calendars (not employee). */
export type TenantDayType = Exclude<DayType, 'leave'>

export interface LaborCalendarOverride {
  id: string
  tenant_id: string
  site_id: string | null
  group_id: string | null
  employee_id: string | null
  calendar_date: string
  day_type: DayType
  day_name: string | null
  work_start: string | null
  work_end: string | null
  work_intervals: WorkInterval[] | null
  created_at: string
  updated_at: string
}

export interface UpsertDaysParams {
  dates: string[]
  dayType: TenantDayType
  dayName?: string | null
  workIntervals?: WorkInterval[] | null
  siteId?: string | null
  groupId?: string | null
  employeeId?: string | null
}

export interface WeeklyPatternParams {
  year: number
  dowArray: number[]
  dayType: TenantDayType
  dayName?: string | null
  workIntervals?: WorkInterval[] | null
  siteId?: string | null
  groupId?: string | null
  employeeId?: string | null
  /** Quan true (per defecte), el RPC no toca dies amb festiu assignat. */
  skipAssignedHolidays?: boolean
}

export interface CalendarGroup {
  id: string
  tenant_id: string
  site_id: string | null
  name: string
  color: string
  description: string | null
  is_active: boolean
  sort_order: number
  attendance_geo_enabled: boolean | null
  punch_only_at_stations: boolean | null
  created_at: string
  updated_at: string
}

export const laborCalKeys = {
  all: ['labor-calendar'] as const,
  overrides: (tenantId: string, siteId: string | null | undefined, year: number) =>
    ['labor-calendar', 'overrides', tenantId, siteId ?? 'none', year] as const,
}

export function useLaborCalendarOverrides(year: number) {
  const { selectedTenantId, selectedSiteId } = useTenant()

  return useQuery({
    queryKey: laborCalKeys.overrides(selectedTenantId ?? '', selectedSiteId, year),
    queryFn: async (): Promise<LaborCalendarOverride[]> => {
      const from = `${year}-01-01`
      const to = `${year}-12-31`

      // The main grid only needs tenant/site/group overrides — not per-employee ones.
      const { data, error } = await supabase
        .from('labor_calendar_overrides' as never)
        .select('*')
        .gte('calendar_date', from)
        .lte('calendar_date', to)
        .is('employee_id' as never, null)
        .order('calendar_date')

      if (error) throw error
      return (data ?? []).map((row) => {
        const r = row as Record<string, unknown>
        return {
          ...(r as unknown as LaborCalendarOverride),
          work_intervals: parseWorkIntervals(r.work_intervals),
        }
      })
    },
    enabled: !!selectedTenantId,
    staleTime: 30_000,
  })
}

/** Holidays from assigned calendars (site → tenant fallback). Display-only layer. */
export function useAssignedHolidays(year: number) {
  const { selectedTenantId, activeTenant, selectedSiteId } = useTenant()
  const tenantId = selectedTenantId ?? activeTenant?.id ?? null
  const from = `${year}-01-01`
  const to = `${year}-12-31`

  return useQuery({
    queryKey: ['labor-calendar', 'assigned-holidays', tenantId, selectedSiteId, year],
    queryFn: async (): Promise<Map<string, Holiday>> => {
      if (!tenantId) return new Map()
      const holidays = await getSiteHolidays(tenantId, selectedSiteId, from, to)
      const map = new Map<string, Holiday>()
      for (const h of holidays) {
        if (h.date) map.set(h.date.slice(0, 10), h)
      }
      return map
    },
    enabled: !!tenantId,
    staleTime: 60_000,
  })
}

export function useUpsertLaborCalendarDays() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const { selectedSiteId } = useTenant()

  return useMutation({
    mutationFn: async (params: UpsertDaysParams) => {
      const first = params.workIntervals?.[0]
      const { error } = await supabase.rpc(
        'upsert_labor_calendar_days' as never,
        {
          p_dates: params.dates,
          p_day_type: params.dayType,
          p_day_name: params.dayName ?? null,
          p_work_start: first?.start ?? null,
          p_work_end: first?.end ?? null,
          p_work_intervals: params.workIntervals?.length ? params.workIntervals : null,
          p_site_id: resolveUpsertSiteId(params.siteId, selectedSiteId),
          p_group_id: params.groupId ?? null,
          p_employee_id: params.employeeId ?? null,
        } as never,
      )
      if (error) throw error
    },
    onSuccess: (_, vars) => {
      queryClient.invalidateQueries({ queryKey: laborCalKeys.all })
      if (vars.dayType !== 'undefined') {
        toast({
          title: t('labor_cal.save_ok', '{{count}} dia/dies actualitzats', { count: vars.dates.length }),
        })
      }
    },
    onError: (err: Error) => {
      toast({
        title: t('labor_cal.save_error', 'Error en desar el calendari'),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

export function useApplyWeeklyPattern() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const { selectedSiteId } = useTenant()

  return useMutation({
    mutationFn: async (params: WeeklyPatternParams) => {
      const { data, error } = await supabase.rpc(
        'apply_weekly_pattern_to_calendar' as never,
        {
          p_year: params.year,
          p_dow_array: params.dowArray,
          p_day_type: params.dayType,
          p_day_name: params.dayName ?? null,
          p_work_intervals: params.workIntervals?.length ? params.workIntervals : null,
          p_site_id: resolveUpsertSiteId(params.siteId, selectedSiteId),
          p_group_id: params.groupId ?? null,
          p_employee_id: params.employeeId ?? null,
          p_skip_assigned_holidays: params.skipAssignedHolidays ?? true,
        } as never,
      )
      if (error) throw error
      return (data as number) ?? 0
    },
    onSuccess: (count) => {
      queryClient.invalidateQueries({ queryKey: laborCalKeys.all })
      toast({
        title: t('labor_cal.pattern_ok', '{{count}} dies actualitzats', { count }),
      })
    },
    onError: (err: Error) => {
      toast({
        title: t('labor_cal.pattern_error', "Error en aplicar el patró setmanal"),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

// ─── Calendar Groups ──────────────────────────────────────────────────────────

export function useCalendarGroups(siteId?: string | null) {
  const normalizedSiteId = sanitizeOptionalUuid(siteId)
  return useQuery({
    queryKey: ['calendar-groups', normalizedSiteId ?? 'all'],
    queryFn: async (): Promise<CalendarGroup[]> => {
      const { data, error } = await supabase.rpc(
        'list_calendar_groups' as never,
        { p_site_id: normalizedSiteId } as never,
      )
      if (error) throw error
      return (data as CalendarGroup[]) ?? []
    },
    staleTime: 60_000,
  })
}

export function useUpsertCalendarGroup() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (params: {
      id?: string
      name: string
      color?: string
      description?: string
      siteId?: string | null
      isActive?: boolean
      sortOrder?: number
      attendanceGeoEnabled?: boolean | null
      punchOnlyAtStations?: boolean | null
    }) => {
      const { data, error } = await supabase.rpc(
        'upsert_calendar_group' as never,
        {
          p_id: params.id ?? null,
          p_name: params.name,
          p_color: params.color ?? '#6366f1',
          p_description: params.description ?? null,
          p_site_id: sanitizeOptionalUuid(params.siteId),
          p_is_active: params.isActive ?? true,
          p_sort_order: params.sortOrder ?? 0,
          p_attendance_geo_enabled: params.attendanceGeoEnabled ?? null,
          p_punch_only_at_stations: params.punchOnlyAtStations ?? null,
        } as never,
      )
      if (error) throw error
      return data as string
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['calendar-groups'] })
      toast({ title: t('cal_groups.save_ok', 'Grup desat') })
    },
    onError: (err: Error) => {
      toast({ title: t('cal_groups.save_error', 'Error en desar el grup'), description: err.message, variant: 'destructive' })
    },
  })
}

export interface CalendarGroupEmployee {
  employee_id: string
  full_name: string | null
  site_id: string | null
}

export async function listCalendarGroupEmployees(groupId: string): Promise<CalendarGroupEmployee[]> {
  const { data, error } = await supabase.rpc(
    'list_calendar_group_employees' as never,
    { p_group_id: groupId } as never,
  )
  if (error) throw error
  return (data as CalendarGroupEmployee[]) ?? []
}

export function useDeleteCalendarGroup() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (params: { groupId: string; reassignToGroupId?: string | null }) => {
      const { error } = await supabase.rpc(
        'delete_calendar_group' as never,
        {
          p_group_id: params.groupId,
          p_reassign_to_group_id: params.reassignToGroupId ?? null,
        } as never,
      )
      if (error) throw error
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['calendar-groups'] })
      queryClient.invalidateQueries({ queryKey: ['employees'] })
      queryClient.invalidateQueries({ queryKey: ['labor-calendar'] })
      toast({ title: t('cal_groups.delete_ok', 'Grup eliminat') })
    },
    onError: (err: Error) => {
      toast({ title: t('cal_groups.delete_error', 'Error en eliminar el grup'), description: err.message, variant: 'destructive' })
    },
  })
}

export function useSetEmployeeCalendarGroup() {
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (params: { employeeId: string; calendarGroupId: string | null }) => {
      const { error } = await supabase.rpc(
        'set_employee_calendar_group' as never,
        { p_employee_id: params.employeeId, p_calendar_group_id: params.calendarGroupId } as never,
      )
      if (error) throw error
    },
    onSuccess: (_, vars) => {
      queryClient.invalidateQueries({ queryKey: ['employees', vars.employeeId] })
      queryClient.invalidateQueries({ queryKey: ['labor-calendar', 'overrides'] })
    },
    onError: (err: Error) => {
      toast({ title: 'Error en assignar el grup', description: err.message, variant: 'destructive' })
    },
  })
}

// ─── Context-free hooks for employee calendar (no TenantContext) ──────────────

/**
 * Fetches all labor calendar overrides + holidays for the year without reading
 * from TenantContext. Fetches: tenant, site, group (if any) and employee (if any)
 * overrides in one pass so buildDayMap can apply the full 5-level cascade.
 */
export function useEmployeeCalendarData(
  year: number,
  tenantId: string | null,
  siteId: string | null | undefined,
  employeeId?: string | null,
  calendarGroupId?: string | null,
) {
  const from = `${year}-01-01`
  const to = `${year}-12-31`

  // Fetch tenant/site/group overrides (no employee rows)
  const baseOverridesQuery = useQuery({
    queryKey: ['labor-calendar', 'overrides', tenantId, siteId ?? 'none', calendarGroupId ?? 'none', year, 'base'],
    queryFn: async (): Promise<LaborCalendarOverride[]> => {
      const { data, error } = await supabase
        .from('labor_calendar_overrides' as never)
        .select('*')
        .gte('calendar_date', from)
        .lte('calendar_date', to)
        .is('employee_id' as never, null)
        .order('calendar_date')
      if (error) throw error
      return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
        ...(r as unknown as LaborCalendarOverride),
        work_intervals: parseWorkIntervals(r.work_intervals),
      }))
    },
    enabled: !!tenantId,
    staleTime: 30_000,
  })

  // Fetch employee-specific overrides
  const employeeOverridesQuery = useQuery({
    queryKey: ['labor-calendar', 'overrides', employeeId, year, 'employee-specific'],
    queryFn: async (): Promise<LaborCalendarOverride[]> => {
      if (!employeeId) return []
      const { data, error } = await supabase
        .from('labor_calendar_overrides' as never)
        .select('*')
        .gte('calendar_date', from)
        .lte('calendar_date', to)
        .eq('employee_id' as never, employeeId)
        .order('calendar_date')
      if (error) throw error
      return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
        ...(r as unknown as LaborCalendarOverride),
        work_intervals: parseWorkIntervals(r.work_intervals),
      }))
    },
    enabled: !!tenantId && !!employeeId,
    staleTime: 30_000,
  })

  const holidaysQuery = useQuery({
    queryKey: ['labor-calendar', 'assigned-holidays', tenantId, siteId, year, 'employee'],
    queryFn: async (): Promise<Map<string, Holiday>> => {
      if (!tenantId) return new Map()
      const holidays = await getSiteHolidays(tenantId, siteId ?? null, from, to)
      const map = new Map<string, Holiday>()
      for (const h of holidays) {
        if (h.date) map.set(h.date.slice(0, 10), h)
      }
      return map
    },
    enabled: !!tenantId,
    staleTime: 60_000,
  })

  const allOverrides = [
    ...(baseOverridesQuery.data ?? []),
    ...(employeeOverridesQuery.data ?? []),
  ]

  return {
    overrides: allOverrides,
    assignedHolidays: holidaysQuery.data ?? new Map<string, Holiday>(),
    isLoading:
      baseOverridesQuery.isLoading ||
      (!!employeeId && employeeOverridesQuery.isLoading) ||
      holidaysQuery.isLoading,
  }
}
