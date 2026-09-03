import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTenant } from '@/contexts/TenantContext'
import { useAuth } from '@/contexts/AuthContext'
import { startEmploymentContractSigning } from './employmentContractSigningService'
import {
  createEmploymentContract,
  createEmploymentContractRenewal,
  getEffectiveEmploymentContract,
  generateEmploymentContractDocument,
  listEmploymentContractAlerts,
  listEmploymentContractTypes,
  listEmploymentContracts,
  reconcileEmploymentContracts,
  resolveEmployeeContractTerms,
  resolveEmployeeWorkContext,
  transitionEmploymentContract,
  updateEmploymentContract,
  type ContractLifecycleStatus,
  type EmploymentContractInsert,
  type EmploymentContractUpdate,
} from './employmentContractsService'

function contractsKey(tenantId: string, employeeId: string) {
  return ['employment-contracts', tenantId, employeeId] as const
}

export function useEmploymentContracts(employeeId?: string) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: contractsKey(activeTenant?.id ?? '', employeeId ?? ''),
    queryFn: () => listEmploymentContracts(employeeId!),
    enabled: !!activeTenant?.id && !!employeeId,
  })
}

export function useEmploymentContractTypes(activeOnly = true) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: ['employment-contract-types', activeTenant?.id ?? '', activeOnly],
    queryFn: () => listEmploymentContractTypes(activeOnly),
    enabled: !!activeTenant?.id,
  })
}

export function useEffectiveEmploymentContract(employeeId?: string) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: ['employment-contract-effective', activeTenant?.id ?? '', employeeId ?? ''],
    queryFn: () => getEffectiveEmploymentContract(employeeId!),
    enabled: !!activeTenant?.id && !!employeeId,
  })
}

export function useEmployeeContractTerms(employeeId?: string) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: ['employment-contract-terms', activeTenant?.id ?? '', employeeId ?? ''],
    queryFn: () => resolveEmployeeContractTerms(employeeId!),
    enabled: !!activeTenant?.id && !!employeeId,
  })
}

export function useEmployeeWorkContext(employeeId?: string, workDate?: string) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: [
      'employment-work-context',
      activeTenant?.id ?? '',
      employeeId ?? '',
      workDate ?? 'today',
    ],
    queryFn: () => resolveEmployeeWorkContext(employeeId!, workDate),
    enabled: !!activeTenant?.id && !!employeeId,
  })
}

function invalidateContractAndEmployee(
  qc: ReturnType<typeof useQueryClient>,
  tenantId: string | undefined,
  employeeId: string,
) {
  if (!tenantId) return
  void qc.invalidateQueries({ queryKey: contractsKey(tenantId, employeeId) })
  void qc.invalidateQueries({
    queryKey: ['employment-contract-effective', tenantId, employeeId],
  })
  void qc.invalidateQueries({
    queryKey: ['employment-contract-terms', tenantId, employeeId],
  })
  void qc.invalidateQueries({
    queryKey: ['employment-work-context', tenantId, employeeId],
  })
  void qc.invalidateQueries({ queryKey: ['employees', tenantId] })
  void qc.invalidateQueries({ queryKey: ['employees', tenantId, 'detail', employeeId] })
  void qc.invalidateQueries({ queryKey: ['employee', employeeId] })
}

export function useCreateEmploymentContract(employeeId: string) {
  const qc = useQueryClient()
  const { activeTenant } = useTenant()
  return useMutation({
    mutationFn: (row: Omit<EmploymentContractInsert, 'tenant_id' | 'employee_id'> & {
      tenant_id?: string
    }) =>
      createEmploymentContract({
        ...row,
        tenant_id: row.tenant_id ?? activeTenant!.id,
        employee_id: employeeId,
      }),
    onSuccess: () => {
      invalidateContractAndEmployee(qc, activeTenant?.id, employeeId)
    },
  })
}

export function useUpdateEmploymentContract(employeeId: string) {
  const qc = useQueryClient()
  const { activeTenant } = useTenant()
  return useMutation({
    mutationFn: ({ id, patch }: { id: string; patch: EmploymentContractUpdate }) =>
      updateEmploymentContract(id, patch),
    onSuccess: () => {
      invalidateContractAndEmployee(qc, activeTenant?.id, employeeId)
    },
  })
}

export function useTransitionEmploymentContract(employeeId: string) {
  const qc = useQueryClient()
  const { activeTenant } = useTenant()
  return useMutation({
    mutationFn: ({
      contractId,
      toStatus,
      reason,
    }: {
      contractId: string
      toStatus: ContractLifecycleStatus
      reason?: string | null
    }) => transitionEmploymentContract(contractId, toStatus, reason),
    onSuccess: () => {
      invalidateContractAndEmployee(qc, activeTenant?.id, employeeId)
    },
  })
}

export function useReconcileEmploymentContracts(employeeId: string) {
  const qc = useQueryClient()
  const { activeTenant } = useTenant()
  return useMutation({
    mutationFn: () => reconcileEmploymentContracts(employeeId),
    onSuccess: () => {
      invalidateContractAndEmployee(qc, activeTenant?.id, employeeId)
    },
  })
}

export function useEmploymentContractAlerts(employeeId?: string) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: ['employment-contract-alerts', activeTenant?.id ?? '', employeeId ?? ''],
    queryFn: () => listEmploymentContractAlerts(employeeId!),
    enabled: !!activeTenant?.id && !!employeeId,
  })
}

export function useCreateEmploymentContractRenewal(employeeId: string) {
  const qc = useQueryClient()
  const { activeTenant } = useTenant()
  return useMutation({
    mutationFn: (contractId: string) => createEmploymentContractRenewal(contractId),
    onSuccess: () => {
      invalidateContractAndEmployee(qc, activeTenant?.id, employeeId)
      if (activeTenant?.id) {
        void qc.invalidateQueries({
          queryKey: ['employment-contract-alerts', activeTenant.id, employeeId],
        })
      }
    },
  })
}

export function useGenerateEmploymentContractDocument(employeeId: string) {
  const qc = useQueryClient()
  const { activeTenant } = useTenant()
  return useMutation({
    mutationFn: (params: {
      contractId: string
      templateLocaleId?: string | null
      force?: boolean
    }) => generateEmploymentContractDocument(params),
    onSuccess: () => {
      if (activeTenant?.id) {
        void qc.invalidateQueries({ queryKey: contractsKey(activeTenant.id, employeeId) })
      }
    },
  })
}

export function useStartEmploymentContractSigning(employeeId: string) {
  const qc = useQueryClient()
  const { activeTenant } = useTenant()
  const { user } = useAuth()
  return useMutation({
    mutationFn: (contractId: string) => {
      if (!activeTenant?.id || !user?.id) {
        throw new Error('Falta tenant o usuari autenticat')
      }
      return startEmploymentContractSigning({
        tenantId: activeTenant.id,
        contractId,
        userId: user.id,
        employerEmail: user.email,
        employerName: user.user_metadata?.full_name ?? user.email ?? null,
      })
    },
    onSuccess: () => {
      if (activeTenant?.id) {
        void qc.invalidateQueries({ queryKey: contractsKey(activeTenant.id, employeeId) })
      }
    },
  })
}
