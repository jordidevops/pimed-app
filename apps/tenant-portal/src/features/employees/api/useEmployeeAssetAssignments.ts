import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useTenant } from '@/contexts/TenantContext'

export type ReturnCondition = 'good' | 'damaged' | 'lost'

export type EmployeeAssetAssignment = {
  id: string
  tenant_id: string
  asset_id: string
  employee_id: string
  assigned_at: string
  assigned_by: string
  expected_return_at: string | null
  returned_at: string | null
  return_condition: ReturnCondition | null
  returned_by: string | null
  acknowledgment_document_id: string | null
  return_document_id: string | null
  notes: string | null
  created_at: string
  asset_name: string | null
  asset_tag: string | null
  asset_status: string | null
  asset_type_id: string | null
  asset_site_id: string | null
  employee_name: string | null
  asset_requires_calibration: boolean | null
  asset_calibration_due_on: string | null
}

export type AssetCalibrationAlert = {
  asset_id: string
  asset_name: string
  asset_tag: string | null
  calibration_due_on: string
  requires_calibration: boolean
  asset_status: string
  site_id: string
  days_left: number
  is_notice_day: boolean
  employee_id: string | null
  employee_name: string | null
  assignment_id: string | null
}

export type AssetCalibrationAlertsReport = {
  as_of: string
  within_days: number
  count: number
  alerts: AssetCalibrationAlert[]
}

export type AssignableAsset = {
  id: string
  name: string
  asset_tag: string | null
  status: string
  site_id: string
  asset_type_id: string | null
}

function assignmentsKey(tenantId: string, employeeId: string) {
  return ['employee-asset-assignments', tenantId, employeeId] as const
}

export function useEmployeeAssetAssignments(employeeId?: string, includeReturned = true) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: [...assignmentsKey(activeTenant?.id ?? '', employeeId ?? ''), includeReturned],
    enabled: !!activeTenant?.id && !!employeeId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_employee_asset_assignments', {
        p_employee_id: employeeId!,
        p_include_returned: includeReturned,
      })
      if (error) throw error
      return (data ?? []) as EmployeeAssetAssignment[]
    },
  })
}

export function useAssignableAssets(siteId?: string | null) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: ['assignable-assets', activeTenant?.id ?? '', siteId ?? ''],
    enabled: !!activeTenant?.id,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_assignable_assets', {
        p_site_id: siteId ?? undefined,
      })
      if (error) throw error
      return (data ?? []) as AssignableAsset[]
    },
  })
}

export function useAssignEmployeeAsset(employeeId: string) {
  const qc = useQueryClient()
  const { activeTenant } = useTenant()
  return useMutation({
    mutationFn: async (input: {
      assetId: string
      expectedReturnAt?: string | null
      notes?: string | null
    }) => {
      const { data, error } = await supabase.rpc('assign_employee_asset', {
        p_asset_id: input.assetId,
        p_employee_id: employeeId,
        p_expected_return_at: input.expectedReturnAt ?? undefined,
        p_notes: input.notes ?? undefined,
      })
      if (error) throw error
      return data as EmployeeAssetAssignment
    },
    onSuccess: () => {
      if (activeTenant?.id) {
        void qc.invalidateQueries({ queryKey: assignmentsKey(activeTenant.id, employeeId) })
        void qc.invalidateQueries({ queryKey: ['assignable-assets', activeTenant.id] })
      }
    },
  })
}

export function useReturnEmployeeAsset(employeeId: string) {
  const qc = useQueryClient()
  const { activeTenant } = useTenant()
  return useMutation({
    mutationFn: async (input: {
      assetId: string
      condition: ReturnCondition
      notes?: string | null
      returnDocumentId?: string | null
    }) => {
      const { data, error } = await supabase.rpc('return_employee_asset', {
        p_asset_id: input.assetId,
        p_condition: input.condition,
        p_return_document_id: input.returnDocumentId ?? undefined,
        p_notes: input.notes ?? undefined,
      })
      if (error) throw error
      return data as EmployeeAssetAssignment
    },
    onSuccess: () => {
      if (activeTenant?.id) {
        void qc.invalidateQueries({ queryKey: assignmentsKey(activeTenant.id, employeeId) })
        void qc.invalidateQueries({ queryKey: ['assignable-assets', activeTenant.id] })
      }
    },
  })
}

export function useGenerateAssetAcknowledgmentDocument(employeeId: string) {
  const qc = useQueryClient()
  const { activeTenant } = useTenant()
  return useMutation({
    mutationFn: async (input: { assignmentId: string; force?: boolean }) => {
      const { data, error } = await supabase.rpc('generate_employee_asset_acknowledgment_document', {
        p_assignment_id: input.assignmentId,
        p_force: input.force ?? false,
      })
      if (error) throw error
      return data as EmployeeAssetAssignment
    },
    onSuccess: () => {
      if (activeTenant?.id) {
        void qc.invalidateQueries({ queryKey: assignmentsKey(activeTenant.id, employeeId) })
      }
    },
  })
}

export function useGenerateAssetReturnDocument(employeeId: string) {
  const qc = useQueryClient()
  const { activeTenant } = useTenant()
  return useMutation({
    mutationFn: async (input: { assignmentId: string; force?: boolean }) => {
      const { data, error } = await supabase.rpc('generate_employee_asset_return_document', {
        p_assignment_id: input.assignmentId,
        p_force: input.force ?? false,
      })
      if (error) throw error
      return data as EmployeeAssetAssignment
    },
    onSuccess: () => {
      if (activeTenant?.id) {
        void qc.invalidateQueries({ queryKey: assignmentsKey(activeTenant.id, employeeId) })
      }
    },
  })
}

export function useAssetCalibrationAlerts(employeeId?: string, withinDays = 30) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: [
      'asset-calibration-alerts',
      activeTenant?.id ?? '',
      employeeId ?? '',
      withinDays,
    ],
    enabled: !!activeTenant?.id && !!employeeId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_asset_calibration_alerts', {
        p_employee_id: employeeId!,
        p_within_days: withinDays,
      })
      if (error) throw error
      const rep = (data ?? {}) as AssetCalibrationAlertsReport
      return {
        as_of: rep.as_of,
        within_days: rep.within_days ?? withinDays,
        count: rep.count ?? 0,
        alerts: rep.alerts ?? [],
      } satisfies AssetCalibrationAlertsReport
    },
  })
}
