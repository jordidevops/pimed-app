import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'

// ─── Types ────────────────────────────────────────────────────────────────────

export type WorkShift = Database['api']['Views']['work_shifts']['Row']
export type ShiftSlot = Database['api']['Views']['shift_slots']['Row']
export type EmployeeAbsence = Database['api']['Views']['employee_absences']['Row']
export type Employee = Database['api']['Views']['employees']['Row']

export interface CoverageDay {
  work_date: string
  employee_count: number
  required_employee_count: number
  coverage_delta: number
}

// ─── Work Shifts (templates) ─────────────────────────────────────────────────

export async function getWorkShifts(siteId?: string | null): Promise<WorkShift[]> {
  let q = supabase.from('work_shifts').select('*').eq('is_active', true).order('name')
  if (siteId) q = q.or(`site_id.eq.${siteId},site_id.is.null`)
  const { data, error } = await q
  if (error) throw error
  return data ?? []
}

export interface AssignShiftSlotResult {
  slot_id: string
  status: string
  location_id: string | null
  anomalies: string[]
}

export async function createWorkShift(params: {
  site_id: string
  name: string
  start_time: string
  end_time: string
  color?: string
  default_role_id?: string | null
}): Promise<WorkShift> {
  const { data, error } = await supabase.rpc('create_work_shift' as never, {
    p_site_id: params.site_id,
    p_name: params.name,
    p_start_time: params.start_time,
    p_end_time: params.end_time,
    p_color: params.color ?? '#6366f1',
    p_default_role_id: params.default_role_id ?? null,
  } as never)
  if (error) throw error
  return data as unknown as WorkShift
}

export async function updateWorkShift(params: {
  id: string
  name?: string
  start_time?: string
  end_time?: string
  color?: string
  default_role_id?: string | null
  clear_role?: boolean
}): Promise<WorkShift> {
  const { data, error } = await supabase.rpc('update_work_shift' as never, {
    p_id: params.id,
    p_name: params.name ?? null,
    p_start_time: params.start_time ?? null,
    p_end_time: params.end_time ?? null,
    p_color: params.color ?? null,
    p_default_role_id: params.default_role_id ?? null,
    p_clear_role: params.clear_role ?? false,
  } as never)
  if (error) throw error
  return data as unknown as WorkShift
}

export async function deactivateWorkShift(id: string): Promise<{ id: string; is_active: boolean }> {
  const { data, error } = await supabase.rpc('deactivate_work_shift' as never, {
    p_id: id,
  } as never)
  if (error) throw error
  return data as unknown as { id: string; is_active: boolean }
}

// ─── Shift Slots ─────────────────────────────────────────────────────────────

export async function getShiftSlots(
  siteId: string,
  from: string,
  to: string,
): Promise<ShiftSlot[]> {
  const { data, error } = await supabase
    .from('shift_slots')
    .select('*')
    .eq('site_id', siteId)
    .gte('slot_date', from)
    .lte('slot_date', to)
    .neq('status', 'cancelled')
    .order('slot_date')
    .order('start_time')
  if (error) throw error
  return data ?? []
}

export async function getMyShiftSlots(
  employeeId: string,
  from: string,
  to: string,
): Promise<ShiftSlot[]> {
  const { data, error } = await supabase
    .from('shift_slots')
    .select('*')
    .eq('employee_id', employeeId)
    .eq('status', 'published')
    .gte('slot_date', from)
    .lte('slot_date', to)
    .order('slot_date')
    .order('start_time')
  if (error) throw error
  return data ?? []
}

// ─── Assign / Delete / Publish ────────────────────────────────────────────────

export async function assignShiftSlot(params: {
  employee_id: string
  shift_id: string
  slot_date: string
  notes?: string
  location_id?: string | null
}): Promise<AssignShiftSlotResult> {
  const { data, error } = await supabase.rpc('assign_shift_slot', {
    p_employee_id: params.employee_id,
    p_shift_id: params.shift_id,
    p_slot_date: params.slot_date,
    p_notes: params.notes,
    p_location_id: params.location_id ?? null,
  })
  if (error) throw error
  const raw = (data ?? {}) as Record<string, unknown>
  const anomaliesRaw = raw.anomalies
  const anomalies = Array.isArray(anomaliesRaw)
    ? anomaliesRaw.map(String)
    : []
  return {
    slot_id: String(raw.slot_id ?? ''),
    status: String(raw.status ?? 'draft'),
    location_id: raw.location_id == null ? null : String(raw.location_id),
    anomalies,
  }
}

