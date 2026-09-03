import { supabase } from '@/lib/supabase'
import type {
  PortalAccessOverviewQuery,
  PortalAccessOverviewResult,
} from './employeePortalOverviewTypes'

export async function listEmployeePortalAccessOverview(
  query: PortalAccessOverviewQuery = {},
): Promise<PortalAccessOverviewResult> {
  const { data, error } = await supabase.rpc('list_employee_portal_access_overview', {
    p_site_id: query.siteId || undefined,
    p_department_id: query.departmentId || undefined,
    p_employee_status: query.employeeStatus ?? 'active',
    p_portal_filter: query.portalFilter || undefined,
    p_search: query.search?.trim() || undefined,
    p_sort: query.sort ?? 'name',
    p_sort_dir: query.sortDir ?? 'asc',
    p_limit: query.limit ?? 50,
    p_offset: query.offset ?? 0,
  })

  if (error) throw error

  const payload = (data as PortalAccessOverviewResult | null) ?? {
    summary: {
      total_employees: 0,
      without_personal_link: 0,
      never_opened: 0,
      missing_document_id: 0,
      identity_rejected_recent: 0,
    },
    rows: [],
    total: 0,
  }

  return {
    summary: payload.summary,
    rows: payload.rows ?? [],
    total: payload.total ?? 0,
  }
}
