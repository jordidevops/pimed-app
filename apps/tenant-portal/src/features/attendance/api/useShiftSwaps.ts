import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useTenant } from '@/contexts/TenantContext'

export type SwapKind = 'swap' | 'give_away' | 'call_off'

export type ShiftSwapRequest = {
  id: string
  kind: SwapKind
  status: string
  requester_id: string
  requester_name: string
  target_employee_id: string | null
  target_employee_name: string | null
  requester_slot_id: string
  target_slot_id: string | null
  slot_date: string
  start_time: string
  end_time: string
  requester_notes: string | null
  review_comment: string | null
  created_at: string
  eligibility: { ok?: boolean; blocks?: string[]; warnings?: string[] } | null
}

function time5(raw: unknown): string {
  const s = String(raw ?? '')
  return s.length >= 5 ? s.slice(0, 5) : s
}

function mapRow(r: Record<string, unknown>): ShiftSwapRequest {
  return {
    id: String(r.id),
    kind: (r.kind as SwapKind) ?? 'swap',
    status: String(r.status ?? 'pending'),
    requester_id: String(r.requester_id),
    requester_name: String(r.requester_name ?? ''),
    target_employee_id: (r.target_employee_id as string | null) ?? null,
    target_employee_name: (r.target_employee_name as string | null) ?? null,
    requester_slot_id: String(r.requester_slot_id),
    target_slot_id: (r.target_slot_id as string | null) ?? null,
    slot_date: String(r.slot_date ?? '').slice(0, 10),
    start_time: time5(r.start_time),
    end_time: time5(r.end_time),
    requester_notes: (r.requester_notes as string | null) ?? null,
    review_comment: (r.review_comment as string | null) ?? null,
    created_at: String(r.created_at ?? ''),
    eligibility: (r.eligibility as ShiftSwapRequest['eligibility']) ?? null,
  }
}

export function useShiftSwapRequests(status: string | null = 'pending') {
  const { activeTenant, selectedSiteId, tenantScopeReady } = useTenant()
  const tenantId = activeTenant?.id

  return useQuery({
    queryKey: ['shift-swap-requests', tenantId, selectedSiteId, status],
    enabled: tenantScopeReady && !!tenantId && !!selectedSiteId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_shift_swap_requests' as never, {
        p_site_id: selectedSiteId,
        p_status: status,
        p_from: null,
        p_to: null,
      } as never)
      if (error) throw error
      return ((data ?? []) as Record<string, unknown>[]).map(mapRow)
    },
  })
}

export function useApproveShiftSwap() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: {
      request_id: string
      new_status: 'approved' | 'rejected' | 'cancelled'
      comment?: string
      target_employee_id?: string | null
      accept_warnings?: boolean
      create_opening?: boolean
    }) => {
      const { data, error } = await supabase.rpc('approve_shift_swap' as never, {
        p_request_id: input.request_id,
        p_new_status: input.new_status,
        p_comment: input.comment ?? null,
        p_target_employee_id: input.target_employee_id ?? null,
        p_accept_warnings: input.accept_warnings ?? true,
        p_create_opening: input.create_opening ?? true,
      } as never)
      if (error) throw error
      return data
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['shift-swap-requests'] })
      void qc.invalidateQueries({ queryKey: ['shift-slots'] })
      void qc.invalidateQueries({ queryKey: ['shift-openings'] })
    },
  })
}