export async function bulkDeleteShiftSlots(slotIds: string[]) {
  const { data, error } = await supabase.rpc('bulk_delete_shift_slots', {
    p_slot_ids: slotIds,
  })
  if (error) throw error
  return data
}

export interface PreflightIssue {
  code: string
  severity: 'block' | 'warn_require_reason' | 'warn' | string
  employee_id?: string
  work_date?: string
  slot_id?: string
  message?: string
  [key: string]: unknown
}

export interface PreflightPublishResult {
  site_id: string
  week_start: string
  week_end: string
  draft_count: number
  can_publish: boolean
  blockers: PreflightIssue[]
  warnings: PreflightIssue[]
  affected_employee_ids: string[]
  required_warning_codes: string[]
}

export interface ShiftPublicationDiff {
  from_publication_id: string | null
  to_publication_id: string
  counts: { added: number; removed: number; changed: number }
  added?: unknown[]
  removed?: unknown[]
  changed?: unknown[]
  [key: string]: unknown
}

export interface PublishShiftsResult {
  site_id: string
  week_start: string
  published: number
  publication_id: string | null
  version: number | null
  content_hash: string | null
  warnings_accepted?: string[]
  diff?: ShiftPublicationDiff | null
}

function asIssueArray(raw: unknown): PreflightIssue[] {
  if (!Array.isArray(raw)) return []
  return raw.flatMap((row) => {
    if (!row || typeof row !== 'object' || Array.isArray(row)) return []
    const r = row as Record<string, unknown>
    return [{
      code: String(r.code ?? ''),
      severity: String(r.severity ?? 'warn'),
      employee_id: r.employee_id == null ? undefined : String(r.employee_id),
      work_date: r.work_date == null ? undefined : String(r.work_date),
      slot_id: r.slot_id == null ? undefined : String(r.slot_id),
      message: r.message == null ? undefined : String(r.message),
    }]
  })
}

export async function preflightPublishShifts(
  siteId: string,
  weekStart: string,
): Promise<PreflightPublishResult> {
  const { data, error } = await supabase.rpc('preflight_publish_shifts' as never, {
    p_site_id: siteId,
    p_week_start: weekStart,
  } as never)
  if (error) throw error
  const raw = (data ?? {}) as Record<string, unknown>
  const requiredRaw = raw.required_warning_codes
  return {
    site_id: String(raw.site_id ?? siteId),
    week_start: String(raw.week_start ?? weekStart),
    week_end: String(raw.week_end ?? ''),
    draft_count: Number(raw.draft_count ?? 0),
    can_publish: Boolean(raw.can_publish),
    blockers: asIssueArray(raw.blockers),
    warnings: asIssueArray(raw.warnings),
    affected_employee_ids: Array.isArray(raw.affected_employee_ids)
      ? raw.affected_employee_ids.map(String)
      : [],
    required_warning_codes: Array.isArray(requiredRaw)
      ? requiredRaw.map(String)
      : [],
  }
}

export async function publishShifts(
  siteId: string,
  weekStart: string,
  warningsAccepted: string[] = [],
): Promise<PublishShiftsResult> {
  const { data, error } = await supabase.rpc('publish_shifts' as never, {
    p_site_id: siteId,
    p_week_start: weekStart,
    p_warnings_accepted: warningsAccepted,
  } as never)
  if (error) throw error
  const raw = (data ?? {}) as Record<string, unknown>
  const diffRaw = raw.diff
  let diff: ShiftPublicationDiff | null = null
  if (diffRaw && typeof diffRaw === 'object' && !Array.isArray(diffRaw)) {
    const d = diffRaw as Record<string, unknown>
    const counts = (d.counts ?? {}) as Record<string, unknown>
    diff = {
      from_publication_id: d.from_publication_id == null ? null : String(d.from_publication_id),
      to_publication_id: String(d.to_publication_id ?? ''),
      counts: {
        added: Number(counts.added ?? 0),
        removed: Number(counts.removed ?? 0),
        changed: Number(counts.changed ?? 0),
      },
      added: Array.isArray(d.added) ? d.added : [],
      removed: Array.isArray(d.removed) ? d.removed : [],
      changed: Array.isArray(d.changed) ? d.changed : [],
    }
  }
  return {
    site_id: String(raw.site_id ?? siteId),
    week_start: String(raw.week_start ?? weekStart),
    published: Number(raw.published ?? 0),
    publication_id: raw.publication_id == null ? null : String(raw.publication_id),
    version: raw.version == null ? null : Number(raw.version),
    content_hash: raw.content_hash == null ? null : String(raw.content_hash),
    warnings_accepted: Array.isArray(raw.warnings_accepted)
      ? raw.warnings_accepted.map(String)
      : warningsAccepted,
    diff,
  }
}

