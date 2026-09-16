import { useQuery } from '@tanstack/react-query'
import { projectsKeys } from './projectsKeys'
import { getProject, type Project } from './projectsService'
import { useTenant } from '@/contexts/TenantContext'
import { getFieldProjectSnapshot, patchFieldProjectSnapshot } from '@/lib/today-cache'

export function useProject(id: string) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: projectsKeys.detail(id),
    queryFn: async () => {
      try {
        const project = await getProject(id)
        if (activeTenant?.id && project) {
          await patchFieldProjectSnapshot(activeTenant.id, id, { project })
        }
        return project
      } catch (error) {
        if (!activeTenant?.id || navigator.onLine) throw error
        const snapshot = await getFieldProjectSnapshot(activeTenant.id, id)
        if (!snapshot?.project) throw error
        return snapshot.project as Project
      }
    },
    enabled: !!id,
  })
}
