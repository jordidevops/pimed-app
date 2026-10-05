import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { useTenant } from '@/contexts/TenantContext'
import { useDocumentTemplateLocales } from '@/features/signing/api/useDocumentTemplateLocales'
import { useContentBlocks } from '@/features/signing/api/useContentBlocks'
import { TemplatePreviewPlayground } from '@/features/signing/components/TemplatePreviewPlayground'
import { DocxPreviewPane } from '@/features/signing/components/DocxPreviewModal'
import { isDocxLocaleMime } from '@/features/signing/utils/docxTemplateIo'
import type { SigningRolesSchema, VariablesSchema } from '@/features/signing/api/signingService'
import { buildSampleCommercialDocumentHtml } from '../utils/buildCommercialDocumentHtml'
import { cn } from '@/lib/utils'

type DocumentTemplatePreviewPaneProps = {
  templateId: string | null | undefined
  blockMapping?: Record<string, string> | null
  templateType?: string | null
  className?: string
  /** Compact height for inline use under a form field. */
  compact?: boolean
  /**
   * When there is no resolved templateId, show the QT-D1 system-default sample
   * for this commercial doc type (what generation uses as fallback).
   */
  systemDefaultDocType?: 'quote' | 'delivery_note' | null
}

export function DocumentTemplatePreviewPane({
  templateId,
  blockMapping,
  templateType,
  className,
  compact = false,
  systemDefaultDocType = null,
}: DocumentTemplatePreviewPaneProps) {
  const { t } = useTranslation('projects')
  const { activeTenant } = useTenant()
  const { data: locales = [], isLoading } = useDocumentTemplateLocales(templateId ?? undefined)
  const { data: contentBlocks = [] } = useContentBlocks(activeTenant?.id)

  const locale = useMemo(() => {
    const active = locales.find((l) => l.is_active)
    return active ?? locales[0] ?? null
  }, [locales])

  const htmlContent = locale?.html_content?.trim() ?? ''
  const isDocx =
    templateType === 'docx' ||
    isDocxLocaleMime(locale?.mime_type) ||
    (!!locale?.storage_path && !htmlContent)
  const isHtml =
    !isDocx &&
    (templateType === 'html' || locale?.mime_type?.includes('html') || !!htmlContent) &&
    !!htmlContent

  const systemDefaultHtml = useMemo(() => {
    if (templateId || !systemDefaultDocType) return null
    return buildSampleCommercialDocumentHtml(systemDefaultDocType, {
      display_name: activeTenant?.name ?? null,
      logo_url: activeTenant?.logo_url ?? null,
    })
  }, [templateId, systemDefaultDocType, activeTenant?.name, activeTenant?.logo_url])

  if (!templateId) {
    if (systemDefaultHtml) {
      return (
        <div className={cn(className, 'space-y-2')}>
          <p className="text-[11px] text-muted-foreground">
            {t(
              'projects.commercial.template_preview_system_default_help',
              'Format per defecte del sistema (sense plantilla full-body activa). Això és el que s’usarà en emetre.',
            )}
          </p>
          <div
            className={cn(
              'overflow-auto rounded-lg border bg-white',
              compact ? 'h-48 min-h-48' : 'h-[45vh] min-h-[45vh]',
            )}
          >
            <iframe
              title={t(
                'projects.commercial.template_preview_system_default_title',
                'Vista prèvia del format per defecte',
              )}
              className="h-full w-full border-0 bg-white"
              sandbox=""
              srcDoc={systemDefaultHtml}
            />
          </div>
        </div>
      )
    }
    return (
      <p className="rounded-lg border border-dashed border-border px-3 py-4 text-xs text-muted-foreground">
        {t(
          'projects.commercial.template_preview_none',
          'Selecciona una plantilla per veure’n la vista prèvia.',
        )}
      </p>
    )
  }

  if (isLoading) {
    return (
      <p className="rounded-lg border border-border px-3 py-4 text-xs text-muted-foreground">
        {t('projects.commercial.template_preview_loading', 'Carregant vista prèvia…')}
      </p>
    )
  }

  if (isDocx) {
    if (!locale?.storage_path) {
      return (
        <p className="rounded-lg border border-border bg-muted/30 px-3 py-4 text-xs text-muted-foreground">
          {t(
            'projects.commercial.template_preview_docx_missing',
            'Aquesta plantilla DOCX no té fitxer desat; no es pot mostrar la vista prèvia.',
          )}
        </p>
      )
    }
    return (
      <div
        className={cn(
          'flex min-h-0 flex-col',
          compact ? 'h-56' : 'h-full min-h-[16rem] flex-1',
          className,
        )}
      >
        <DocxPreviewPane
          storagePath={locale.storage_path}
          bucket="document-templates"
          previewValues={(locale.sample_values as Record<string, unknown> | null) ?? null}
          showZoomControls
          initialZoom="fit"
          className="min-h-0 flex-1"
        />
      </div>
    )
  }

  if (!isHtml) {
    return (
      <p className="rounded-lg border border-border bg-muted/30 px-3 py-4 text-xs text-muted-foreground">
        {t(
          'projects.commercial.template_preview_unavailable',
          'No hi ha contingut de vista prèvia per a aquesta plantilla.',
        )}
      </p>
    )
  }

  return (
    <div className={className}>
      <TemplatePreviewPlayground
        htmlContent={htmlContent}
        variablesSchema={(locale?.variables_schema as VariablesSchema | null) ?? null}
        rolesSchema={(locale?.signing_roles_schema as SigningRolesSchema | null) ?? {}}
        tenant={activeTenant}
        blockMapping={blockMapping}
        blocks={contentBlocks}
        sampleValues={(locale?.sample_values as Record<string, unknown> | null) ?? null}
        previewOnly
        compact={compact}
      />
    </div>
  )
}