export async function diffShiftPublications(
  fromId: string,
  toId: string,
): Promise<ShiftPublicationDiff> {
  const { data, error } = await supabase.rpc('diff_shift_publications' as never, {
    p_from_publication_id: fromId,
    p_to_publication_id: toId,
  } as never)
  if (error) throw error
  const d = (data ?? {}) as Record<string, unknown>
  const counts = (d.counts ?? {}) as Record<string, unknown>
  return {
    from_publication_id: d.from_publication_id == null ? null : String(d.from_publication_id),
    to_publication_id: String(d.to_publication_id ?? toId),
    counts: {
      added: Number(counts.added ?? 0),
      removed: Number(counts.removed ?? 0),
      changed: Number(counts.changed ?? 0),
    },
    added: Array.isArray(d.added) ? d.added : [],
    removed: Array.isArray(d.removed) ? d.removed : [],
    changed: Array.isArray(d.changed) ? d.changed : [],
  }
}

export async function getCoverageForPeriod(
  siteId: string,
  from: string,
  to: string,
): Promise<CoverageDay[]> {
  const { data, error } = await supabase.rpc('get_coverage_for_period', {
    p_site_id: siteId,
    p_from: from,
    p_to: to,
  })
  if (error) throw error
  if (!Array.isArray(data)) return []

  return data.flatMap((row) => {
    if (!row || typeof row !== 'object' || Array.isArray(row)) return []

    const parsed = row as Record<string, unknown>
    return [{
      work_date: String(parsed.work_date ?? ''),
      employee_count: Number(parsed.employee_count ?? 0),
      required_employee_count: Number(parsed.required_employee_count ?? 0),
      coverage_delta: Number(parsed.coverage_delta ?? 0),
    }]
  })
}

// ─── Site Employees ───────────────────────────────────────────────────────────

export async function getSiteEmployees(siteId: string): Promise<Employee[]> {
  const { data, error } = await supabase
    .from('employees')
    .select('*')
    .eq('site_id', siteId)
    .eq('status', 'active')
    .order('full_name')
  if (error) throw error
  return data ?? []
}

/** Tots els empleats actius del tenant, independentment del local. */
export async function getTenantEmployees(): Promise<Employee[]> {
  const { data, error } = await supabase
    .from('employees')
    .select('id, full_name, site_id, status')
    .eq('status', 'active')
    .order('full_name')
  if (error) throw error
  return (data ?? []) as Employee[]
}

// ─── Absences ─────────────────────────────────────────────────────────────────

export async function getMyAbsences(
  employeeId: string,
  from: string,
  to: string,
): Promise<EmployeeAbsence[]> {
  const { data, error } = await supabase
    .from('employee_absences')
    .select('*')
    .eq('employee_id', employeeId)
    .lte('start_date', to)
    .gte('end_date', from)
    .order('start_date', { ascending: false })
  if (error) throw error
  return data ?? []
}

export async function getAllAbsences(
  from: string,
  to: string,
  siteId?: string | null,
): Promise<EmployeeAbsence[]> {
  let query = supabase
    .from('employee_absences')
    .select('*')
    .lte('start_date', to)
    .gte('end_date', from)

  if (siteId) {
    query = query.eq('site_id', siteId)
  }

  const { data, error } = await query.order('start_date', { ascending: false })
  if (error) throw error
  return data ?? []
}

