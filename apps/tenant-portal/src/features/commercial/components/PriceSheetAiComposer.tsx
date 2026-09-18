import { useMemo, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Sparkles } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Textarea } from '@/components/ui/textarea'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { getCatalogItems } from '@/features/catalog/api/catalogService'
import { listPublishedTemplatesForTenant } from '@/features/field-service/api/checklistTemplatesService'
import { AIGenerateAction } from '@/features/ai/components/AIGenerateAction'
import { usePriceSheetTitle } from '@/hooks/useSectorLabel'
import {
  applyPriceSheet,
  type PriceSheetLineInput,
} from '../api/commercialFlowService'
import { matchCatalogItemId, matchNamedId, parseAiJsonContent } from '../utils/aiJson'
import { priceSheetRpcErrorCopy, priceSheetRpcErrorTitle } from '../utils/rpcError'

const moneyFmt = new Intl.NumberFormat('ca-ES', {
  style: 'currency',
  currency: 'EUR',
})

type ProposedSheet = {
  mode: 'append' | 'replace'
  lines: PriceSheetLineInput[]
  checklistTemplateId: string | null
  checklistName: string | null
}

interface PriceSheetAiComposerProps {
  projectId: string
  currentLineCount: number
  open: boolean
  onClose: () => void
  onApplied: () => void
}

