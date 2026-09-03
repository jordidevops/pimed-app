import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTenant } from '@/contexts/TenantContext'
import {
  ensureEmployeeTag,
  getEmployeeTagAssignments,
  getEmployeeTags,
  setEmployeeTags,
} from './employeeTagsService'

export function useEmployeeTags(activeOnly = true) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: ['employee-tags', activeTenant?.id ?? '', activeOnly],
    queryFn: () => getEmployeeTags(activeOnly),
    enabled: !!activeTenant?.id,
  })
}

export function useEmployeeTagAssignments(employeeId?: string) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: ['employee-tag-assignments', activeTenant?.id ?? '', employeeId ?? ''],
    queryFn: () => getEmployeeTagAssignments(employeeId!),
    enabled: !!activeTenant?.id && !!employeeId,
  })
}

export function useSetEmployeeTags(employeeId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (tagIds: string[]) => setEmployeeTags(employeeId, tagIds),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['employee-tag-assignments'] })
      void qc.invalidateQueries({ queryKey: ['employee-tags'] })
    },
  })
}

export function useEnsureEmployeeTag() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (name: string) => ensureEmployeeTag(name),
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['employee-tags'] }),
  })
}
