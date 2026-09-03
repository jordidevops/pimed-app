import { useQuery } from '@tanstack/react-query'
import { tasksKeys } from './tasksKeys'
import { getTasks } from './tasksService'

export function useTasks(projectId: string) {
  return useQuery({
    queryKey: tasksKeys.byProject(projectId),
    queryFn: () => getTasks(projectId),
    enabled: !!projectId,
  })
}
