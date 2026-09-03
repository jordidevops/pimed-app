import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useTenant } from '@/contexts/TenantContext'

export type AssetReturnChecklist = {
  id: string
  tenant_id: string
  employee_id: string
  lifecycle_event_id: string | null
  status: 'open' | 'completed' | 'waived'
  created_at: string
  completed_at: string | null
  completed_by: string | null
  waive_reason: string | null
  notes: string | null
}

export type AssetReturnChecklistItem = {
  id: string
  checklist_id: string
  tenant_id: string
  assignment_id: string
  asset_id: string
  status: 'pending' | 'returned' | 'waived'
  created_at: string
  resolved_at: string | null
  resolved_by: string | null
  waive_reason: string | null
  asset_name: string | null
  asset_tag: string | null
  assigned_at: string | null
  assignment_returned_at: string | null
  return_condition: string | null
}

export type AssetReturnChecklistReport = {
  checklist: AssetReturnChecklist | null
  items: AssetReturnChecklistItem[]
  pending_count: number
  open_assignments_count: number
}

function checklistKey(tenantId: string, employeeId: string) {
  return ['employee-asset-return-checklist', tenantId, employeeId] as const
}

export function useEmployeeAssetReturnChecklist(employeeId?: string) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: checklistKey(activeTenant?.id ?? '', employeeId ?? ''),
    enabled: !!activeTenant?.id && !!employeeId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_employee_asset_return_checklist', {
        p_employee_id: employeeId!,
        p_include_closed: true,
      })
      if (error) throw error
      const rep = (data ?? {}) as AssetReturnChecklistReport
      return {
        checklist: rep.checklist ?? null,
        items: rep.items ?? [],
        pending_count: rep.pending_count ?? 0,
        open_assignments_count: rep.open_assignments_count ?? 0,
      } satisfies AssetReturnChecklistReport
    },
  })
}

export function useWaiveAssetReturnChecklistItem(employeeId: string) {
  const qc = useQueryClient()
  const { activeTenant } = useTenant()
  return useMutation({
    mutationFn: async (input: { itemId: string; reason?: string | null }) => {
      const { data, error } = await supabase.rpc('waive_employee_asset_return_checklist_item', {
        p_item_id: input.itemId,
        p_reason: input.reason ?? undefined,
      })
      if (error) throw error
      return data as AssetReturnChecklistItem
    },
    onSuccess: () => {
      if (activeTenant?.id) {
        void qc.invalidateQueries({ queryKey: checklistKey(activeTenant.id, employeeId) })
        void qc.invalidateQueries({
          queryKey: ['employee-asset-assignments', activeTenant.id, employeeId],
        })
      }
    },
  })
}

export function useWaiveAssetReturnChecklist(employeeId: string) {
  const qc = useQueryClient()
  const { activeTenant } = useTenant()
  return useMutation({
    mutationFn: async (input: { checklistId: string; reason?: string | null }) => {
      const { data, error } = await supabase.rpc('waive_employee_asset_return_checklist', {
        p_checklist_id: input.checklistId,
        p_reason: input.reason ?? undefined,
      })
      if (error) throw error
      return data as AssetReturnChecklist
    },
    onSuccess: () => {
      if (activeTenant?.id) {
        void qc.invalidateQueries({ queryKey: checklistKey(activeTenant.id, employeeId) })
        void qc.invalidateQueries({
          queryKey: ['employee-asset-assignments', activeTenant.id, employeeId],
        })
      }
    },
  })
}
