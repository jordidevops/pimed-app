import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { signingKeys } from './signingKeys'
import type { DocumentTemplateLocale } from './signingService'

/**
 * Fetches ALL locales for a given set of template IDs in a single query.
 * Use this instead of per-card useDocumentTemplateLocales to avoid N+1 queries.
 * The templateIds array is included in the query key so the cache is invalidated
 * automatically when the template list changes.
 */
export function useLocalesBatch(tenantId: string | undefined, templateIds: string[]) {
  const sortedIds = [...templateIds].sort()
  return useQuery<DocumentTemplateLocale[]>({
    queryKey: [...signingKeys.localesBatch(tenantId ?? ''), ...sortedIds],
    queryFn: async () => {
      if (!sortedIds.length) return []
      const { data, error } = await supabase
        .from('document_template_locales')
        .select('id, template_id, locale, storage_path, mime_type, variables_schema, signing_roles_schema, sample_values, is_active, created_at, updated_at')
        .in('template_id', sortedIds)
        .order('locale', { ascending: true })

      if (error) throw error
      return (data ?? []) as DocumentTemplateLocale[]
    },
    enabled: !!tenantId && sortedIds.length > 0,
  })
}
