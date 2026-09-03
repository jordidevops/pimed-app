import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTenant } from '@/contexts/TenantContext'
import {
  createJobPosition,
  deleteJobPosition,
  getJobPositions,
  updateJobPosition,
  type JobPosition,
  type JobPositionInsert,
  type JobPositionUpdate,
} from './jobPositionsService'

export function useJobPositions(activeOnly = false) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: ['job-positions', activeTenant?.id ?? '', activeOnly],
    queryFn: () => getJobPositions(activeOnly),
    enabled: !!activeTenant?.id,
  })
}

export function useCreateJobPosition() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (params: Pick<JobPositionInsert, 'tenant_id' | 'name' | 'code' | 'description' | 'department_id' | 'is_active'>) =>
      createJobPosition(params),
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['job-positions'] }),
  })
}

export function useUpdateJobPosition() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, params }: { id: string; params: JobPositionUpdate }) => updateJobPosition(id, params),
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['job-positions'] }),
  })
}

export function useDeleteJobPosition() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => deleteJobPosition(id),
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['job-positions'] }),
  })
}

export type { JobPosition }
