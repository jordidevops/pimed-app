import { useMutation, useQueryClient } from '@tanstack/react-query'
import { tasksKeys } from './tasksKeys'
import { projectsKeys } from './projectsKeys'
import { deleteTask } from './tasksService'

export function useDeleteTask(projectId: string) {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: (id: string) => deleteTask(id),
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
