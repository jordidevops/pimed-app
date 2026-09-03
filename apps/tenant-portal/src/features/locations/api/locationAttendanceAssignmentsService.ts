import { supabase } from '@/lib/supabase'

export interface LocationAttendanceAssignmentRow {
  id: string
  employee_id: string
  full_name: string
  location_id: string
  starts_on: string | null
  ends_on: string | null
  created_at: string
  inherited: boolean
  is_active_today?: boolean
}

export interface LocationAttendanceAssignmentsPayload {
  assignments: LocationAttendanceAssignmentRow[]
  scope_has_assignments: boolean
  assigned_count: number
  site_employee_count: number
}

export async function listLocationAttendanceAssignments(
  locationId: string,
  includeInactive = false,
): Promise<LocationAttendanceAssignmentsPayload> {
  const { data, error } = await supabase.rpc('list_attendance_location_assignments', {
    p_location_id: locationId,
    p_include_inactive: includeInactive,
  })
  if (error) throw error

  const payload = (data ?? {}) as Record<string, unknown>
  return {
    assignments: (payload.assignments ?? []) as LocationAttendanceAssignmentRow[],
    scope_has_assignments: Boolean(payload.scope_has_assignments),
    assigned_count: Number(payload.assigned_count ?? 0),
    site_employee_count: Number(payload.site_employee_count ?? 0),
  }
}

export async function addLocationAttendanceAssignment(input: {
  locationId: string
  employeeId: string
  startsOn?: string | null
  endsOn?: string | null
}) {
  const { data, error } = await supabase.rpc('add_attendance_location_assignment', {
    p_location_id: input.locationId,
    p_employee_id: input.employeeId,
    p_starts_on: input.startsOn ?? undefined,
    p_ends_on: input.endsOn ?? undefined,
  })
  if (error) throw error
  return data as { assignment_id: string }
}

export async function updateLocationAttendanceAssignment(input: {
  assignmentId: string
  startsOn?: string | null
  endsOn?: string | null
}) {
  const { data, error } = await supabase.rpc('update_attendance_location_assignment', {
    p_assignment_id: input.assignmentId,
    p_starts_on: input.startsOn ?? undefined,
    p_ends_on: input.endsOn ?? undefined,
  })
  if (error) throw error
  return data as { assignment_id: string; updated: boolean }
}

export async function bulkAddLocationAttendanceAssignments(input: {
  locationId: string
  employeeIds: string[]
  startsOn?: string | null
  endsOn?: string | null
}) {
  const { data, error } = await supabase.rpc('bulk_add_attendance_location_assignments', {
    p_location_id: input.locationId,
    p_employee_ids: input.employeeIds,
    p_starts_on: input.startsOn ?? undefined,
    p_ends_on: input.endsOn ?? undefined,
  })
  if (error) throw error
  return data as {
    ok: boolean
    created: number
    updated: number
    errors: Array<{ employee_id: string; code: string; message: string }>
  }
}

export async function removeLocationAttendanceAssignment(assignmentId: string) {
  const { data, error } = await supabase.rpc('remove_attendance_location_assignment', {
    p_assignment_id: assignmentId,
  })
  if (error) throw error
  return data as { removed: boolean }
}
