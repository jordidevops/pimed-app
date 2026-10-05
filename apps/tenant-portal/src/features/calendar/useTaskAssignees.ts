import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useTenant } from '@/contexts/TenantContext'

/** Loads assignee_id for task entity ids (used by «Els meus» filter). */
export function useTaskAssignees(taskIds: string[], enabled: boolean) {
  const { selectedTenantId } = useTenant()
  const sortedKey = [...taskIds].sort().join(',')

  return useQuery({
    queryKey: ['calendar_task_assignees', selectedTenantId, sortedKey],
    enabled: enabled && !!selectedTenantId && taskIds.length > 0,
    staleTime: 60_000,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('tasks')
        .select('id, assignee_id')
        .eq('tenant_id', selectedTenantId!)
        .in('id', taskIds)
      if (error) throw error
      const map = new Map<string, string | null>()
      for (const row of data ?? []) {
        if (row.id) map.set(row.id, row.assignee_id ?? null)
      }
      return map
    },
  })
}