export function PriceSheetAiComposer({
  projectId,
  currentLineCount,
  open,
  onClose,
  onApplied,
}: PriceSheetAiComposerProps) {
  const { t } = useTranslation('projects')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()
  const priceSheetTitle = usePriceSheetTitle()
  const [prompt, setPrompt] = useState('')
  const [applying, setApplying] = useState(false)
  const [mode, setMode] = useState<'append' | 'replace'>(
    currentLineCount === 0 ? 'replace' : 'append',
  )
  const [proposal, setProposal] = useState<ProposedSheet | null>(null)

  const { data: catalogItems = [] } = useQuery({
    queryKey: ['catalog_items', activeTenant?.id],
    queryFn: getCatalogItems,
    enabled: open && !!activeTenant,
  })

  const { data: checklists = [] } = useQuery({
    queryKey: ['checklist_templates_published', activeTenant?.id],
    queryFn: () => listPublishedTemplatesForTenant(activeTenant!.id!),
    enabled: open && !!activeTenant?.id,
  })

  const catalogHint = useMemo(
    () =>
      catalogItems
        .slice(0, 40)
        .map((item) => `${item.name} [${item.id}] ${item.unit_price}€/${item.unit ?? 'u'}`)
        .join('\n'),
    [catalogItems],
  )

  const checklistHint = useMemo(
    () =>
      checklists
        .slice(0, 20)
        .map((tpl) => `${tpl.name} [${tpl.id}]`)
        .join('\n'),
    [checklists],
  )

  const messages = useMemo(
    () => [
      {
        role: 'user' as const,
        content: `Feina: ${prompt.trim()}\n\nCatàleg:\n${catalogHint || '(buit)'}\n\nChecklists:\n${checklistHint || '(cap)'}\n\nEl full actual té ${currentLineCount} línies.`,
      },
    ],
    [prompt, catalogHint, checklistHint, currentLineCount],
  )

  if (!open) return null

  function hydrateProposal(content: string) {
    const parsed = parseAiJsonContent(content) as {
        mode?: string
        lines?: Array<Record<string, unknown>>
        checklist_name?: string | null
        checklist_template_id?: string | null
      }
      const rawLines = Array.isArray(parsed.lines) ? parsed.lines : []
      const lines: PriceSheetLineInput[] = []
      for (const raw of rawLines) {
        const named = String(raw.name ?? '').trim()
        const catalogId =
          (typeof raw.catalog_item_id === 'string' &&
          catalogItems.some((item) => item.id === raw.catalog_item_id)
            ? raw.catalog_item_id
            : matchCatalogItemId(named, catalogItems)) ?? null
        const qty = Number(raw.quantity ?? 1)
        if (!named && !catalogId) continue
        lines.push({
          catalog_item_id: catalogId,
          kind: raw.kind === 'product' ? 'product' : 'service',
          name: named || catalogItems.find((item) => item.id === catalogId)?.name || '',
          quantity: Number.isFinite(qty) && qty > 0 ? qty : 1,
          unit: typeof raw.unit === 'string' ? raw.unit : undefined,
          unit_price: typeof raw.unit_price === 'number' ? raw.unit_price : undefined,
          discount_pct: typeof raw.discount_pct === 'number' ? raw.discount_pct : 0,
          tax_rate: typeof raw.tax_rate === 'number' ? raw.tax_rate : undefined,
        })
      }
      if (lines.length === 0) {
        throw new Error(t('projects.lines.ai_fill_empty', 'Encara no hi ha proposta.'))
      }
      const checklistName = parsed.checklist_name?.trim() || null
      const checklistId =
        (typeof parsed.checklist_template_id === 'string' &&
        checklists.some((tpl) => tpl.id === parsed.checklist_template_id)
          ? parsed.checklist_template_id
          : checklistName
            ? matchNamedId(
                checklistName,
                checklists.map((tpl) => ({ id: tpl.id, name: tpl.name })),
              )
            : null) ?? null
      const nextMode = parsed.mode === 'replace' || parsed.mode === 'append'
        ? parsed.mode
        : currentLineCount === 0
          ? 'replace'
          : 'append'
      setMode(nextMode)
      setProposal({
        mode: nextMode,
        lines,
        checklistTemplateId: checklistId,
        checklistName:
          checklistId
            ? checklists.find((tpl) => tpl.id === checklistId)?.name ?? checklistName
            : null,
      })
  }

  async function handleAccept() {
    if (!proposal) return
    setApplying(true)
    try {
      const result = await applyPriceSheet({
        projectId,
        lines: proposal.lines,
        mode,
        checklistTemplateId: proposal.checklistTemplateId,
      })
      await queryClient.invalidateQueries({ queryKey: ['project_lines', projectId] })
      await queryClient.invalidateQueries({ queryKey: ['checklist_runs', projectId] })
      toast({
        title: `${priceSheetTitle} escrit`,
        description:
          (result.skipped?.length ?? 0) > 0
            ? result.skipped?.map((row) => row.name || row.reason).join(', ')
            : undefined,
      })
      onApplied()
      onClose()
      setProposal(null)
      setPrompt('')
    } catch (err) {
      const copy = priceSheetRpcErrorCopy(err, priceSheetTitle)
      toast({
        variant: 'destructive',
        title: priceSheetRpcErrorTitle(t, copy),
        description: t(copy.descriptionKey, copy.descriptionFallback),
      })
    } finally {
      setApplying(false)
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-end sm:items-center justify-center bg-black/40 p-0 sm:p-4">
      <div className="w-full max-w-lg rounded-t-2xl sm:rounded-xl border border-border bg-background p-4 sm:p-6 shadow-lg max-h-[90vh] overflow-y-auto">
        <h3 className="mb-1 flex items-center gap-2 text-lg font-semibold text-foreground">
          <Sparkles className="h-4 w-4" />
          {`Compositor: ${priceSheetTitle}`}
        </h3>
        <p className="mb-4 text-sm text-muted-foreground">
          {t(
            'projects.lines.ai_fill_help',
            "Descriu la feina. La proposta es previsualitza; Acceptar escriu les línies (i la checklist, si n'hi ha).",
          )}
        </p>

        <Textarea
          value={prompt}
          onChange={(e) => setPrompt(e.target.value)}
          rows={4}
          className="mb-1 resize-y"
          placeholder={t('projects.lines.ai_fill_placeholder', 'Descriu la feina…')}
        />
        <p className="mb-3 text-xs text-muted-foreground">
          {t(
            'projects.lines.ai_fill_example',
            'Exemple: Revisió de quadre + 2 hores de tècnic i checklist de visita estàndard',
          )}
        </p>

        <div className="mb-4">
          <AIGenerateAction
            feature="commercial.price_sheet"
            messages={messages}
            responseFormat="json"
            disabled={!prompt.trim()}
            label={t('projects.lines.ai_fill_submit', 'Proposar')}
            onSuccess={(result) => {
              try {
                hydrateProposal(result.content)
              } catch (err) {
                toast({
                  variant: 'destructive',
                  title: t('projects.lines.ai_fill_failed', "No s'ha pogut escriure el full"),
                  description: err instanceof Error ? err.message : undefined,
                })
              }
            }}
          />
        </div>

        {proposal ? (
          <div className="mb-4 space-y-2 rounded-lg border border-border p-3">
            {proposal.lines.map((line, index) => (
              <div key={`${line.name}-${index}`} className="flex justify-between gap-2 text-sm">
                <span className="text-foreground">
                  {line.name} × {line.quantity}
                </span>
                {line.unit_price != null ? (
                  <span className="tabular-nums text-muted-foreground">
                    {moneyFmt.format(line.unit_price)}
                  </span>
                ) : null}
              </div>
            ))}
            {proposal.checklistName ? (
              <p className="text-xs text-muted-foreground">
                {t('projects.lines.ai_fill_checklist', 'Checklist: {{name}}', {
                  name: proposal.checklistName,
                })}
              </p>
            ) : null}
          </div>
        ) : (
          <p className="mb-4 text-sm text-muted-foreground">
            {t('projects.lines.ai_fill_empty', 'Encara no hi ha proposta.')}
          </p>
        )}

        {currentLineCount > 0 ? (
          <div className="mb-4 space-y-2">
            <label className="flex items-center gap-2 text-sm">
              <input
                type="radio"
                name="ai-sheet-mode"
                value="append"
                checked={mode === 'append'}
                onChange={() => setMode('append')}
              />
              {t('projects.lines.ai_fill_mode_append', 'Afegir al full')}
            </label>
            <label className="flex items-center gap-2 text-sm">
              <input
                type="radio"
                name="ai-sheet-mode"
                value="replace"
                checked={mode === 'replace'}
                onChange={() => setMode('replace')}
              />
              {t('projects.lines.ai_fill_mode_replace', 'Substituir el full')}
            </label>
          </div>
        ) : null}

        <div className="flex justify-end gap-2">
          <Button type="button" variant="outline" onClick={onClose} disabled={applying}>
            {t('projects.lines.form.cancel', 'Cancel·lar')}
          </Button>
          <Button type="button" onClick={() => void handleAccept()} disabled={!proposal || applying}>
            {t('projects.lines.ai_fill_accept', 'Acceptar i escriure el full')}
          </Button>
        </div>
      </div>
    </div>
  )
}
