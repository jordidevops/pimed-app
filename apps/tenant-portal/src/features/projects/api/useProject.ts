import { useQuery } from '@tanstack/react-query'
import { projectsKeys } from './projectsKeys'
import { getProject } from './projectsService'

export function useProject(id: string) {
  return useQuery({
    queryKey: projectsKeys.detail(id),
    queryFn: () => getProject(id),
    enabled: !!id,
  })
}
