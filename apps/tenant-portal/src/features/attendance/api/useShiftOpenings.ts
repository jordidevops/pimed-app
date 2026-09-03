import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useTenant } from '@/contexts/TenantContext'

export type ShiftOpeningStatus = 'draft' | 'open' | 'filled' | 'expired' | 'cancelled'
export type ClaimPolicy = 'first_eligible' | 'manager_approval' | 'ranked_window'

export type ShiftOpening = {
  id: string
  tenant_id: string
  site_id: string
  location_id: string | null
  role_id: string | null
  shift_id: string | null
  opening_date: string
  start_time: string
  end_time: string
  places_total: number
  places_filled: number
  claim_policy: ClaimPolicy
  opens_at: string | null
  closes_at: string | null
  status: ShiftOpeningStatus
  title: string | null
  notes: string | null
  compensation_label: string | null
  role_name_snapshot: string | null
  location_name_snapshot: string | null
  published_at: string | null
  created_at: string
}

export type ShiftOpeningClaim = {
  id: string
  opening_id: string
  employee_id: string
  employee_name: string
  status: string
  notes: string | null
  claimed_at: string
  review_comment: string | null
}

function timeValue(raw: string | null | undefined): string {
  if (!raw) return ''
  return raw.length >= 5 ? raw.slice(0, 5) : raw
}

function mapOpening(raw: Record<string, unknown>): ShiftOpening {
  return {
    id: String(raw.id),
    tenant_id: String(raw.tenant_id),
    site_id: String(raw.site_id),
    location_id: (raw.location_id as string | null) ?? null,
    role_id: (raw.role_id as string | null) ?? null,
    shift_id: (raw.shift_id as string | null) ?? null,
    opening_date: String(raw.opening_date).slice(0, 10),
    start_time: timeValue(String(raw.start_time ?? '')),
    end_time: timeValue(String(raw.end_time ?? '')),
    places_total: Number(raw.places_total ?? 1),
    places_filled: Number(raw.places_filled ?? 0),
    claim_policy: (raw.claim_policy as ClaimPolicy) ?? 'manager_approval',
    opens_at: (raw.opens_at as string | null) ?? null,
    closes_at: (raw.closes_at as string | null) ?? null,
    status: (raw.status as ShiftOpeningStatus) ?? 'draft',
    title: (raw.title as string | null) ?? null,
    notes: (raw.notes as string | null) ?? null,
    compensation_label: (raw.compensation_label as string | null) ?? null,
    role_name_snapshot: (raw.role_name_snapshot as string | null) ?? null,
    location_name_snapshot: (raw.location_name_snapshot as string | null) ?? null,
    published_at: (raw.published_at as string | null) ?? null,
    created_at: String(raw.created_at ?? ''),
  }
}

export function useShiftOpenings(params?: { from?: string; to?: string; status?: string | null }) {
  const { activeTenant, selectedSiteId, tenantScopeReady } = useTenant()
  const tenantId = activeTenant?.id

  return useQuery({
    queryKey: ['shift-openings', tenantId, selectedSiteId, params?.from, params?.to, params?.status ?? null],
    enabled: tenantScopeReady && !!tenantId && !!selectedSiteId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_shift_openings' as never, {
        p_site_id: selectedSiteId,
        p_from: params?.from ?? null,
        p_to: params?.to ?? null,
        p_status: params?.status ?? null,
      } as never)
      if (error) throw error
      return ((data ?? []) as Record<string, unknown>[]).map(mapOpening)
    },
  })
}

export function useShiftOpeningClaims(openingId: string | null) {
  return useQuery({
    queryKey: ['shift-opening-claims', openingId],
    enabled: !!openingId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_shift_opening_claims' as never, {
        p_opening_id: openingId,
      } as never)
      if (error) throw error
      return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
        id: String(r.id),
        opening_id: String(r.opening_id),
        employee_id: String(r.employee_id),
        employee_name: String(r.employee_name ?? ''),
        status: String(r.status),
        notes: (r.notes as string | null) ?? null,
        claimed_at: String(r.claimed_at ?? ''),
        review_comment: (r.review_comment as string | null) ?? null,
      })) satisfies ShiftOpeningClaim[]
    },
  })
}

export function useUpsertShiftOpening() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: {
      id?: string | null
      site_id: string
      opening_date: string
      start_time: string
      end_time: string
      places_total?: number
      claim_policy?: ClaimPolicy
      role_id?: string | null
      title?: string | null
      notes?: string | null
    }) => {
      const { data, error } = await supabase.rpc('upsert_shift_opening' as never, {
        p_id: input.id ?? null,
        p_site_id: input.site_id,
        p_opening_date: input.opening_date,
        p_start_time: input.start_time,
        p_end_time: input.end_time,
        p_places_total: input.places_total ?? 1,
        p_claim_policy: input.claim_policy ?? 'manager_approval',
        p_location_id: null,
        p_role_id: input.role_id ?? null,
        p_shift_id: null,
        p_title: input.title ?? null,
        p_notes: input.notes ?? null,
        p_compensation_label: null,
        p_opens_at: null,
        p_closes_at: null,
        p_clear_location: false,
        p_clear_role: !input.role_id,
      } as never)
      if (error) throw error
      return mapOpening(data as Record<string, unknown>)
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['shift-openings'] })
    },
  })
}

export function usePublishShiftOpening() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: string) => {
      const { data, error } = await supabase.rpc('publish_shift_opening' as never, { p_id: id } as never)
      if (error) throw error
      return mapOpening(data as Record<string, unknown>)
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['shift-openings'] })
    },
  })
}

export function useCancelShiftOpening() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: string) => {
      const { data, error } = await supabase.rpc('cancel_shift_opening' as never, { p_id: id } as never)
      if (error) throw error
      return mapOpening(data as Record<string, unknown>)
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['shift-openings'] })
    },
  })
}

export function useRejectShiftOpeningClaim() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: { claim_id: string; opening_id: string; comment?: string }) => {
      const { data, error } = await supabase.rpc('reject_shift_opening_claim' as never, {
        p_claim_id: input.claim_id,
        p_review_comment: input.comment ?? null,
      } as never)
      if (error) throw error
      return data
    },
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: ['shift-opening-claims', vars.opening_id] })
    },
  })
}

export function useAcceptShiftOpeningClaim() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: {
      claim_id: string
      opening_id: string
      accept_warnings?: boolean
    }) => {
      const { data, error } = await supabase.rpc('accept_shift_opening_claim' as never, {
        p_claim_id: input.claim_id,
        p_accept_warnings: input.accept_warnings ?? true,
      } as never)
      if (error) throw error
      return data as {
        claim_id: string
        slot_id: string
        opening_status: string
        places_filled: number
        places_total: number
        warnings: unknown
      }
    },
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: ['shift-opening-claims', vars.opening_id] })
      void qc.invalidateQueries({ queryKey: ['shift-openings'] })
      void qc.invalidateQueries({ queryKey: ['shift-slots'] })
    },
  })
}

export function useEvaluateShiftOpeningClaim() {
  return useMutation({
    mutationFn: async (claimId: string) => {
      const { data, error } = await supabase.rpc('evaluate_shift_opening_claim' as never, {
        p_claim_id: claimId,
      } as never)
      if (error) throw error
      return data as {
        ok: boolean
        blocks: string[]
        warnings: string[]
        claim_id: string
      }
    },
  })
}