export type AbsenceParentKey =
  | 'vacation'
  | 'personal'
  | 'family'
  | 'permission'
  | 'it'
  | 'compensation'
  | 'other'

export interface AbsenceTypeConfig {
  id: string
  absence_type: string
  name_i18n: Record<string, string>
  counts_as_worked: boolean
  affects_entitlement: boolean
  entitlement_type: string | null
  requires_approval: boolean
  requires_document: boolean
  max_days_per_year: number | null
  is_it: boolean
  is_partial: boolean
  is_active: boolean
  is_system: boolean
  sort_order: number
  parent_key: AbsenceParentKey | null
  subtype_key: string | null
  export_code: string | null
}

export async function listAbsenceTypeConfigs(
  includeIt = true,
  includePartial = true,
): Promise<AbsenceTypeConfig[]> {
  const { data, error } = await supabase.rpc(
    'list_absence_type_configs' as never,
    { p_include_it: includeIt, p_include_partial: includePartial } as never,
  )
  if (error) throw error
  return (data ?? []) as unknown as AbsenceTypeConfig[]
}

export async function saveAbsenceTypeExportSettings(params: {
  absence_type: string
  export_code: string
  parent_key?: AbsenceParentKey | null
  subtype_key?: string | null
}) {
  const { data, error } = await supabase.rpc('save_absence_type_export_settings' as never, {
    p_absence_type: params.absence_type,
    p_export_code: params.export_code,
    p_parent_key: params.parent_key ?? null,
    p_subtype_key: params.subtype_key ?? null,
  } as never)
  if (error) throw error
  return data as string
}

export async function createAbsenceTypeSubtype(params: {
  absence_type: string
  parent_key: AbsenceParentKey
  subtype_key: string
  name_i18n: Record<string, string>
  export_code: string
  counts_as_worked?: boolean
  affects_entitlement?: boolean
  entitlement_type?: string | null
  requires_approval?: boolean
  requires_document?: boolean
  max_days_per_year?: number | null
  is_partial?: boolean
}) {
  const { data, error } = await supabase.rpc('create_absence_type_subtype' as never, {
    p_absence_type: params.absence_type,
    p_parent_key: params.parent_key,
    p_subtype_key: params.subtype_key,
    p_name_i18n: params.name_i18n,
    p_export_code: params.export_code,
    p_counts_as_worked: params.counts_as_worked ?? false,
    p_affects_entitlement: params.affects_entitlement ?? false,
    p_entitlement_type: params.entitlement_type ?? null,
    p_requires_approval: params.requires_approval ?? true,
    p_requires_document: params.requires_document ?? false,
    p_max_days_per_year: params.max_days_per_year ?? null,
    p_is_partial: params.is_partial ?? false,
  } as never)
  if (error) throw error
  return data as string
}

export async function requestAbsence(params: {
  employee_id: string
  absence_type: string
  start_date: string
  end_date: string
  notes?: string
  hours_per_day?: number
  partial_start_time?: string | null
  partial_end_time?: string | null
}) {
  const { data, error } = await supabase.rpc(
    'request_absence' as never,
    {
      p_employee_id: params.employee_id,
      p_absence_type: params.absence_type,
      p_start_date: params.start_date,
      p_end_date: params.end_date,
      p_notes: params.notes,
      p_hours_per_day: params.hours_per_day,
      p_partial_start_time: params.partial_start_time ?? null,
      p_partial_end_time: params.partial_end_time ?? null,
    } as never,
  )
  if (error) throw error
  return data
}

export async function approveAbsence(
  absenceId: string,
  newStatus: 'approved' | 'rejected' | 'cancelled',
  reviewComment?: string,
) {
  const { data, error } = await supabase.rpc('approve_absence', {
    p_absence_id: absenceId,
    p_new_status: newStatus,
    p_review_comment: reviewComment,
  })
  if (error) throw error
  return data
}

export async function registerIT(params: {
  employee_id: string
  absence_type: string
  start_date: string
  end_date?: string | null
  it_reference?: string | null
  notes?: string | null
  document_id?: string | null
}) {
  const { data, error } = await supabase.rpc(
    'register_it' as never,
    {
      p_employee_id:  params.employee_id,
      p_absence_type: params.absence_type,
      p_start_date:   params.start_date,
      p_end_date:     params.end_date ?? null,
      p_it_reference: params.it_reference ?? null,
      p_notes:        params.notes ?? null,
      p_document_id:  params.document_id ?? null,
    } as never,
  )
  if (error) throw error
  return data
}

