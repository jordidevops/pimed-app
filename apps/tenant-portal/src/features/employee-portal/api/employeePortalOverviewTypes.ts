export type PortalAccessOverviewPortalFilter =
  | 'no_personal_link'
  | 'has_personal_link'
  | 'never_opened'
  | 'pin_not_configured'
  | 'missing_document_id'

export type PortalAccessOverviewSort = 'name' | 'last_access' | 'link_created'

export interface PortalAccessTokenSummary {
  has_active: boolean
  token_id: string | null
  pin_must_set?: boolean
  pin_required?: boolean
  pin_configured?: boolean
  first_accessed_at: string | null
  last_accessed_at: string | null
  created_at: string | null
  label: string | null
}

export interface PortalAccessOverviewRow {
  employee_id: string
  full_name: string | null
  document_id: string | null
  email: string | null
  site_id: string | null
  site_name: string | null
  department_id: string | null
  status: string | null
  missing_document_id: boolean
  site_configured: boolean
  last_access_any: string | null
  personal: PortalAccessTokenSummary
}

export interface PortalAccessOverviewSummary {
  total_employees: number
  without_personal_link: number
  never_opened: number
  missing_document_id: number
  identity_rejected_recent: number
}

export interface PortalAccessOverviewResult {
  summary: PortalAccessOverviewSummary
  rows: PortalAccessOverviewRow[]
  total: number
}

export interface PortalAccessOverviewQuery {
  siteId?: string | null
  departmentId?: string | null
  employeeStatus?: string | null
  portalFilter?: PortalAccessOverviewPortalFilter | null
  search?: string | null
  sort?: PortalAccessOverviewSort
  sortDir?: 'asc' | 'desc'
  limit?: number
  offset?: number
}
