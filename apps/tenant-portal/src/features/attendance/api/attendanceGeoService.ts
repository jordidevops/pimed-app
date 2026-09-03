import { supabase } from '@/lib/supabase'

export async function fetchAttendanceGeoEnabled(employeeId: string): Promise<boolean> {
  const { data, error } = await supabase.rpc('get_attendance_geo_enabled' as never, {
    p_employee_id: employeeId,
  } as never)

  if (error) throw new Error(error.message)
  return Boolean(data)
}
