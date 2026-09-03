import { useMutation, useQueryClient } from '@tanstack/react-query'
import { tasksKeys } from './tasksKeys'
import { projectsKeys } from './projectsKeys'
import { bulkUpdateTaskStatus } from './tasksService'

export function useBulkUpdateTaskStatus(projectId: string) {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: ({
      taskIds,
      newStatus,
      tenantId,
    }: {
      taskIds: string[]
      newStatus: string
      tenantId: string
    }) => bulkUpdateTaskStatus(taskIds, newStatus, tenantId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: tasksKeys.byProject(projectId) })
      queryClient.invalidateQueries({ queryKey: projectsKeys.detail(projectId) })
      queryClient.invalidateQueries({
        queryKey: ['projects'],
        predicate: (query) => query.queryKey.includes('list'),
      })
    },
  })
}
