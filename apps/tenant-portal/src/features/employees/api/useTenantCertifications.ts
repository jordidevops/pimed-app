import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useTenant } from '@/contexts/TenantContext'

export type TenantCertificationRow = {
  id: string
  tenant_id: string
  employee_id: string
  employee_name: string
  site_id: string | null
  department_id: string | null
  requirement_type_id: string
  requirement_code: string
  requirement_name: string
  requirement_category: string
  issuer: string | null
  credential_number: string | null
  issued_on: string | null
  valid_from: string
  valid_until: string | null
  document_id: string | null
  revoked_at: string | null
  computed_status: string
  created_at: string
}

export type CertificationStatusFilter =
  | ''
  | 'active'
  | 'expiring_soon'
  | 'expired'
  | 'indefinite'
  | 'not_yet_valid'

export function useTenantCertifications(filters: {
  computedStatus?: CertificationStatusFilter
  siteId?: string | null
  departmentId?: string | null
  includeRevoked?: boolean
}) {
  const { activeTenant, tenantScopeReady } = useTenant()
  const tenantId = activeTenant?.id

  return useQuery({
    queryKey: [
      'tenant-certifications',
      tenantId,
      filters.computedStatus ?? '',
      filters.siteId ?? '',
      filters.departmentId ?? '',
      filters.includeRevoked ?? false,
    ],
    enabled: tenantScopeReady && !!tenantId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_tenant_certifications', {
        p_computed_status: filters.computedStatus || undefined,
        p_site_id: filters.siteId || undefined,
        p_department_id: filters.departmentId || undefined,
        p_include_revoked: filters.includeRevoked ?? false,
        p_limit: 200,
        p_offset: 0,
      })
      if (error) throw error
      return (data ?? []) as TenantCertificationRow[]
    },
    staleTime: 15_000,
  })
}
