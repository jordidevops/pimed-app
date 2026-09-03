import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'
import { emailKeys } from './emailKeys'
import type { EmailDomainUpdate } from '../types'

export function useAddEmailDomain(tenantId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (domain: string) => {
      const { data: fnData, error: fnError } = await supabase.functions.invoke(
        'manage-email-domain',
        {
          headers: { 'x-tenant-id': tenantId },
          body: { action: 'register', domain },
        },
      )

      if (fnError) throw fnError
      if (!fnData?.success) throw new Error(fnData?.error ?? 'Error en registrar el domini a Resend')
      return fnData
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: emailKeys.domains(tenantId) })
    },
  })
}

export function useUpdateEmailDomain(tenantId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({ domainId, updates }: { domainId: string; updates: EmailDomainUpdate }) => {
      const { data, error } = await supabase
        .from('email_domains')
        .update(updates)
        .eq('id', domainId)
        .eq('tenant_id', tenantId)
        .select()
        .single()
      if (error) throw error
      return data
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: emailKeys.domains(tenantId) })
    },
  })
}

export function useDeleteEmailDomain(tenantId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (domainId: string) => {
      // Crida l'Edge Function que esborra de Resend i de la BD
      const { data, error } = await supabase.functions.invoke('manage-email-domain', {
        body: { action: 'delete', domain_id: domainId },
      })
      if (error) throw error
      if (!data?.success) throw new Error(data?.error ?? 'Error en eliminar el domini')
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: emailKeys.domains(tenantId) })
    },
  })
}

export function useVerifyEmailDomain(tenantId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (domainId: string) => {
      const { data, error } = await supabase.functions.invoke('manage-email-domain', {
        body: { action: 'verify', domain_id: domainId },
      })
      if (error) throw error
      if (!data?.success) throw new Error(data?.error ?? 'Error en verificar el domini')
      return data as { success: true; status: string }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: emailKeys.domains(tenantId) })
    },
  })
}
