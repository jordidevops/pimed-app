import { useState, useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { Save } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { useContentBlocks, type ContentBlock, type BlockType } from '@/features/signing/api/useContentBlocks'
import { useUpdateTemplateMappingMutation } from '@/features/signing/api/useContentBlockMutations'

// Slots disponibles per tipus de template
const HTML_SLOTS: { key: string; types: BlockType[]; labelKey: string; fallback: string }[] = [
  { key: 'page_header',     types: ['PAGE_HEADER'],     labelKey: 'blockMapping.pageHeader',     fallback: 'Capçalera de pàgina (per pàgina)' },
  { key: 'page_footer',     types: ['PAGE_FOOTER'],     labelKey: 'blockMapping.pageFooter',     fallback: 'Peu de pàgina (per pàgina)' },
  { key: 'document_header', types: ['DOCUMENT_HEADER'], labelKey: 'blockMapping.documentHeader', fallback: 'Capçalera del document' },
  { key: 'document_footer', types: ['DOCUMENT_FOOTER'], labelKey: 'blockMapping.documentFooter', fallback: 'Peu del document' },
]

const DOCX_SLOTS: typeof HTML_SLOTS = [
  { key: 'page_header', types: ['PAGE_HEADER'], labelKey: 'blockMapping.pageHeader', fallback: 'Capçalera de pàgina (per pàgina)' },
  { key: 'page_footer', types: ['PAGE_FOOTER'], labelKey: 'blockMapping.pageFooter', fallback: 'Peu de pàgina (per pàgina)' },
]

const NO_BLOCK = '__none__'

interface Props {
  templateId:         string
  tenantId:           string
  templateType:       string | null | undefined
  defaultBlockMapping: Record<string, string> | null | undefined
  canWrite:           boolean
}

export function BlockMappingSection({
  templateId,
  tenantId,
  templateType,
  defaultBlockMapping,
  canWrite,
}: Props) {
  const { t } = useTranslation('signing')
  const { toast } = useToast()

  const { data: allBlocks = [] } = useContentBlocks(tenantId || undefined)
  const updateMapping = useUpdateTemplateMappingMutation(tenantId)

  const isHtml = templateType === 'html'
  const slots  = isHtml ? HTML_SLOTS : DOCX_SLOTS

  // Inicialitzar mapping local a partir del que ve del template
  const [mapping, setMapping] = useState<Record<string, string>>(() => defaultBlockMapping ?? {})
  useEffect(() => {
    setMapping(defaultBlockMapping ?? {})
  }, [defaultBlockMapping])

  // Filtrar blocs per tipus de slot
  function blocksForSlot(types: BlockType[]): ContentBlock[] {
    return allBlocks.filter(b => types.includes(b.block_type as BlockType))
  }

  function groupedBlocks(types: BlockType[]) {
    const filtered = blocksForSlot(types)
    const system = filtered.filter(b => b.is_platform_default)
    const tenant = filtered.filter(b => !b.is_platform_default)
    return { system, tenant }
  }

  async function handleSave() {
    // Neteja: elimina entrades amb valor buit
    const clean: Record<string, string> = {}
    for (const [k, v] of Object.entries(mapping)) {
      if (v && v !== NO_BLOCK) clean[k] = v
    }
    try {
      await updateMapping.mutateAsync({ templateId, tenantId, blockMapping: clean })
      toast({ title: t('blockMapping.saveSuccess', 'Assignació desada') })
    } catch (err) {
      toast({ title: t('blockMapping.saveError', 'Error desant l\'assignació'), variant: 'destructive' })
    }
  }

  return (
    <div className="rounded-lg border bg-card p-5 space-y-4">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h3 className="text-sm font-semibold text-foreground">
            {t('blockMapping.sectionTitle', 'Blocs de contingut de la plantilla')}
          </h3>
          <p className="text-xs text-muted-foreground mt-0.5">
            {t('blockMapping.sectionDescription', 'Assigna blocs de capçalera, peu i personalitzats a aquesta plantilla.')}
          </p>
        </div>
        {canWrite && (
          <Button size="sm" onClick={handleSave} disabled={updateMapping.isPending}>
            <Save className="h-4 w-4 mr-1" />
            {t('blockMapping.saveButton', 'Desar assignació')}
          </Button>
        )}
      </div>

      <div className="grid gap-3">
        {slots.map(slot => {
          const { system, tenant } = groupedBlocks(slot.types)
          const hasBlocks = system.length > 0 || tenant.length > 0
          const currentValue = mapping[slot.key] ?? NO_BLOCK

          return (
            <div key={slot.key} className="grid grid-cols-[180px_1fr] items-center gap-3">
              <label className="text-sm text-muted-foreground">
                {t(slot.labelKey, slot.fallback)}
              </label>
              <select
                value={currentValue}
                onChange={e => setMapping(m => ({ ...m, [slot.key]: e.target.value }))}
                disabled={!canWrite || !hasBlocks}
                className="h-8 w-full text-sm border rounded-md px-2 bg-background disabled:opacity-50"
              >
                <option value={NO_BLOCK}>{t('blockMapping.noBlockSelected', 'Cap bloc seleccionat')}</option>
                {system.length > 0 && (
                  <optgroup label={t('blocks.systemBadge', 'Sistema')}>
                    {system.map(b => (
                      <option key={b.id} value={b.id!}>{b.name}</option>
                    ))}
                  </optgroup>
                )}
                {tenant.length > 0 && (
                  <optgroup label={t('blocks.tenantBadge', 'Pròpia')}>
                    {tenant.map(b => (
                      <option key={b.id} value={b.id!}>{b.name}</option>
                    ))}
                  </optgroup>
                )}
              </select>
            </div>
          )
        })}
      </div>
    </div>
  )
}
