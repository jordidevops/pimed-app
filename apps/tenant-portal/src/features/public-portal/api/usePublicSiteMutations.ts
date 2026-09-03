import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'
import { publicPortalKeys } from './queryKeys'
import type { Json } from '../../../types/database.types'

// ---------------------------------------------------------------------------
// createPublicSite
// ---------------------------------------------------------------------------
export function useCreatePublicSite(tenantId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: {
      name: string
      siteId?: string
      supportedLocales?: string[]
      defaultLocale?: string
    }) => {
      const { data, error } = await supabase.rpc('create_public_site', {
        p_name: input.name,
        p_site_id: input.siteId ?? undefined,
      })
      if (error) throw error

      const createdSiteId = data
      if (!createdSiteId) {
        throw new Error('create_public_site_returned_null')
      }

      const chosenLocales = (input.supportedLocales ?? []).filter(Boolean)
      const locales = chosenLocales.length > 0
        ? Array.from(new Set(chosenLocales))
        : (input.defaultLocale ? [input.defaultLocale] : [])
      const selectedDefaultLocale = input.defaultLocale ?? locales[0]

      if (locales.length > 0 && selectedDefaultLocale) {
        const { error: localeError } = await supabase.rpc('update_public_site', {
          p_id: createdSiteId,
          p_supported_locales: locales,
          p_default_locale: selectedDefaultLocale,
        })
        if (localeError) throw localeError
      }

      return createdSiteId
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: publicPortalKeys.site(tenantId) })
    },
  })
}

// ---------------------------------------------------------------------------
// updatePublicSite — actualitza camps del site via RPC
// ---------------------------------------------------------------------------
export function useUpdatePublicSite(tenantId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: {
      id: string
      name?: string
      seoTitle?: string
      seoDescription?: string
      supportedLocales?: string[]
      defaultLocale?: string
      contactEmailPublic?: string | null
      leadAckCopyEmail?: string | null
    }) => {
      const { error } = await supabase.rpc('update_public_site', {
        p_id: input.id,
        p_name: input.name ?? undefined,
        p_seo_title: input.seoTitle ?? undefined,
        p_seo_description: input.seoDescription ?? undefined,
        p_seo_keywords: undefined,
        p_content: undefined,
        p_theme_config: undefined,
        p_supported_locales: input.supportedLocales ?? undefined,
        p_default_locale: input.defaultLocale ?? undefined,
        p_contact_email_public: input.contactEmailPublic === null ? '' : (input.contactEmailPublic ?? undefined),
        p_lead_ack_copy_email: input.leadAckCopyEmail === null ? '' : (input.leadAckCopyEmail ?? undefined),
      })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: publicPortalKeys.site(tenantId) })
    },
  })
}

// ---------------------------------------------------------------------------
// publishPublicSite
// ---------------------------------------------------------------------------
export function usePublishPublicSite(tenantId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (publicSiteId: string) => {
      const { error } = await supabase.rpc('publish_public_site', {
        p_id: publicSiteId,
      })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: publicPortalKeys.site(tenantId) })
    },
  })
}

// ---------------------------------------------------------------------------
// unpublishPublicSite — reverteix a 'draft' via RPC
// ---------------------------------------------------------------------------
export function useUnpublishPublicSite(tenantId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (publicSiteId: string) => {
      const { error } = await supabase.rpc('unpublish_public_site', {
        p_id: publicSiteId,
      })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: publicPortalKeys.site(tenantId) })
    },
  })
}

// ---------------------------------------------------------------------------
// attachPublicDomain
// ---------------------------------------------------------------------------
export function useAttachPublicDomain(tenantId: string, siteId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (domain: string) => {
      const { data, error } = await supabase.rpc('attach_public_domain', {
        p_public_site_id: siteId,
        p_domain: domain.toLowerCase().trim(),
      })
      if (error) throw error
      return data
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: publicPortalKeys.domains(tenantId, siteId) })
    },
  })
}

// ---------------------------------------------------------------------------
// deletePublicDomain
// ---------------------------------------------------------------------------
export function useDeletePublicDomain(tenantId: string, siteId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (domainId: string) => {
      const { error } = await supabase
        .rpc('detach_public_domain', { p_domain_id: domainId })

      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: publicPortalKeys.domains(tenantId, siteId) })
    },
  })
}

// ---------------------------------------------------------------------------
// requestDomainCheck — demana verificació DNS immediata d'un domini
// ---------------------------------------------------------------------------
export function useRequestDomainCheck(tenantId: string, siteId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (domainId: string) => {
      const { error } = await supabase
        .rpc('request_domain_check', { p_domain_id: domainId })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: publicPortalKeys.domains(tenantId, siteId) })
    },
  })
}

// ---------------------------------------------------------------------------
// promoteLeadToContact
// ---------------------------------------------------------------------------
export function usePromoteLeadToContact(tenantId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (leadId: string) => {
      const { data, error } = await supabase.rpc('promote_lead_to_contact', {
        p_lead_id: leadId,
      })
      if (error) throw error
      return data
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: publicPortalKeys.leads(tenantId) })
    },
  })
}

// ---------------------------------------------------------------------------
// savePublicPage — upsert d'una pàgina
// ---------------------------------------------------------------------------
export function useSavePublicPage(tenantId: string, siteId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: {
      id?: string
      slug: string
      title: string
      status: 'draft' | 'published'
      seoTitle?: string
      seoDescription?: string
      sortOrder?: number
      showLeadForm?: boolean
      showInNav?: boolean
      contentHtml?: string
      translations?: Json
    }) => {
      // Usa la RPC upsert_public_page (ON CONFLICT slug) per a create i update.
      // La RPC valida el tenant via data.active_tenant_id() i comprova ownership.
      const { error } = await supabase.rpc('upsert_public_page', {
        p_public_site_id: siteId,
        p_slug: input.slug,
        p_title: input.title,
        p_content: {
          show_lead_form: input.showLeadForm !== false,
          html: input.contentHtml ?? '',
        },
        p_status: input.status,
        p_seo_title: input.seoTitle ?? undefined,
        p_seo_description: input.seoDescription ?? undefined,
        p_sort_order: input.sortOrder ?? 0,
        p_translations: input.translations ?? undefined,
        p_show_in_nav: input.showInNav !== false,
      })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: publicPortalKeys.pages(tenantId, siteId) })
    },
  })
}

// ---------------------------------------------------------------------------
// patchPublicSiteTheme
// ---------------------------------------------------------------------------
export function usePatchPublicSiteTheme(tenantId: string, siteId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: { section: string; patch: Json }) => {
      const { error } = await supabase.rpc('patch_public_site_theme', {
        p_id: siteId,
        p_section: input.section,
        p_patch: input.patch,
      })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: publicPortalKeys.site(tenantId) })
    },
  })
}