export async function closeIT(params: {
  absence_id: string
  end_date: string
  it_reference?: string | null
}) {
  const { data, error } = await supabase.rpc(
    'close_it' as never,
    {
      p_absence_id:   params.absence_id,
      p_end_date:     params.end_date,
      p_it_reference: params.it_reference ?? null,
    } as never,
  )
  if (error) throw error
  return data
}

// ─── Holidays ─────────────────────────────────────────────────────────────────

export type Holiday = Database['api']['Views']['holidays']['Row']
export type HolidayCalendar = Database['api']['Views']['holiday_calendars']['Row']
export type SiteHolidayCalendarAssignment = Database['api']['Views']['site_holiday_calendar_assignments']['Row']

export interface HolidayCoverageInfo {
  source: 'site' | 'tenant' | 'none'
  calendarCount: number
}

export interface ImportHolidaysResult {
  importedCount: number
  totalCount: number
}

async function resolveCalendarIdsForHolidays(
  tenantId: string,
  siteId: string | null,
): Promise<{ source: 'site' | 'tenant' | 'none'; calendarIds: string[] }> {
  const calendarIds = new Set<string>()

  const { data: tenantAssignments, error: tenantErr } = await supabase
    .from('tenant_holiday_calendar_assignments')
    .select('calendar_id')
    .eq('tenant_id', tenantId)
    .eq('calendar_active', true)
  if (tenantErr) throw tenantErr

  let tenantRows = tenantAssignments ?? []
  if (tenantRows.length === 0) {
    const { data: tenantFallbackRows, error: tenantFallbackErr } = await supabase
      .from('tenant_holiday_calendar_assignments')
      .select('calendar_id')
      .eq('tenant_id', tenantId)
      .neq('calendar_active', false)
    if (tenantFallbackErr) throw tenantFallbackErr
    tenantRows = tenantFallbackRows ?? []
  }

  for (const a of tenantRows) {
    if (a.calendar_id) calendarIds.add(a.calendar_id)
  }

  const tenantCount = calendarIds.size

  if (siteId) {
    const { data: siteAssignments, error: siteErr } = await supabase
      .from('site_holiday_calendar_assignments')
      .select('calendar_id')
      .eq('site_id', siteId)
      .eq('calendar_active', true)
    if (siteErr) throw siteErr

    let siteRows = siteAssignments ?? []
    if (siteRows.length === 0) {
      const { data: siteFallbackRows, error: siteFallbackErr } = await supabase
        .from('site_holiday_calendar_assignments')
        .select('calendar_id')
        .eq('site_id', siteId)
        .neq('calendar_active', false)
      if (siteFallbackErr) throw siteFallbackErr
      siteRows = siteFallbackRows ?? []
    }

    for (const a of siteRows) {
      if (a.calendar_id) calendarIds.add(a.calendar_id)
    }
  }

  if (calendarIds.size === 0) return { source: 'none', calendarIds: [] }

  const siteOnly = siteId && tenantCount === 0 && calendarIds.size > 0
  return {
    source: siteOnly ? 'site' : 'tenant',
    calendarIds: [...calendarIds],
  }
}

export async function getSiteHolidays(
  tenantId: string,
  siteId: string | null,
  from: string,
  to: string,
): Promise<Holiday[]> {
  const { calendarIds } = await resolveCalendarIdsForHolidays(tenantId, siteId)
  if (!calendarIds.length) return []

  const { data, error } = await supabase
    .from('holidays')
    .select('*')
    .in('calendar_id', calendarIds)
    .gte('date', from)
    .lte('date', to)
    .order('date')
  if (error) throw error

  const holidays = data ?? []
  if (!siteId) return holidays

  const { data: exclusions, error: exErr } = await supabase
    .from('site_holiday_exclusions')
    .select('holiday_id')
    .eq('site_id', siteId)
  if (exErr) throw exErr

  const excludedIds = new Set(
    (exclusions ?? []).map(e => e.holiday_id).filter(Boolean) as string[],
  )
  return holidays.filter(h => !h.id || !excludedIds.has(h.id))
}

