import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../lib/supabase'
import { useTenant } from '../contexts/TenantContext'

export interface SettingsContext {
  tenantId?: string | null  // passar explícitament per evitar la cursa x-tenant-id
  siteId?: string | null
  userId?: string | null
}

// ---------------------------------------------------------------------------
// useEffectiveSettings
// Retorna el JSONB complet del merge dels 4 nivells per al context donat.
// Requereix tenantId per garantir queryKey correcte i evitar la cursa de timing.
// ---------------------------------------------------------------------------
export function useEffectiveSettings(
  context: SettingsContext,
  options?: { enabled?: boolean },
) {
  return useQuery<Record<string, unknown>>({
    queryKey: [
      'effective_settings',
      context.tenantId ?? null,
      context.siteId ?? null,
      context.userId ?? null,
    ],
    enabled: (options?.enabled ?? true) && !!context.tenantId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_effective_settings', {
        p_site_id:   context.siteId   ?? undefined,
        p_user_id:   context.userId   ?? undefined,
        p_tenant_id: context.tenantId ?? undefined,
      })
      if (error) throw error
      return (data as Record<string, unknown>) ?? {}
    },
  })
}

// ---------------------------------------------------------------------------
// useSettings(key, context)
// Retorna el valor efectiu d'una clau concreta del motor de configuració.
// Inclou el valor "heretat" (merge sense el nivell d'usuari) per a UX.
// ---------------------------------------------------------------------------
export function useSettings<T = unknown>(
  key: string,
  context: SettingsContext,
  options?: { enabled?: boolean },
) {
  const { data: effective, isLoading, error } = useEffectiveSettings(context, options)

  const value = effective?.[key] as T | undefined

  return { value, isLoading, error }
}

// ---------------------------------------------------------------------------
// useInheritedSettings(key, context)
// Retorna el valor que s'heretaria dels nivells superiors (excloent l'usuari).
// Útil per mostrar el placeholder "Heretat de l'empresa" als formularis.
// ---------------------------------------------------------------------------
export function useInheritedSettings<T = unknown>(
  key: string,
  context: Omit<SettingsContext, 'userId'>,
  options?: { enabled?: boolean },
) {
  // Cridem get_effective_settings sense p_user_id per obtenir el merge System+Tenant+Site
  const { data: inherited, isLoading, error } = useEffectiveSettings(
    { siteId: context.siteId, userId: undefined },
    options,
  )

  const value = inherited?.[key] as T | undefined

  return { value, isLoading, error }
}

// ---------------------------------------------------------------------------
// useMemberSettingsMutation
// Actualitza el settings JSONB de l'usuari actual a tenant_members.
// Invalida la cache de effective_settings automàticament.
// ---------------------------------------------------------------------------
export function useMemberSettingsMutation() {
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()

  return useMutation({
    mutationFn: async (settings: Record<string, unknown>) => {
      const tenantId = activeTenant?.id
      if (!tenantId) throw new Error('No active tenant')
      const { error } = await supabase.rpc('update_my_member_settings', {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        p_settings:  settings as any,
        p_tenant_id: tenantId,
      })
      if (error) throw error
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['effective_settings'] })
    },
  })
}

// ---------------------------------------------------------------------------
// useTenantSettingsMutation
// Actualitza el settings JSONB del tenant actiu (requereix owner o manager).
// ---------------------------------------------------------------------------
export function useTenantSettingsMutation() {
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()

  return useMutation({
    mutationFn: async (settings: Record<string, unknown>) => {
      const tenantId = activeTenant?.id
      if (!tenantId) throw new Error('No active tenant')
      const { error } = await supabase.rpc('update_tenant_settings', {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        p_settings:  settings as any,
        p_tenant_id: tenantId,
      })
      if (error) throw error
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['effective_settings'] })
    },
  })
}

// ---------------------------------------------------------------------------
// useSiteSettingsMutation
// Actualitza el settings JSONB d'un site concret (requereix owner o manager).
// ---------------------------------------------------------------------------
export function useSiteSettingsMutation(siteId: string) {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (settings: Record<string, unknown>) => {
      const { error } = await supabase.rpc('update_site_settings', {
        p_site_id: siteId,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        p_settings: settings as any,
      })
      if (error) throw error
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['effective_settings'] })
    },
  })
}
