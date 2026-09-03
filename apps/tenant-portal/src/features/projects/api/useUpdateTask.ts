import { useMutation, useQueryClient } from '@tanstack/react-query'
import { tasksKeys } from './tasksKeys'
import { projectsKeys } from './projectsKeys'
import { updateTask, type UpdateTaskParams } from './tasksService'

export function useUpdateTask(projectId: string) {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: ({ id, params }: { id: string; params: UpdateTaskParams }) =>
      updateTask(id, params),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: tasksKeys.byProject(projectId),
      })
      queryClient.invalidateQueries({
        queryKey: projectsKeys.detail(projectId),
      })
      queryClient.invalidateQueries({
        queryKey: ['projects'],
        predicate: (query) => query.queryKey.includes('list'),
      })
    },
  })
}
