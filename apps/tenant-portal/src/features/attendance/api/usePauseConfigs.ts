import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useTenant } from '@/contexts/TenantContext'

export interface PauseConfig {
  id: string
  key: string
  label_i18n: Record<string, string> | null
  counts_as_work: boolean
  max_duration_minutes: number | null
  sort_order: number
}

export function pauseLabel(config: PauseConfig, lang = 'ca'): string {
  return config.label_i18n?.[lang] ?? config.label_i18n?.es ?? config.key
}

async function fetchPauseConfigs(): Promise<PauseConfig[]> {
  const { data, error } = await supabase.rpc(
    // @ts-expect-error RPC added in attendance v2 migration
    'list_pause_configs',
  )
  if (error) throw new Error(error.message)
  return (data ?? []) as unknown as PauseConfig[]
}

export function usePauseConfigs() {
  const { activeTenant, tenantScopeReady } = useTenant()
  const tenantId = activeTenant?.id

  return useQuery({
    queryKey: ['attendance', 'pause-configs', tenantId],
    queryFn: fetchPauseConfigs,
    enabled: tenantScopeReady && !!tenantId,
    staleTime: 5 * 60_000,
  })
}
