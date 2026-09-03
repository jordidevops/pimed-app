import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  createPayrollExportProfileFromTemplate,
  deletePayrollExportProfile,
  exportPayrollWithProfile,
  listPayrollExportProfiles,
  upsertPayrollExportProfile,
} from './payrollExportProfileService'
import type { PayrollExportProfile, PayrollExportProfileMapping } from './payrollConnectorTypes'

const QUERY_KEY = 'payroll-export-profiles'

export function usePayrollExportProfiles(tenantId: string | null) {
  return useQuery({
    queryKey: [QUERY_KEY, tenantId],
    queryFn: () => listPayrollExportProfiles(tenantId!),
    enabled: !!tenantId,
  })
}

export function useUpsertPayrollExportProfile(tenantId: string | null) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: {
      id?: string
      name: string
      connector: PayrollExportProfile['connector']
      source_mode: PayrollExportProfile['source_mode']
      output_format: PayrollExportProfile['output_format']
      mapping: PayrollExportProfileMapping
      is_active?: boolean
    }) => upsertPayrollExportProfile({ ...input, tenantId: tenantId! }),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: [QUERY_KEY, tenantId] })
    },
  })
}

export function useDeletePayrollExportProfile(tenantId: string | null) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => deletePayrollExportProfile(id),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: [QUERY_KEY, tenantId] })
    },
  })
}

export function useCreatePayrollExportProfileTemplate(tenantId: string | null) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (template: 'a3' | 'sage') =>
      createPayrollExportProfileFromTemplate(tenantId!, template),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: [QUERY_KEY, tenantId] })
    },
  })
}

export function useExportPayrollWithProfile() {
  return useMutation({
    mutationFn: exportPayrollWithProfile,
  })
}
