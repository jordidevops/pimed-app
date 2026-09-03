import { useQuery } from '@tanstack/react-query'
import { supabase } from '../lib/supabase'
import type { EntityStatusFilter } from './useSites'

export interface MemberInfo {
  id: string
  tenant_id: string
  user_id: string
  role: string
  is_active: boolean
  joined_at: string
  email: string
  full_name: string | null
  avatar_url: string | null
}

interface UseMembersOptions {
  enabled?: boolean
}

function statusToIsActive(status: EntityStatusFilter): boolean | null {
  if (status === 'active') return true
  if (status === 'inactive') return false
  return null
}

/**
 * Retorna membres del tenant seleccionat amb filtre d'estat.
 * Requereix userId per garantir que la query no es dispara sense JWT.
 */
export function useMembers(
  tenantId: string | null,
  userId: string | undefined,
  status: EntityStatusFilter = 'active',
  options?: UseMembersOptions,
) {
  const isActiveFilter = statusToIsActive(status)
  const isEnabled = options?.enabled ?? true

  return useQuery<MemberInfo[]>({
    queryKey: ['members', tenantId, status],
    enabled: !!tenantId && !!userId && isEnabled,
    queryFn: async () => {
      let query = supabase
        .from('tenant_members')
        .select('id, tenant_id, user_id, role, is_active, joined_at, email, full_name, avatar_url')
        .eq('tenant_id', tenantId!)
        .order('full_name', { ascending: true })

      if (isActiveFilter !== null) {
        query = query.eq('is_active', isActiveFilter)
      }

      const { data, error } = await query

      if (error) throw error
      return data as MemberInfo[]
    },
  })
}