export async function getHolidayCoverageInfo(
  tenantId: string,
  siteId: string | null,
): Promise<HolidayCoverageInfo> {
  const { source, calendarIds } = await resolveCalendarIdsForHolidays(tenantId, siteId)
  return { source, calendarCount: calendarIds.length }
}

export async function getCalendarHolidays(
  calendarId: string,
  from: string,
  to: string,
): Promise<Holiday[]> {
  const { data, error } = await supabase
    .from('holidays')
    .select('*')
    .eq('calendar_id', calendarId)
    .gte('date', from)
    .lte('date', to)
    .order('date')
  if (error) throw error
  return data ?? []
}

export async function getHolidayCalendars(tenantId: string): Promise<HolidayCalendar[]> {
  const { data, error } = await supabase
    .from('holiday_calendars')
    .select('*')
    .eq('tenant_id', tenantId)
    .order('year', { ascending: false })
  if (error) throw error
  return data ?? []
}

export async function getSiteHolidayCalendarAssignments(
  siteId: string,
): Promise<SiteHolidayCalendarAssignment[]> {
  const { data, error } = await supabase
    .from('site_holiday_calendar_assignments')
    .select('*')
    .eq('site_id', siteId)
  if (error) throw error
  return data ?? []
}

export async function assignHolidayCalendarToSite(
  siteId: string,
  calendarId: string,
): Promise<void> {
  const { error } = await supabase.rpc('assign_site_holiday_calendar', {
    p_site_id: siteId,
    p_calendar_id: calendarId,
    p_priority: 0,
  })
  if (error) throw error
}

export async function removeHolidayCalendarFromSite(assignmentId: string): Promise<void> {
  const { error } = await supabase.rpc('remove_site_holiday_calendar_assignment', {
    p_assignment_id: assignmentId,
  })
  if (error) throw error
}

// Nager.Date shape (only fields we need)
interface NagerHoliday {
  date: string
  localName: string
  name: string
  global: boolean
  counties: string[] | null
  holidayType?: string
}

export async function importNagerHolidays(params: {
  calendarId: string
  year: number
  countryCode: string
  regionCode?: string
}): Promise<ImportHolidaysResult> {
  const { count: countBefore, error: beforeErr } = await supabase
    .from('holidays')
    .select('*', { head: true, count: 'exact' })
    .eq('calendar_id', params.calendarId)
  if (beforeErr) throw beforeErr

  const url = `https://date.nager.at/api/v3/PublicHolidays/${params.year}/${params.countryCode}`
  const response = await fetch(url)
  if (!response.ok) throw new Error(`Nager.Date API error: ${response.status}`)
  const rawJson: NagerHoliday[] = await response.json()

  // Filtrar per regió: conserva festius nacionals (global o sense counties)
  // i, si hi ha regionCode, els específics de la regió (ex: ES-CT)
  const isoRegion = params.regionCode
    ? `${params.countryCode}-${params.regionCode}`
    : null
  const nagerJson = rawJson.filter(h => {
    const isNational = h.global || !h.counties || h.counties.length === 0
    if (isNational) return true
    if (isoRegion) return h.counties!.includes(isoRegion)
    return false
  })

  const { error } = await supabase.rpc('import_holidays', {
    p_calendar_id: params.calendarId,
    p_holidays_json: nagerJson as unknown as import('@/types/database.types').Json,
  })
  if (error) throw error

  const { count: countAfter, error: afterErr } = await supabase
    .from('holidays')
    .select('*', { head: true, count: 'exact' })
    .eq('calendar_id', params.calendarId)
  if (afterErr) throw afterErr

  const totalCount = countAfter ?? 0
  const importedCount = Math.max(0, (countAfter ?? 0) - (countBefore ?? 0))
  return { importedCount, totalCount }
}

export type HolidayType = 'national' | 'regional' | 'local' | 'tenant_custom'

