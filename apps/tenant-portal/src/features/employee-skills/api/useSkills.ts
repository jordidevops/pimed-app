import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTenant } from '@/contexts/TenantContext'
import {
  createSkill,
  createSkillLevel,
  createSkillType,
  deleteEmployeeSkill,
  deleteSkill,
  deleteSkillLevel,
  deleteSkillType,
  getEmployeeSkills,
  getEmployeeSkillsSummary,
  getSkillLevels,
  getSkillLevelsByTypeIds,
  getSkills,
  getSkillTypes,
  searchEmployeesBySkills,
  updateSkill,
  updateSkillLevel,
  updateSkillType,
  type SkillSearchCriterion,
  type SkillSearchMatchMode,
  upsertEmployeeSkill,
} from './skillsService'

export function useSkillTypes(activeOnly = true) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: ['skill-types', activeTenant?.id ?? '', activeOnly],
    queryFn: () => getSkillTypes(activeOnly),
    enabled: !!activeTenant?.id,
  })
}

export function useSkills(skillTypeId?: string | null, activeOnly = true) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: ['skills', activeTenant?.id ?? '', skillTypeId ?? 'all', activeOnly],
    queryFn: () => getSkills(skillTypeId ?? undefined, activeOnly),
    enabled: !!activeTenant?.id,
  })
}

export function useSkillLevels(skillTypeId?: string | null) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: ['skill-levels', activeTenant?.id ?? '', skillTypeId ?? ''],
    queryFn: () => getSkillLevels(skillTypeId!),
    enabled: !!activeTenant?.id && !!skillTypeId,
  })
}

export function useSkillLevelsByTypeIds(typeIds: string[]) {
  const { activeTenant } = useTenant()
  const key = [...typeIds].sort().join(',')
  return useQuery({
    queryKey: ['skill-levels-multi', activeTenant?.id ?? '', key],
    queryFn: () => getSkillLevelsByTypeIds(typeIds),
    enabled: !!activeTenant?.id && typeIds.length > 0,
  })
}

export function useEmployeeSkills(employeeId?: string) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: ['employee-skills', activeTenant?.id ?? '', employeeId ?? ''],
    queryFn: () => getEmployeeSkills(employeeId!),
    enabled: !!activeTenant?.id && !!employeeId,
  })
}

export function useCreateSkillType() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: createSkillType,
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['skill-types'] }),
  })
}

function invalidateCatalog(qc: ReturnType<typeof useQueryClient>) {
  void qc.invalidateQueries({ queryKey: ['skill-types'] })
  void qc.invalidateQueries({ queryKey: ['skills'] })
  void qc.invalidateQueries({ queryKey: ['skill-levels'] })
  void qc.invalidateQueries({ queryKey: ['skill-levels-multi'] })
  void qc.invalidateQueries({ queryKey: ['employee-skills-summary'] })
  void qc.invalidateQueries({ queryKey: ['skill-search-multi'] })
}

export function useUpdateSkillType() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: updateSkillType,
    onSuccess: () => invalidateCatalog(qc),
  })
}

export function useDeleteSkillType() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: deleteSkillType,
    onSuccess: () => invalidateCatalog(qc),
  })
}

export function useCreateSkill() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: createSkill,
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['skills'] }),
  })
}

export function useUpdateSkill() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: updateSkill,
    onSuccess: () => invalidateCatalog(qc),
  })
}

export function useDeleteSkill() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: deleteSkill,
    onSuccess: () => invalidateCatalog(qc),
  })
}

export function useCreateSkillLevel() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: createSkillLevel,
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['skill-levels'] }),
  })
}

export function useUpdateSkillLevel() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: updateSkillLevel,
    onSuccess: () => invalidateCatalog(qc),
  })
}

export function useDeleteSkillLevel() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: deleteSkillLevel,
    onSuccess: () => invalidateCatalog(qc),
  })
}

export function useUpsertEmployeeSkill() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: upsertEmployeeSkill,
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['employee-skills'] })
      void qc.invalidateQueries({ queryKey: ['employee-skills-summary'] })
    },
  })
}

export function useDeleteEmployeeSkill() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: deleteEmployeeSkill,
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['employee-skills'] })
      void qc.invalidateQueries({ queryKey: ['employee-skills-summary'] })
    },
  })
}

export function useSearchEmployeesBySkills(params: {
  criteria: SkillSearchCriterion[]
  matchMode: SkillSearchMatchMode
  siteId?: string | null
  enabled?: boolean
}) {
  const { activeTenant } = useTenant()
  const criteriaKey = JSON.stringify(params.criteria)
  return useQuery({
    queryKey: [
      'skill-search-multi',
      activeTenant?.id ?? '',
      criteriaKey,
      params.matchMode,
      params.siteId ?? '',
    ],
    queryFn: () =>
      searchEmployeesBySkills({
        criteria: params.criteria,
        matchMode: params.matchMode,
        siteId: params.siteId,
      }),
    enabled:
      !!activeTenant?.id &&
      params.criteria.length > 0 &&
      (params.enabled ?? true),
  })
}

export function useEmployeeSkillsSummary(siteId?: string | null) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: ['employee-skills-summary', activeTenant?.id ?? '', siteId ?? ''],
    queryFn: () => getEmployeeSkillsSummary(siteId),
    enabled: !!activeTenant?.id,
  })
}
