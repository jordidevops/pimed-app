import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { RefreshCw } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { cn } from '@/lib/utils'
import type { SigningRolesSchema, VariablesSchema } from '../api/signingService'
import { buildPreviewHtml, type PreviewBlock } from '../utils/previewBlocks'
import { generateDummyPreviewValues } from '../utils/aiTemplate'

interface TemplatePreviewPlaygroundProps {
  htmlContent: string
  variablesSchema: VariablesSchema | null
  rolesSchema: SigningRolesSchema
  tenant?: { name?: string | null; logo_url?: string | null } | null
  blockMapping?: Record<string, string> | null
  blocks?: PreviewBlock[] | null
  className?: string
  /** Només iframe renderitzat (p. ex. referència d'un altre idioma). */
  previewOnly?: boolean
}

function hasBlockDuplicationRisk(html: string, blockMapping?: Record<string, string> | null): boolean {
  if (!blockMapping) return false
  const hasPageSlot = Boolean(blockMapping.page_header || blockMapping.page_footer)
  const hasDocRefs = /\{\{\s*document_(header|footer)\s*\}\}/.test(html)
  return hasPageSlot && hasDocRefs
}

export function TemplatePreviewPlayground({
  htmlContent,
  variablesSchema,
  rolesSchema,
  tenant,
  blockMapping,
  blocks,
  className,
  previewOnly = false,
}: TemplatePreviewPlaygroundProps) {
  const { t } = useTranslation('signing')
  const [values, setValues] = useState<Record<string, string>>({})

  const sortedVars = useMemo(() => {
    if (!variablesSchema) return [] as [string, VariablesSchema[string]][]
    return Object.entries(variablesSchema).sort(([, a], [, b]) => (a.order ?? 0) - (b.order ?? 0))
  }, [variablesSchema])

  useEffect(() => {
    const dummy = generateDummyPreviewValues(variablesSchema, rolesSchema)
    const flat: Record<string, string> = {}
    for (const [k, v] of Object.entries(dummy)) {
      if (typeof v === 'string' || typeof v === 'number') flat[k] = String(v)
    }
    setValues(flat)
  }, [variablesSchema, rolesSchema, htmlContent])

  const appliedBlockLabels = useMemo(() => {
    if (!blockMapping || !blocks?.length) return [] as string[]
    const blockById = new Map(blocks.map(b => [b.id ?? '', b]))
    return Object.entries(blockMapping)
      .filter(([, id]) => id)
      .map(([slot, id]) => {
        const block = blockById.get(id)
        return block?.name ? `${slot}: ${block.name}` : slot
      })
  }, [blockMapping, blocks])

  const showDuplicationWarning = useMemo(
    () => hasBlockDuplicationRisk(htmlContent, blockMapping),
    [htmlContent, blockMapping],
  )

  const { previewHtml, renderError } = useMemo(() => {
    if (!htmlContent.trim()) return { previewHtml: '', renderError: null as string | null }
    try {
      const ctx = generateDummyPreviewValues(variablesSchema, rolesSchema)
      for (const [k, v] of Object.entries(values)) {
        if (v !== '') ctx[k] = v
      }
      const tenantCtx = tenant ?? (ctx.tenant as Record<string, unknown> | undefined)
      return {
        previewHtml: buildPreviewHtml(htmlContent, ctx, {
          tenant: tenantCtx,
          blockMapping,
          blocks,
        }),
        renderError: null,
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err)
      return { previewHtml: '', renderError: msg }
    }
  }, [htmlContent, values, variablesSchema, rolesSchema, tenant, blockMapping, blocks])

  function fillDummy() {
    const dummy = generateDummyPreviewValues(variablesSchema, rolesSchema)
    const flat: Record<string, string> = {}
    for (const [k, v] of Object.entries(dummy)) {
      if (typeof v === 'string' || typeof v === 'number') flat[k] = String(v)
    }
    setValues(flat)
  }

  return (
    <div className={`flex flex-col gap-3 ${className ?? ''}`}>
      {appliedBlockLabels.length > 0 && (
        <p className="text-xs text-muted-foreground bg-muted/40 px-2.5 py-1.5 rounded">
          {t('aiWizard.blocksInPreview', 'Vista prèvia amb blocs assignats')}: {appliedBlockLabels.join(' · ')}
        </p>
      )}
      {showDuplicationWarning && (
        <p className="text-xs text-amber-800 bg-amber-50 px-2.5 py-1.5 rounded">
          {t(
            'aiWizard.blockDuplicationWarning',
            'Aquesta plantilla inclou {{ document_header }}/{{ document_footer }} i també té capçalera/peu de pàgina assignats. Al PDF final podrien aparèixer elements duplicats.',
          )}
        </p>
      )}
      <div className={cn('flex flex-col gap-4', !previewOnly && 'lg:flex-row')}>
      {!previewOnly && (
      <div className="w-full lg:w-[38%] shrink-0 space-y-3 max-h-[52vh] overflow-y-auto pr-1">
        <div className="flex items-center justify-between gap-2">
          <p className="text-sm font-medium">{t('aiWizard.previewForm', 'Dades de prova')}</p>
          <Button type="button" variant="outline" size="sm" onClick={fillDummy}>
            <RefreshCw className="h-3.5 w-3.5 mr-1" />
            {t('aiWizard.fillDummy', 'Generar dades de prova')}
          </Button>
        </div>
        {sortedVars.length === 0 ? (
          <p className="text-xs text-muted-foreground">{t('aiWizard.noVariables', 'Sense variables declarades.')}</p>
        ) : (
          <div className="space-y-2">
            {sortedVars.map(([key, def]) => (
              <div key={key} className="space-y-1">
                <label className="text-xs font-medium">{def.label ?? key}</label>
                <Input
                  type={def.type === 'date' ? 'date' : def.type === 'number' ? 'number' : 'text'}
                  value={values[key] ?? ''}
                  onChange={e => setValues(prev => ({ ...prev, [key]: e.target.value }))}
                  className="h-8 text-sm"
                />
              </div>
            ))}
          </div>
        )}
      </div>
      )}
      <div className={cn(
        'w-full rounded-lg border bg-white overflow-hidden flex flex-col',
        previewOnly ? 'min-h-[45vh] h-[45vh]' : 'lg:flex-1 min-h-[52vh] h-[52vh]',
      )}>
        {renderError ? (
          <p className="p-4 text-sm text-red-600">{t('aiWizard.previewError', 'Error en generar la vista prèvia')}: {renderError}</p>
        ) : previewHtml ? (
          <iframe
            srcDoc={previewHtml}
            sandbox=""
            title={t('aiWizard.previewTitle', 'Vista prèvia')}
            className="w-full flex-1 border-0 bg-white"
            style={{ minHeight: previewOnly ? '45vh' : '52vh' }}
          />
        ) : (
          <p className="p-4 text-sm text-muted-foreground">{t('aiWizard.previewEmpty', 'Sense contingut HTML per previsualitzar.')}</p>
        )}
      </div>
    </div>
    </div>
  )
}
