import { useMutation, useQueryClient } from '@tanstack/react-query'
import { tasksKeys } from './tasksKeys'
import { projectsKeys } from './projectsKeys'
import { createTask } from './tasksService'
import type { CreateTaskParams } from './tasksService'

export function useCreateTask(projectId: string) {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: (params: CreateTaskParams) => createTask(params),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: tasksKeys.byProject(projectId),
      })
      queryClient.invalidateQueries({
        queryKey: projectsKeys.detail(projectId),
      })
      // Invalidate all project lists (task_count/pending_task_count are in the list view)
      queryClient.invalidateQueries({
        queryKey: ['projects'],
        predicate: (query) => query.queryKey.includes('list'),
      })
    },
  })
}
