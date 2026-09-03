import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useTenant } from '@/contexts/TenantContext'
import type { CoverageBucket } from './useCoverageBuckets'

export type CoverageGapSeverity = 'now' | 'upcoming'

export type CoverageGapAlert = {
  kinds: string[]
  severity: CoverageGapSeverity
  bucket_start: string
  bucket_end: string
  bucket_start_min: number
  bucket_end_min: number
  role_id: string | null
  role_name: string | null
  required: number
  planned: number
  present: number
  qualified: number
  gap_planned: number
  gap_present: number
  gap_qualified: number
  missing_count?: number
}

export type CoverageMissingNow = {
  employee_id: string
  employee_name: string
  role_id: string | null
  role_name: string | null
  slot_start: string
  slot_end: string
  status: 'late' | 'absent' | string
}

export type CoverageOperationalSnapshot = {
  site_id: string
  work_date: string
  as_of: string
  as_of_min: number
  timezone: string
  bucket_minutes: number
  horizon_minutes: number
  role_id: string | null
  role_name: string | null
  current: CoverageBucket | null
  alerts: CoverageGapAlert[]
  missing_now: CoverageMissingNow[]
  summary: {
    open_gap_count: number
    missing_now_count: number
    worst_gap_planned: number
    worst_gap_present: number
    current_ok: boolean
  }
}

function normalizeAlert(raw: Record<string, unknown>): CoverageGapAlert {
  const kindsRaw = raw.kinds
  let kinds: string[] = []
  if (Array.isArray(kindsRaw)) kinds = kindsRaw.map(String)
  else if (typeof kindsRaw === 'string') {
    try {
      const parsed = JSON.parse(kindsRaw) as unknown
      if (Array.isArray(parsed)) kinds = parsed.map(String)
    } catch {
      kinds = [kindsRaw]
    }
  }

  return {
    kinds,
    severity: raw.severity === 'upcoming' ? 'upcoming' : 'now',
    bucket_start: String(raw.bucket_start ?? ''),
    bucket_end: String(raw.bucket_end ?? ''),
    bucket_start_min: Number(raw.bucket_start_min ?? 0),
    bucket_end_min: Number(raw.bucket_end_min ?? 0),
    role_id: (raw.role_id as string | null) ?? null,
    role_name: (raw.role_name as string | null) ?? null,
    required: Number(raw.required ?? 0),
    planned: Number(raw.planned ?? 0),
    present: Number(raw.present ?? 0),
    qualified: Number(raw.qualified ?? 0),
    gap_planned: Number(raw.gap_planned ?? 0),
    gap_present: Number(raw.gap_present ?? 0),
    gap_qualified: Number(raw.gap_qualified ?? 0),
    missing_count: raw.missing_count != null ? Number(raw.missing_count) : undefined,
  }
}

export function useCoverageOperationalSnapshot(params?: {
  roleId?: string | null
  horizonMinutes?: number
  bucketMinutes?: 15 | 30
  enabled?: boolean
  refetchIntervalMs?: number
}) {
  const { activeTenant, selectedSiteId, tenantScopeReady } = useTenant()
  const tenantId = activeTenant?.id
  const bucketMinutes = params?.bucketMinutes ?? 30
  const horizonMinutes = params?.horizonMinutes ?? 240

  return useQuery({
    queryKey: [
      'coverage-ops-snapshot',
      tenantId,
      selectedSiteId,
      bucketMinutes,
      horizonMinutes,
      params?.roleId ?? null,
    ],
    enabled:
      (params?.enabled ?? true)
      && tenantScopeReady
      && !!tenantId
      && !!selectedSiteId,
    refetchInterval: params?.refetchIntervalMs ?? 60_000,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_coverage_operational_snapshot' as never, {
        p_site_id: selectedSiteId,
        p_bucket_minutes: bucketMinutes,
        p_horizon_minutes: horizonMinutes,
        p_role_id: params?.roleId ?? null,
        p_as_of: null,
      } as never)
      if (error) throw error
      const raw = (data ?? {}) as Record<string, unknown>
      const alertsRaw = Array.isArray(raw.alerts) ? raw.alerts : []
      const missingRaw = Array.isArray(raw.missing_now) ? raw.missing_now : []
      const summaryRaw = (raw.summary ?? {}) as Record<string, unknown>

      return {
        site_id: String(raw.site_id ?? ''),
        work_date: String(raw.work_date ?? ''),
        as_of: String(raw.as_of ?? ''),
        as_of_min: Number(raw.as_of_min ?? 0),
        timezone: String(raw.timezone ?? ''),
        bucket_minutes: Number(raw.bucket_minutes ?? bucketMinutes),
        horizon_minutes: Number(raw.horizon_minutes ?? horizonMinutes),
        role_id: (raw.role_id as string | null) ?? null,
        role_name: (raw.role_name as string | null) ?? null,
        current: (raw.current as CoverageBucket | null) ?? null,
        alerts: alertsRaw.map((a) => normalizeAlert(a as Record<string, unknown>)),
        missing_now: missingRaw.map((m) => {
          const row = m as Record<string, unknown>
          return {
            employee_id: String(row.employee_id ?? ''),
            employee_name: String(row.employee_name ?? ''),
            role_id: (row.role_id as string | null) ?? null,
            role_name: (row.role_name as string | null) ?? null,
            slot_start: String(row.slot_start ?? ''),
            slot_end: String(row.slot_end ?? ''),
            status: String(row.status ?? 'late'),
          } satisfies CoverageMissingNow
        }),
        summary: {
          open_gap_count: Number(summaryRaw.open_gap_count ?? 0),
          missing_now_count: Number(summaryRaw.missing_now_count ?? 0),
          worst_gap_planned: Number(summaryRaw.worst_gap_planned ?? 0),
          worst_gap_present: Number(summaryRaw.worst_gap_present ?? 0),
          current_ok: Boolean(summaryRaw.current_ok ?? true),
        },
      } satisfies CoverageOperationalSnapshot
    },
  })
}