export async function createHoliday(params: {
  calendarId: string
  date: string
  name: string
  holidayType: HolidayType
  isHalfDay: boolean
}): Promise<Holiday> {
  const { data, error } = await supabase.rpc('create_holiday', {
    p_calendar_id: params.calendarId,
    p_date: params.date,
    p_name: params.name,
    p_holiday_type: params.holidayType,
    p_is_half_day: params.isHalfDay,
  })
  if (error) throw error
  return data as unknown as Holiday
}

export async function updateHoliday(params: {
  id: string
  date: string
  name: string
  holidayType: HolidayType
  isHalfDay: boolean
}): Promise<Holiday> {
  const { data, error } = await supabase.rpc('update_holiday', {
    p_id: params.id,
    p_date: params.date,
    p_name: params.name,
    p_holiday_type: params.holidayType,
    p_is_half_day: params.isHalfDay,
  })
  if (error) throw error
  return data as unknown as Holiday
}

export async function deleteHoliday(id: string): Promise<void> {
  const { error } = await supabase.rpc('delete_holiday', {
    p_id: id,
  })
  if (error) throw error
}

export async function deleteHolidayCalendar(calendarId: string): Promise<void> {
  const { error } = await supabase.rpc('delete_holiday_calendar', {
    p_calendar_id: calendarId,
  })
  if (error) throw error
}

// ─── Site Holiday Exclusions ──────────────────────────────────────────────────

export type SiteHolidayExclusion = Database['api']['Views']['site_holiday_exclusions']['Row']

export async function getSiteHolidayExclusions(siteId: string): Promise<SiteHolidayExclusion[]> {
  const { data, error } = await supabase
    .from('site_holiday_exclusions')
    .select('*')
    .eq('site_id', siteId)
  if (error) throw error
  return data ?? []
}

export async function toggleSiteHolidayExclusion(params: {
  siteId: string
  holidayId: string
  isExcluded: boolean
}): Promise<void> {
  const { error } = await supabase.rpc('toggle_site_holiday_exclusion', {
    p_site_id: params.siteId,
    p_holiday_id: params.holidayId,
    p_is_excluded: params.isExcluded,
  })
  if (error) throw error
}

export async function createHolidayCalendar(params: {
  name: string
  tenantId: string
  year: number
  countryCode: string
  regionCode?: string
}): Promise<HolidayCalendar> {
  const { data, error } = await supabase
    .from('holiday_calendars')
    .insert({
      name: params.name,
      tenant_id: params.tenantId,
      year: params.year,
      country_code: params.countryCode,
      region_code: params.regionCode ?? null,
    })
    .select()
    .single()
  if (error) throw error
  return data
}

// ─── Tenant Holiday Calendar Assignments ─────────────────────────────────────

export type TenantHolidayCalendarAssignment =
  Database['api']['Views']['tenant_holiday_calendar_assignments']['Row']

export async function getTenantHolidayCalendarAssignments(
  tenantId: string,
): Promise<TenantHolidayCalendarAssignment[]> {
  const { data, error } = await supabase
    .from('tenant_holiday_calendar_assignments')
    .select('*')
    .eq('tenant_id', tenantId)
    .order('priority', { ascending: false })
  if (error) throw error
  return data ?? []
}

export async function assignHolidayCalendarToTenant(
  tenantId: string,
  calendarId: string,
): Promise<void> {
  const { error } = await supabase.rpc('assign_tenant_holiday_calendar', {
    p_tenant_id: tenantId,
    p_calendar_id: calendarId,
    p_priority: 0,
  })
  if (error) throw error
}

export async function removeTenantHolidayCalendarAssignment(
  assignmentId: string,
): Promise<void> {
  const { error } = await supabase.rpc('remove_tenant_holiday_calendar_assignment', {
    p_assignment_id: assignmentId,
  })
  if (error) throw error
}

// ─── Employee Day Overrides ───────────────────────────────────────────────────

export type EmployeeDayOverride = Database['api']['Views']['employee_day_overrides']['Row']

export async function getEmployeeDayOverrides(
  employeeId: string,
): Promise<EmployeeDayOverride[]> {
  const { data, error } = await supabase
    .from('employee_day_overrides')
    .select('*')
    .eq('employee_id', employeeId)
    .order('override_date', { ascending: false })
  if (error) throw error
  return data ?? []
}

