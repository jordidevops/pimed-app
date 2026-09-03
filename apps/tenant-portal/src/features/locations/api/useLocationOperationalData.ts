import { useQuery } from '@tanstack/react-query'
import { useTenant } from '@/contexts/TenantContext'
import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'

type AssetRow = Database['api']['Views']['assets']['Row']
type ProjectRow = Database['api']['Views']['projects']['Row']
type WorkLogRow = Database['api']['Views']['work_logs']['Row']

export interface LocationOperationalData {
  assets: AssetRow[]
  projects: ProjectRow[]
  openWorkLogs: WorkLogRow[]
}

export function useLocationOperationalData() {
  const { activeTenant, activeSite } = useTenant()
  const tenantId = activeTenant?.id ?? ''
  const siteId = activeSite?.id ?? null
  const hasSiteSelected = !!siteId

  return useQuery<LocationOperationalData>({
    queryKey: ['locations', 'operational-data', tenantId, siteId ?? 'all'],
    enabled: !!tenantId && hasSiteSelected,
    queryFn: async () => {
      if (!tenantId || !siteId) {
        return { assets: [], projects: [], openWorkLogs: [] }
      }

      let assetsQuery = supabase
        .from('assets')
        .select('*')
        .eq('tenant_id', tenantId)

      let projectsQuery = supabase
        .from('projects')
        .select('*')
        .eq('tenant_id', tenantId)

      let workLogsQuery = supabase
        .from('work_logs')
        .select('*')
        .eq('tenant_id', tenantId)
        .eq('status', 'open')

      assetsQuery = assetsQuery.eq('site_id', siteId)
      projectsQuery = projectsQuery.eq('site_id', siteId)
      workLogsQuery = workLogsQuery.eq('site_id', siteId)

      const [assetsRes, projectsRes, workLogsRes] = await Promise.all([
        assetsQuery,
        projectsQuery,
        workLogsQuery,
      ])

      if (assetsRes.error) throw assetsRes.error
      if (projectsRes.error) throw projectsRes.error
      if (workLogsRes.error) throw workLogsRes.error

      return {
        assets: (assetsRes.data ?? []) as AssetRow[],
        projects: (projectsRes.data ?? []) as ProjectRow[],
        openWorkLogs: (workLogsRes.data ?? []) as WorkLogRow[],
      }
    },
    staleTime: 1000 * 60,
  })
}
