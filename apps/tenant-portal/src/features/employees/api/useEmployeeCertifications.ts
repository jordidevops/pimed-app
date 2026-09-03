import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { useTenant } from '@/contexts/TenantContext'
import {
  generateMedicalClearanceDocument,
  startMedicalClearanceSigning,
} from './medicalClearanceSigningService'

export type EmployeeCertification = {
  id: string
  tenant_id: string
  employee_id: string
  requirement_type_id: string
  issuer: string | null
  credential_number: string | null
  issued_on: string | null
  valid_from: string
  valid_until: string | null
  document_id: string | null
  revoked_at: string | null
  revoked_reason: string | null
  notes: string | null
  created_by: string
  created_at: string
  updated_at: string
  computed_status: string
  requirement_code: string
  requirement_name: string
  requirement_category: 'legal' | 'medical' | 'technical' | 'other'
  signing_submission_id?: string | null
}

export function useEmployeeCertifications(employeeId: string | undefined, includeRevoked = false) {
  const { activeTenant, tenantScopeReady } = useTenant()
  const tenantId = activeTenant?.id

  return useQuery({
    queryKey: ['employee-certifications', tenantId, employeeId, includeRevoked],
    enabled: tenantScopeReady && !!tenantId && !!employeeId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_employee_certifications' as never, {
        p_employee_id: employeeId,
        p_include_revoked: includeRevoked,
      } as never)
      if (error) throw error
      return (data ?? []) as EmployeeCertification[]
    },
  })
}

export function useUpsertEmployeeCertification() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (params: {
      id?: string | null
      employee_id: string
      requirement_type_id: string
      issuer?: string | null
      credential_number?: string | null
      issued_on?: string | null
      valid_from?: string | null
      valid_until?: string | null
      notes?: string | null
    }) => {
      const { data, error } = await supabase.rpc('upsert_employee_certification' as never, {
        p_id: params.id ?? null,
        p_employee_id: params.employee_id,
        p_requirement_type_id: params.requirement_type_id,
        p_issuer: params.issuer ?? null,
        p_credential_number: params.credential_number ?? null,
        p_issued_on: params.issued_on ?? null,
        p_valid_from: params.valid_from ?? null,
        p_valid_until: params.valid_until ?? null,
        p_document_id: null,
        p_notes: params.notes ?? null,
      } as never)
      if (error) throw error
      return data as EmployeeCertification
    },
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: ['employee-certifications'] })
      void qc.invalidateQueries({ queryKey: ['employee-certifications', undefined, vars.employee_id] })
    },
  })
}

export function useRevokeEmployeeCertification() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (params: { id: string; reason?: string | null; employee_id: string }) => {
      const { data, error } = await supabase.rpc('revoke_employee_certification' as never, {
        p_id: params.id,
        p_reason: params.reason ?? null,
      } as never)
      if (error) throw error
      return data as EmployeeCertification
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['employee-certifications'] })
    },
  })
}

export function useGenerateMedicalClearanceDocument(employeeId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (params: { certificationId: string; force?: boolean }) =>
      generateMedicalClearanceDocument(params),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['employee-certifications'] })
      void qc.invalidateQueries({ queryKey: ['employee-certifications', undefined, employeeId] })
    },
  })
}

export function useStartMedicalClearanceSigning(employeeId: string) {
  const qc = useQueryClient()
  const { activeTenant } = useTenant()
  const { user } = useAuth()
  return useMutation({
    mutationFn: (certificationId: string) => {
      if (!activeTenant?.id || !user?.id) {
        throw new Error('Falta tenant o usuari autenticat')
      }
      return startMedicalClearanceSigning({
        tenantId: activeTenant.id,
        certificationId,
        userId: user.id,
        officerEmail: user.email,
        officerName: user.user_metadata?.full_name ?? user.email ?? null,
      })
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['employee-certifications'] })
      void qc.invalidateQueries({ queryKey: ['employee-certifications', undefined, employeeId] })
    },
  })
}
