import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { signingKeys } from './signingKeys'
import type { DocumentTemplate, DocumentTemplateWithLocales } from './signingService'

export function useDocumentTemplates(tenantId: string | undefined) {
  return useQuery<DocumentTemplateWithLocales[]>({
    queryKey: signingKeys.templates(tenantId ?? ''),
    queryFn:  async () => {
      const [templatesRes, localesRes] = await Promise.all([
        supabase
          .from('document_templates')
          .select('*')
          .or(`tenant_id.eq.${tenantId},is_platform_default.eq.true`)
          .eq('is_active', true)
          .order('is_platform_default', { ascending: false })
          .order('name', { ascending: true })
          .limit(100),
        supabase
          .from('document_template_locales')
          .select('id, template_id, locale, is_active')
          .order('locale', { ascending: true }),
      ])

      if (templatesRes.error) throw templatesRes.error
      if (localesRes.error) throw localesRes.error

      const localesByTemplate = new Map<string, { id: string; locale: string; is_active: boolean }[]>()
      for (const l of (localesRes.data ?? [])) {
        const row = l as { id: string | null; template_id: string | null; locale: string | null; is_active: boolean | null }
        if (!row.template_id || !row.id || !row.locale) continue
        const arr = localesByTemplate.get(row.template_id) ?? []
        arr.push({ id: row.id, locale: row.locale, is_active: row.is_active ?? false })
        localesByTemplate.set(row.template_id, arr)
      }

      return ((templatesRes.data ?? []) as DocumentTemplate[]).map(t => ({
        ...t,
        locales: localesByTemplate.get(t.id ?? '') ?? [],
      }))
    },
    enabled: !!tenantId,
  })
}
