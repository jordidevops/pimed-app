import { useQuery } from '@tanstack/react-query'
import { projectsKeys } from './projectsKeys'
import { getProjectsPage, type ProjectListParams } from './projectsService'
import { useTenant } from '@/contexts/TenantContext'

export function useProjects(params: ProjectListParams) {
  const { activeTenant } = useTenant()
  const tenantId = activeTenant?.id ?? ''

  return useQuery({
    queryKey: projectsKeys.list(tenantId, params),
    queryFn: () => getProjectsPage(tenantId, params),
    enabled: !!tenantId,
  })
}
