import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { signingKeys } from './signingKeys'
import type { DocumentTemplateLocaleDetail } from './signingService'

export function useDocumentTemplateLocales(templateId: string | undefined) {
  return useQuery<DocumentTemplateLocaleDetail[]>({
    queryKey: signingKeys.locales(templateId ?? ''),
    queryFn:  async () => {
      const { data, error } = await supabase
        .schema('api')
        .from('document_template_locale_detail')
        .select('id, template_id, locale, storage_path, mime_type, html_content, variables_schema, signing_roles_schema, sample_values, is_active, created_at, updated_at')
        .eq('template_id', templateId!)
        .order('locale', { ascending: true })

      if (error) throw error
      return (data ?? []) as DocumentTemplateLocaleDetail[]
    },
    enabled: !!templateId,
  })
}
