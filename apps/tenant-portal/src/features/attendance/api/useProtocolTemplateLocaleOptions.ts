import { useMemo } from 'react'
import { useDocumentTemplates } from '@/features/signing/api/useDocumentTemplates'

export interface ProtocolTemplateLocaleOption {
  localeId: string
  label: string
  category: string | null
}

export function useProtocolTemplateLocaleOptions(tenantId: string | null | undefined) {
  const { data: templates = [], isLoading, error } = useDocumentTemplates(tenantId ?? undefined)

  const options = useMemo<ProtocolTemplateLocaleOption[]>(() => {
    const rows: ProtocolTemplateLocaleOption[] = []
    for (const template of templates) {
      if (template.category !== 'attendance') continue
      for (const locale of template.locales) {
        if (!locale.is_active || !locale.id) continue
        rows.push({
          localeId: locale.id,
          label: `${template.name ?? 'Plantilla'} (${locale.locale})`,
          category: template.category,
        })
      }
    }
    return rows.sort((a, b) => a.label.localeCompare(b.label, 'ca'))
  }, [templates])

  return { options, isLoading, error }
}

export function labelForProtocolTemplateLocale(
  options: ProtocolTemplateLocaleOption[],
  localeId: string | null | undefined,
): string | null {
  if (!localeId) return null
  return options.find((o) => o.localeId === localeId)?.label ?? null
}