export async function upsertEmployeeDayOverride(params: {
  tenantId: string
  employeeId: string
  overrideDate: string
  overrideType: 'force_work' | 'force_holiday'
  note?: string
}): Promise<EmployeeDayOverride> {
  const { data, error } = await supabase
    .from('employee_day_overrides')
    .upsert(
      {
        tenant_id: params.tenantId,
        employee_id: params.employeeId,
        override_date: params.overrideDate,
        override_type: params.overrideType,
        note: params.note ?? null,
      },
      { onConflict: 'employee_id,override_date' },
    )
    .select()
    .single()
  if (error) throw error
  return data
}

export async function deleteEmployeeDayOverride(overrideId: string): Promise<void> {
  const { error } = await supabase
    .from('employee_day_overrides')
    .delete()
    .eq('id', overrideId)
  if (error) throw error
}

// ─── Weekly Recurring Base (ADR-0003) ─────────────────────────────────────────
// Substitueix work_schedules/employee_schedule_assignments (retirades a EX-03.3).
// El patró es consulta en viu pel resolver — no es materialitza en overrides.

export interface WeeklyDayPattern {
  day_of_week: number
  day_type: 'work' | 'non_working'
  work_intervals: { start: string; end: string }[]
  valid_from: string
  valid_to: string | null
}

export async function getCalendarGroupWeeklyPattern(groupId: string): Promise<WeeklyDayPattern[]> {
  const { data, error } = await supabase.rpc('get_calendar_group_weekly_pattern' as never, {
    p_group_id: groupId,
  } as never)
  if (error) throw error
  return (data as unknown as WeeklyDayPattern[]) ?? []
}

export async function setCalendarGroupWeeklyDay(params: {
  groupId: string
  dayOfWeek: number
  dayType: 'work' | 'non_working'
  workIntervals?: { start: string; end: string }[] | null
  effectiveFrom?: string
}): Promise<void> {
  const { error } = await supabase.rpc('set_calendar_group_weekly_day' as never, {
    p_group_id: params.groupId,
    p_day_of_week: params.dayOfWeek,
    p_day_type: params.dayType,
    p_work_intervals: params.workIntervals?.length ? params.workIntervals : null,
    p_effective_from: params.effectiveFrom ?? null,
  } as never)
  if (error) throw error
}

export async function clearCalendarGroupWeeklyDay(params: {
  groupId: string
  dayOfWeek: number
  effectiveFrom?: string
}): Promise<void> {
  const { error } = await supabase.rpc('clear_calendar_group_weekly_day' as never, {
    p_group_id: params.groupId,
    p_day_of_week: params.dayOfWeek,
    p_effective_from: params.effectiveFrom ?? null,
  } as never)
  if (error) throw error
}

export async function getEmployeeWeeklyPattern(employeeId: string): Promise<WeeklyDayPattern[]> {
  const { data, error } = await supabase.rpc('get_employee_weekly_pattern' as never, {
    p_employee_id: employeeId,
  } as never)
  if (error) throw error
  return (data as unknown as WeeklyDayPattern[]) ?? []
}

export async function setEmployeeWeeklyDay(params: {
  employeeId: string
  dayOfWeek: number
  dayType: 'work' | 'non_working'
  workIntervals?: { start: string; end: string }[] | null
  effectiveFrom?: string
}): Promise<void> {
  const { error } = await supabase.rpc('set_employee_weekly_day' as never, {
    p_employee_id: params.employeeId,
    p_day_of_week: params.dayOfWeek,
    p_day_type: params.dayType,
    p_work_intervals: params.workIntervals?.length ? params.workIntervals : null,
    p_effective_from: params.effectiveFrom ?? null,
  } as never)
  if (error) throw error
}

export async function clearEmployeeWeeklyDay(params: {
  employeeId: string
  dayOfWeek: number
  effectiveFrom?: string
}): Promise<void> {
  const { error } = await supabase.rpc('clear_employee_weekly_day' as never, {
    p_employee_id: params.employeeId,
    p_day_of_week: params.dayOfWeek,
    p_effective_from: params.effectiveFrom ?? null,
  } as never)
  if (error) throw error
}

// ─── Admin Time Summaries ─────────────────────────────────────────────────────

export type { TimeDailySummary } from './timesheetService'
export { getAllTimeDailySummaries } from './timesheetService'
