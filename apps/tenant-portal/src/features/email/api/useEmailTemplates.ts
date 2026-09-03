import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'
import { emailKeys } from './emailKeys'
import type { EmailTemplate } from '../types'

/**
 * Retorna totes les plantilles de contingut (is_layout=false) visibles per al tenant:
 * les seves pròpies (incloses esborranys) i les de plataforma (fallback).
 */
export function useEmailTemplates(tenantId: string | undefined) {
  return useQuery<EmailTemplate[]>({
    queryKey: emailKeys.templates(tenantId ?? ''),
    queryFn: async () => {
      const { data, error } = await supabase
        .from('email_templates')
        .select('*')
        .or(`tenant_id.eq.${tenantId},is_platform_default.eq.true`)
        .eq('is_layout', false)
        .order('event_type', { ascending: true, nullsFirst: false })

      if (error) throw error
      return (data ?? []) as EmailTemplate[]
    },
    enabled: !!tenantId,
  })
}

/**
 * Retorna totes les plantilles de layout (is_layout=true) visibles per al tenant:
 * les seves pròpies i les de plataforma.
 */
export function useEmailLayouts(tenantId: string | undefined) {
  return useQuery<EmailTemplate[]>({
    queryKey: emailKeys.layouts(tenantId ?? ''),
    queryFn: async () => {
      const { data, error } = await supabase
        .from('email_templates')
        .select('*')
        .or(`tenant_id.eq.${tenantId},is_platform_default.eq.true`)
        .eq('is_layout', true)
        .eq('is_active', true)
        .order('name', { ascending: true })

      if (error) throw error
      return (data ?? []) as EmailTemplate[]
    },
    enabled: !!tenantId,
  })
}
