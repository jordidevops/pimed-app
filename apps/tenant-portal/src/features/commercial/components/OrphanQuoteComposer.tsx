import { useEffect, useMemo, useRef, useState } from 'react'
import { Link, useLocation } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Plus, Printer, Trash2 } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { usePermission } from '@/hooks/usePermission'
import { useEffectiveSettings } from '@/hooks/useSettings'
import { getCatalogItems, type CatalogItem } from '@/features/catalog/api/catalogService'
import { unitSelectOptions } from '@/features/catalog/unitOptions'
import { useIsFieldService, usePriceSheetTitle, useSectorLabel } from '@/hooks/useSectorLabel'
import { useDocumentTemplates } from '@/features/signing/api/useDocumentTemplates'
import {
  formatMoney,
  partyDisplayName,
  type CommercialDocumentDetail,
  type CommercialDocumentLine,
} from '../utils/commercialDocumentModel'
import { printCommercialDocument } from '../utils/commercialDocumentPrint'
import { QUOTE_TEMPLATES_HREF, commercialTemplatesHref } from '../utils/commercialTemplatePaths'
import {
  deleteCommercialDocumentLine,
  issueOrphanCommercialDocument,
  cancelOrphanQuoteDraft,
  setCommercialDocumentTitle,
  setCommercialQuoteDraftProgress,
  upsertCommercialDocumentLine,
  type PriceSheetLineInput,
} from '../api/commercialFlowService'
import { commercialErrorMessage } from '../utils/commercialErrorMessage'
import {
  COMMERCIAL_QUOTE_TEMPLATE_ID_KEY,
  parseCommercialSettingId,
  parseFormalizationModeDefault,
  shouldSkipCommercialTemplateStep,
  type FormalizationMode,
} from '../utils/deviationApprovalThreshold'
import { DocumentTemplateSelect } from './AgreementTemplateSelect'
import { ApplyPricingTemplateDialog, type DocumentPriceLineDraft } from './ApplyPricingTemplateDialog'
import { ApplyCalculatorDialog } from './ApplyCalculatorDialog'
import { CopyFromJobDialog } from './CopyFromJobDialog'
import { LiveCommercialPreview } from './LiveCommercialPreview'
import { PriceSheetAiComposer } from './PriceSheetAiComposer'
import {
  FormalizationChoiceCards,
  QuoteDraftStepBar,
  canSelectQuoteDraftStep,
  type QuoteDraftStep,
} from './QuoteDraftStepBar'

const TAX_RATE_OPTIONS = [0, 4, 10, 21] as const
const DISCARD_REASONS = [
  { id: 'price', fallback: 'Error de preu' },
  { id: 'client', fallback: 'Client equivocat' },
  { id: 'duplicate', fallback: 'Duplicat' },
  { id: 'unneeded', fallback: 'Ja no cal' },
] as const

function inSentence(label: string): string {
  if (!label) return label
  return label.charAt(0).toLocaleLowerCase('ca') + label.slice(1)
}

function defaultQuoteTitle(
  clientName: string,
  t: (key: string, fallback: string, opts?: Record<string, string>) => string,
): string {
  const date = new Date().toLocaleDateString('ca-ES', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
  })
  return t('projects.orphan.default_title', 'Pressupost — {{client}} — {{date}}', {
    client: clientName,
    date,
  })
}
const fieldClass =
  'w-full rounded-md border border-border bg-background px-3 py-2 text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-ring'

function parseLineNumber(raw: string): number | null {
  const trimmed = raw.trim().replace(',', '.')
  if (!trimmed) return null
  const value = Number(trimmed)
  return Number.isFinite(value) ? value : null
}

function joinGapLabels(labels: string[]): string {
  if (labels.length <= 1) return labels[0] ?? ''
  return `${labels.slice(0, -1).join(', ')} i ${labels[labels.length - 1]}`
}

function lineFieldGaps(fields: {
  name: string
  qty: string
  price: string
  unit: string
}): Array<'name' | 'qty' | 'price' | 'unit'> {
  const gaps: Array<'name' | 'qty' | 'price' | 'unit'> = []
  if (!fields.name.trim()) gaps.push('name')
  const qty = parseLineNumber(fields.qty)
  if (qty == null || qty <= 0) gaps.push('qty')
  if (parseLineNumber(fields.price) == null) gaps.push('price')
  if (!fields.unit.trim()) gaps.push('unit')
  return gaps
}

function OrphanPriceSheetTable({
  lines,
  busy,
  onRemove,
}: {
  lines: CommercialDocumentLine[]
  busy: boolean
  onRemove: (lineId: string) => void
}) {
  const { t } = useTranslation('projects')
  const totalSubtotal = lines.reduce((acc, line) => acc + (line.line_subtotal ?? 0), 0)
  const totalWithTax = lines.reduce((acc, line) => acc + (line.line_total ?? 0), 0)

  return (
    <>
      <div className="space-y-2 sm:hidden">
        {lines.map((line) => (
          <div key={line.id} className="space-y-2 rounded-xl border border-border bg-card p-4">
            <div className="flex items-start justify-between gap-2">
              <div className="min-w-0">
                <p className="font-medium text-foreground">{line.name}</p>
                {line.description ? (
                  <p className="text-xs text-muted-foreground">{line.description}</p>
                ) : null}
              </div>
              <button
                type="button"
                title={t('projects.lines.delete_line', 'Eliminar línia')}
                disabled={busy}
                onClick={() => onRemove(line.id)}
                className="rounded-lg p-1.5 text-muted-foreground hover:bg-destructive/10 hover:text-destructive disabled:opacity-50"
              >
                <Trash2 className="h-4 w-4" />
              </button>
            </div>
            <div className="flex flex-wrap gap-x-3 gap-y-1 text-sm tabular-nums text-muted-foreground">
              <span>
                {line.quantity} {line.unit}
              </span>
              <span>{formatMoney(line.unit_price)}</span>
              {(line.discount_pct ?? 0) > 0 ? <span>−{line.discount_pct}%</span> : null}
            </div>
            <div className="flex justify-between text-sm">
              <span className="text-muted-foreground">{t('projects.lines.columns.total', 'Total')}</span>
              <span className="font-semibold tabular-nums text-foreground">{formatMoney(line.line_total)}</span>
            </div>
          </div>
        ))}
        <div className="space-y-1 rounded-xl border border-border bg-muted/20 px-4 py-3">
          <div className="flex justify-between text-sm text-muted-foreground">
            <span>{t('projects.lines.totals.subtotal', 'Subtotal (sense IVA)')}</span>
            <span className="font-medium tabular-nums text-foreground">{formatMoney(totalSubtotal)}</span>
          </div>
          <div className="flex justify-between text-sm text-muted-foreground">
            <span>{t('projects.lines.totals.tax', 'IVA')}</span>
            <span className="font-medium tabular-nums text-foreground">{formatMoney(totalWithTax - totalSubtotal)}</span>
          </div>
          <div className="flex justify-between text-sm font-semibold text-foreground">
            <span>{t('projects.lines.totals.total', 'Total (amb IVA)')}</span>
            <span className="tabular-nums">{formatMoney(totalWithTax)}</span>
          </div>
        </div>
      </div>

      <div className="hidden w-max max-w-full overflow-x-auto overflow-y-hidden rounded-xl border border-border sm:block">
        <table className="w-max text-sm">
          <thead>
            <tr className="border-b border-border bg-muted/40">
              <th className="px-4 py-2.5 text-left font-medium text-muted-foreground">
                {t('projects.lines.columns.name', 'Descripció')}
              </th>
              <th className="px-4 py-2.5 text-right font-medium text-muted-foreground">
                {t('projects.lines.columns.quantity', 'Qtd')}
              </th>
              <th className="hidden px-4 py-2.5 text-left font-medium text-muted-foreground md:table-cell">
                {t('projects.lines.columns.unit', 'Unitat')}
              </th>
              <th className="px-4 py-2.5 text-right font-medium text-muted-foreground">
                {t('projects.lines.columns.unit_price', 'Preu unit.')}
              </th>
              <th className="hidden px-4 py-2.5 text-right font-medium text-muted-foreground md:table-cell">
                {t('projects.lines.columns.discount', 'Dte%')}
              </th>
              <th className="px-4 py-2.5 text-right font-medium text-muted-foreground">
                {t('projects.lines.columns.tax_rate', 'IVA%')}
              </th>
              <th className="px-4 py-2.5 text-right font-medium text-muted-foreground">
                {t('projects.lines.columns.subtotal', 'Subtotal')}
              </th>
              <th className="px-4 py-2.5 text-right font-medium text-muted-foreground">
                {t('projects.lines.columns.total', 'Total')}
              </th>
              <th className="w-10" />
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {lines.map((line) => (
              <tr key={line.id} className="transition-colors hover:bg-muted/20">
                <td className="max-w-sm px-3 py-2.5 font-medium text-foreground">
                  {line.name}
                  {line.description ? (
                    <span className="mt-0.5 block text-xs font-normal text-muted-foreground">{line.description}</span>
                  ) : null}
                </td>
                <td className="whitespace-nowrap px-3 py-2.5 text-right tabular-nums text-muted-foreground">{line.quantity}</td>
                <td className="hidden whitespace-nowrap px-3 py-2.5 text-muted-foreground md:table-cell">{line.unit}</td>
                <td className="whitespace-nowrap px-3 py-2.5 text-right tabular-nums text-muted-foreground">
                  {formatMoney(line.unit_price)}
                </td>
                <td className="hidden whitespace-nowrap px-3 py-2.5 text-right text-muted-foreground md:table-cell">
                  {line.discount_pct != null ? `${line.discount_pct}%` : '0%'}
                </td>
                <td className="whitespace-nowrap px-3 py-2.5 text-right text-muted-foreground">
                  {line.tax_rate != null ? `${line.tax_rate}%` : '—'}
                </td>
                <td className="whitespace-nowrap px-3 py-2.5 text-right tabular-nums text-muted-foreground">
                  {formatMoney(line.line_subtotal)}
                </td>
                <td className="whitespace-nowrap px-3 py-2.5 text-right font-medium tabular-nums text-foreground">
                  {formatMoney(line.line_total)}
                </td>
                <td className="px-2 py-2.5 text-right">
                  <button
                    type="button"
                    title={t('projects.lines.delete_line', 'Eliminar línia')}
                    disabled={busy}
                    onClick={() => onRemove(line.id)}
                    className="rounded-lg p-1.5 text-muted-foreground transition-colors hover:bg-destructive/10 hover:text-destructive disabled:opacity-50"
                  >
                    <Trash2 className="h-4 w-4" />
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr className="border-t border-border bg-muted/20">
              <td colSpan={6} className="px-4 py-2.5 text-right text-sm font-medium text-muted-foreground">
                {t('projects.lines.totals.subtotal', 'Subtotal (sense IVA)')}
              </td>
              <td className="px-4 py-2.5 text-right font-semibold tabular-nums text-foreground">
                {formatMoney(totalSubtotal)}
              </td>
              <td colSpan={2} />
            </tr>
            <tr className="border-t border-border bg-muted/10">
              <td colSpan={6} className="px-4 py-2.5 text-right text-sm font-medium text-muted-foreground">
                {t('projects.lines.totals.tax', 'IVA')}
              </td>
              <td className="px-4 py-2.5 text-right font-semibold tabular-nums text-foreground">
                {formatMoney(totalWithTax - totalSubtotal)}
              </td>
              <td colSpan={2} />
            </tr>
            <tr className="border-t border-border">
              <td colSpan={6} className="px-4 py-2.5 text-right text-sm font-semibold text-foreground">
                {t('projects.lines.totals.total', 'Total (amb IVA)')}
              </td>
              <td className="px-4 py-2.5 text-right text-base font-bold tabular-nums text-foreground">
                {formatMoney(totalWithTax)}
              </td>
              <td colSpan={2} />
            </tr>
          </tfoot>
        </table>
      </div>
    </>
  )
}

function isQuoteDraftStep(value: unknown): value is QuoteDraftStep {
  return value === 'lines' || value === 'template' || value === 'issue'
}

type Props = {
  documentId: string
  status: string
  projectId: string | null
  lines: CommercialDocumentLine[]
  title?: string | null
  formalizationMode?: string | null
  doc: CommercialDocumentDetail
  clientId?: string | null
  onChanged: () => void
}

type DraftNavState = {
  templateId?: string | null
  step?: QuoteDraftStep
}

export function OrphanQuoteComposer({
  documentId,
  status,
  projectId,
  lines,
  title,
  formalizationMode,
  doc,
  clientId = null,
  onChanged,
}: Props) {
  const { t } = useTranslation(['projects', 'common'])
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const canEditPricing = usePermission('commercial.pricing.edit')
  const location = useLocation()
  const priceSheetTitle = usePriceSheetTitle()
  const isFieldService = useIsFieldService()
  const contactLabel = useSectorLabel('contact', isFieldService ? 'Client' : 'Contacte')
  const contactWord = inSentence(contactLabel)
  const nav = (location.state ?? null) as DraftNavState | null
  const [step, setStep] = useState<QuoteDraftStep>(
    nav?.step ?? (isQuoteDraftStep(doc.draft_wizard_step) ? doc.draft_wizard_step : 'lines'),
  )
  const [lineOpen, setLineOpen] = useState(false)
  const [discardOpen, setDiscardOpen] = useState(false)
  const [discardReason, setDiscardReason] = useState('')
  const [titleTouched, setTitleTouched] = useState(Boolean(title?.trim()))
  const [copyOpen, setCopyOpen] = useState(false)
  const [aiOpen, setAiOpen] = useState(false)
  const [templateOpen, setTemplateOpen] = useState(false)
  const [calculatorOpen, setCalculatorOpen] = useState(false)
  const [docTitle, setDocTitle] = useState(title ?? '')
  const [catalogId, setCatalogId] = useState('')
  const [kind, setKind] = useState<'service' | 'product'>('service')
  const [name, setName] = useState('')
  const [notes, setNotes] = useState('')
  const [qty, setQty] = useState('1')
  const [price, setPrice] = useState('0')
  const [unit, setUnit] = useState('u')
  const [discount, setDiscount] = useState('0')
  const [tax, setTax] = useState('21')
  const [busy, setBusy] = useState(false)
  const [mode, setMode] = useState<FormalizationMode>('signed_quote')
  const [modeTouched, setModeTouched] = useState(false)
  const [templateId, setTemplateId] = useState(nav?.templateId ?? doc.full_body_template_id ?? '')
  const docTitleRef = useRef(title ?? '')
  const savedTitleRef = useRef((title ?? '').trim())
  const titleFocusedRef = useRef(false)

  const { data: effective } = useEffectiveSettings(
    { tenantId: activeTenant?.id ?? '' },
    { enabled: !!activeTenant?.id },
  )
  const skipTemplateByDefault = shouldSkipCommercialTemplateStep(
    effective,
    COMMERCIAL_QUOTE_TEMPLATE_ID_KEY,
  )
  const defaultQuoteTemplateId =
    parseCommercialSettingId(effective, COMMERCIAL_QUOTE_TEMPLATE_ID_KEY) ?? ''
  const [forceAskTemplate, setForceAskTemplate] = useState(false)
  const { data: templates = [] } = useDocumentTemplates(activeTenant?.id)
  const quoteTemplates = useMemo(
    () =>
      templates.filter(
        (tpl) =>
          tpl.category === 'quote' &&
          (tpl.template_type === 'html' || tpl.template_type === 'docx') &&
          !!tpl.id,
      ),
    [templates],
  )
  const { data: catalogItems = [] } = useQuery<CatalogItem[]>({
    queryKey: ['catalog_items', activeTenant?.id],
    queryFn: () => getCatalogItems(),
    enabled: !!activeTenant?.id,
  })

  const isDraft = status === 'draft' && !projectId
  const isOrphan = !projectId

  const openIssuedQuery = useQuery({
    queryKey: ['commercial', 'orphan-open-issued', clientId, documentId],
    queryFn: async () => {
      const { count, error } = await supabase
        .from('commercial_documents' as never)
        .select('id', { count: 'exact', head: true })
        .eq('client_id', clientId!)
        .eq('doc_type', 'quote')
        .eq('status', 'issued')
        .is('project_id', null)
      if (error) throw error
      return count ?? 0
    },
    enabled: isDraft && !!clientId,
  })

  const lineGaps = lineFieldGaps({ name, qty, price, unit })
  const addLineBlocked = lineGaps.length > 0

  useEffect(() => {
    docTitleRef.current = docTitle
  }, [docTitle])

  useEffect(() => {
    if (titleFocusedRef.current) return
    if (title?.trim()) {
      setDocTitle(title)
      return
    }
    if (titleTouched) return
    const clientName = partyDisplayName(doc.buyer_snapshot)
    if (!clientName || clientName === '—') return
    setDocTitle(defaultQuoteTitle(clientName, t))
  }, [title, titleTouched, doc.buyer_snapshot, t])

  useEffect(() => {
    if (nav?.templateId) setTemplateId(nav.templateId)
    if (nav?.step) setStep(nav.step)
  }, [nav?.templateId, nav?.step])

  useEffect(() => {
    if (nav?.templateId || doc.full_body_template_id) return
    if (skipTemplateByDefault && !forceAskTemplate && !templateId && defaultQuoteTemplateId) {
      setTemplateId(defaultQuoteTemplateId)
    }
  }, [
    defaultQuoteTemplateId,
    doc.full_body_template_id,
    forceAskTemplate,
    nav?.templateId,
    skipTemplateByDefault,
    templateId,
  ])

  async function saveProgress(patch: {
    templateId?: string | null
    setTemplate?: boolean
    formalizationMode?: FormalizationMode
    wizardStep?: QuoteDraftStep
  }) {
    if (status !== 'draft') return
    try {
      await setCommercialQuoteDraftProgress({ documentId, ...patch })
    } catch (err) {
      toast({
        variant: 'destructive',
        description: commercialErrorMessage(err, t('common:error', 'Error')),
      })
    }
  }

  function goStep(next: QuoteDraftStep) {
    setStep(next)
    void saveProgress({ wizardStep: next })
    void saveTitle()
  }

  function goAfterLines() {
    if (skipTemplateByDefault && !forceAskTemplate) {
      goStep('issue')
      return
    }
    goStep('template')
  }

  function goBackFromIssue() {
    if (skipTemplateByDefault && !forceAskTemplate) {
      goStep('lines')
      return
    }
    goStep('template')
  }

  function chooseTemplate(id: string) {
    setTemplateId(id)
    void saveProgress({ templateId: id, setTemplate: true })
  }

  async function writeRows(rows: DocumentPriceLineDraft[], modeWrite: 'append' | 'replace') {
    if (modeWrite === 'replace') {
      for (const line of lines) {
        await deleteCommercialDocumentLine(line.id)
      }
    }
    let position = modeWrite === 'replace' ? 1 : lines.length + 1
    for (const row of rows) {
      if (!row.name.trim()) continue
      await upsertCommercialDocumentLine({
        documentId,
        catalogItemId: row.catalogItemId ?? null,
        kind: row.kind === 'product' ? 'product' : 'service',
        name: row.name.trim(),
        description: row.description ?? null,
        unit: row.unit || 'u',
        quantity: row.quantity,
        unitPrice: row.unitPrice,
        discountPct: row.discountPct,
        taxRate: row.taxRate,
        position,
      })
      position += 1
    }
    onChanged()
  }

  async function copyFromProject(sourceProjectId: string, modeWrite: 'append' | 'replace') {
    const { data, error } = await supabase
      .from('project_lines')
      .select('*')
      .eq('project_id', sourceProjectId)
      .order('position', { ascending: true })
    if (error) throw error
    const rows: DocumentPriceLineDraft[] = (data ?? []).map((row) => ({
      catalogItemId: row.catalog_item_id,
      kind: row.kind === 'product' ? 'product' : 'service',
      name: row.name ?? '',
      description: row.description,
      unit: row.unit ?? 'u',
      quantity: Number(row.quantity ?? 1),
      unitPrice: Number(row.unit_price ?? 0),
      discountPct: Number(row.discount_pct ?? 0),
      taxRate: Number(row.tax_rate ?? 21),
    }))
    await writeRows(rows, modeWrite)
  }

  async function applyAiLines(aiLines: PriceSheetLineInput[], modeWrite: 'append' | 'replace') {
    await writeRows(
      aiLines.map((line) => ({
        catalogItemId: line.catalog_item_id,
        kind: line.kind,
        name: line.name ?? '',
        description: line.description,
        unit: line.unit,
        quantity: line.quantity,
        unitPrice: Number(line.unit_price ?? 0),
        discountPct: Number(line.discount_pct ?? 0),
        taxRate: Number(line.tax_rate ?? 21),
      })),
      modeWrite,
    )
  }

  useEffect(() => {
    if (modeTouched) return
    if (formalizationMode === 'signed_quote' || formalizationMode === 'separate_agreement') {
      setMode(formalizationMode)
      return
    }
    setMode(parseFormalizationModeDefault(effective))
  }, [formalizationMode, effective, modeTouched])

  async function saveTitle() {
    const next = docTitleRef.current.trim()
    if (!next || next === savedTitleRef.current) return
    try {
      await setCommercialDocumentTitle({ documentId, title: next })
      savedTitleRef.current = next
    } catch (err) {
      toast({
        variant: 'destructive',
        description: commercialErrorMessage(err, t('common:error', 'Error')),
      })
    }
  }

  useEffect(() => {
    if (status !== 'draft') return
    const handle = window.setTimeout(() => {
      void saveTitle()
    }, 600)
    return () => window.clearTimeout(handle)
  }, [docTitle, status])

  useEffect(() => {
    return () => {
      const next = docTitleRef.current.trim()
      if (status === 'draft' && next && next !== savedTitleRef.current) {
        void setCommercialDocumentTitle({ documentId, title: next })
      }
    }
  }, [documentId, status])

  async function addLine() {
    if (lineFieldGaps({ name, qty, price, unit }).length > 0) return
    setBusy(true)
    try {
      await upsertCommercialDocumentLine({
        documentId,
        catalogItemId: catalogId || null,
        name: name.trim(),
        description: notes.trim() || null,
        kind,
        unit,
        quantity: Number(qty.replace(',', '.')) || 1,
        unitPrice: Number(price.replace(',', '.')) || 0,
        discountPct: Number(discount.replace(',', '.')) || 0,
        taxRate: Number(tax.replace(',', '.')) || 21,
      })
      setCatalogId('')
      setKind('service')
      setName('')
      setNotes('')
      setQty('1')
      setPrice('0')
      setUnit('u')
      setDiscount('0')
      setTax('21')
      setLineOpen(false)
      onChanged()
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('common:error', 'Error'),
      })
    } finally {
      setBusy(false)
    }
  }

  async function removeLine(lineId: string) {
    setBusy(true)
    try {
      await deleteCommercialDocumentLine(lineId)
      onChanged()
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('common:error', 'Error'),
      })
    } finally {
      setBusy(false)
    }
  }

  async function issue() {
    setBusy(true)
    try {
      const nextTitle = docTitle.trim()
      if (nextTitle && nextTitle !== (title ?? '').trim()) {
        await setCommercialDocumentTitle({ documentId, title: nextTitle })
      }
      await issueOrphanCommercialDocument({
        documentId,
        formalizationMode: mode,
        fullBodyTemplateId: templateId || null,
      })
      toast({ title: t('projects.orphan.issued', 'Pressupost emès') })
      onChanged()
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('common:error', 'Error'),
      })
    } finally {
      setBusy(false)
    }
  }

  async function discard() {
    setBusy(true)
    try {
      await cancelOrphanQuoteDraft(documentId, discardReason)
      setDiscardOpen(false)
      toast({ title: t('projects.orphan.discarded', 'Pressupost anul·lat') })
      onChanged()
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('common:error', 'Error'),
      })
    } finally {
      setBusy(false)
    }
  }

  if (!isOrphan || !isDraft) return null

  const openIssuedCount = openIssuedQuery.data ?? 0
  const issueDisabledReason = !docTitle.trim()
    ? t('projects.orphan.issue_needs_title', 'Escriu un títol per poder emetre.')
    : lines.length === 0
      ? t('projects.commercial.issue_needs_lines', 'Afegeix almenys una línia al full de preus.')
      : null
  const quoteTemplateOptions = quoteTemplates.map((tpl) => ({
    id: tpl.id!,
    name: tpl.name,
    is_platform_default: tpl.is_platform_default,
    template_type: tpl.template_type,
    default_block_mapping:
      (tpl.default_block_mapping as Record<string, string> | null | undefined) ?? null,
  }))

  return (
    <section className="space-y-4 rounded-xl border border-border bg-card p-4">
      <QuoteDraftStepBar
        step={step}
        onStepSelect={goStep}
        canSelectStep={(next) => canSelectQuoteDraftStep(step, next, lines.length > 0)}
        actions={
          step === 'lines' ? (
            <Button type="button" disabled={lines.length === 0} onClick={goAfterLines}>
              {t('projects.quotes.wizard_continue', 'Continuar')}
            </Button>
          ) : step === 'template' ? (
            <>
              <Button type="button" variant="outline" onClick={() => goStep('lines')}>
                {t('projects.quotes.wizard_back', 'Enrere')}
              </Button>
              <Button type="button" onClick={() => goStep('issue')}>
                {t('projects.quotes.wizard_continue', 'Continuar')}
              </Button>
            </>
          ) : (
            <>
              <Button type="button" variant="outline" onClick={goBackFromIssue}>
                {t('projects.quotes.wizard_back', 'Enrere')}
              </Button>
              <Button type="button" variant="ghost" disabled={busy} onClick={() => setDiscardOpen(true)}>
                {t('projects.orphan.discard', 'Descartar')}
              </Button>
              <Button type="button" disabled={busy || issueDisabledReason != null} onClick={() => void issue()}>
                {t('projects.orphan.issue', 'Emetre pressupost')}
              </Button>
            </>
          )
        }
      />
      {step === 'lines' && lines.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('projects.orphan.continue_needs_lines', 'Afegeix almenys una línia per continuar.')}
        </p>
      ) : null}
      {step === 'issue' && issueDisabledReason ? (
        <p className="text-sm text-muted-foreground">{issueDisabledReason}</p>
      ) : null}
      {step === 'lines' ? (
        <div className="space-y-4">
          <div className="flex items-start justify-between gap-3">
            <div className="min-w-0">
              <h2 className="text-lg font-semibold text-foreground">{priceSheetTitle}</h2>
              <p className="mt-1 text-sm text-muted-foreground">
                {t('projects.orphan.lines_step_help', 'Omple el full. El pas següent és la plantilla.')}
              </p>
            </div>
            <div className="flex shrink-0 flex-col gap-2 sm:flex-row">
              <Button size="sm" variant="outline" onClick={() => setCopyOpen(true)}>
                {t('projects.lines.copy_from_job', "Copiar d'una feina")}
              </Button>
              <Button size="sm" variant="outline" onClick={() => setAiOpen(true)}>
                {t('projects.lines.ai_fill', 'Omplir amb IA')}
              </Button>
              <Button size="sm" variant="outline" onClick={() => setTemplateOpen(true)}>
                {t('projects.lines.apply_template', 'Servei habitual')}
              </Button>
              {canEditPricing ? (
                <Button size="sm" variant="outline" onClick={() => setCalculatorOpen(true)}>
                  {t('projects.lines.apply_calculator', 'Calculadora')}
                </Button>
              ) : null}
              <Button size="sm" onClick={() => setLineOpen(true)}>
                <Plus className="mr-1.5 h-4 w-4" />
                {t('projects.lines.add_line', 'Afegir línia')}
              </Button>
              {!templateId ? (
                <Button
                  size="sm"
                  variant="outline"
                  className="px-2"
                  title={t(
                    'projects.orphan.print_standard_hint',
                    'Imprimeix aquest esborrany amb el format estàndard: client, línies i emissor. No fa servir una plantilla pròpia.',
                  )}
                  onClick={() => {
                    void printCommercialDocument(doc).catch((err: unknown) => {
                      toast({
                        variant: 'destructive',
                        description: err instanceof Error ? err.message : t('common:error', 'Error'),
                      })
                    })
                  }}
                >
                  <Printer className="h-4 w-4" />
                  <span className="sr-only">{t('projects.commercial.share_print', 'Imprimir HTML')}</span>
                </Button>
              ) : null}
            </div>
          </div>
          {lines.length === 0 ? (
            <div className="flex flex-col items-center justify-center gap-2 rounded-xl border border-dashed border-border py-10">
              <p className="text-sm text-muted-foreground">
                {t('projects.lines.empty', "No hi ha línies d'imports")}
              </p>
            </div>
          ) : (
            <OrphanPriceSheetTable lines={lines} busy={busy} onRemove={(id) => void removeLine(id)} />
          )}
          <div className="flex justify-end border-t border-border pt-3">
            <Button type="button" disabled={lines.length === 0} onClick={goAfterLines}>
              {t('projects.quotes.wizard_continue', 'Continuar')}
            </Button>
          </div>
        </div>
      ) : null}
      {step === 'template' ? (
        <div className="space-y-4">
          <div>
            <h2 className="text-lg font-semibold text-foreground">{t('projects.orphan.guide_template', 'Plantilla')}</h2>
            <p className="mt-1 text-sm text-muted-foreground">
              {t('projects.orphan.template_step_help', 'La vista prèvia fa servir el client i les línies d’aquest esborrany.')}
            </p>
          </div>
          <DocumentTemplateSelect
            templates={quoteTemplateOptions}
            value={templateId}
            onChange={chooseTemplate}
            previewFor={(id) => <LiveCommercialPreview doc={doc} templateId={id} />}
            disabled={busy}
            emptyOptionLabel={t(
              'projects.orphan.system_format',
              'Format estàndard (sense plantilla pròpia)',
            )}
            pickerTitle={t('projects.quotes.template_picker_title', 'Plantilla de pressupost')}
            pickerDescription={t(
              'projects.quotes.template_picker_help',
              'Cerca i previsualitza la plantilla que s’usarà per a aquest pressupost.',
            )}
            searchPlaceholder={t(
              'projects.quotes.create_template_search',
              'Cerca plantilla de pressupost…',
            )}
            emptyPreviewMessage={t(
              'projects.orphan.system_format_help',
              'És el document que genera PiMed si no tries una plantilla. Aquesta vista fa servir el client i les línies d’aquest esborrany.',
            )}
            emptyPreview={<LiveCommercialPreview doc={doc} templateId="" />}
          />
          <p className="text-xs text-muted-foreground">
            {t(
              'projects.orphan.system_format_help',
              'És el document que genera PiMed si no tries una plantilla. Aquesta vista fa servir el client i les línies d’aquest esborrany.',
            )}
          </p>
          <span className="text-xs text-muted-foreground">
            <Link to={QUOTE_TEMPLATES_HREF} className="text-indigo-600 hover:underline">
              {t('projects.quotes.manage_templates', 'Gestionar plantilles')}
            </Link>
            {' · '}
            <Link
              to={commercialTemplatesHref('quote', { create: true })}
              className="text-indigo-600 hover:underline"
            >
              {t('projects.quotes.templates_new', 'Nova plantilla')}
            </Link>
          </span>
          <LiveCommercialPreview doc={doc} templateId={templateId} />
          <div className="flex justify-between border-t border-border pt-3">
            <Button type="button" variant="outline" onClick={() => goStep('lines')}>
              {t('projects.quotes.wizard_back', 'Enrere')}
            </Button>
            <Button type="button" onClick={() => goStep('issue')}>
              {t('projects.quotes.wizard_continue', 'Continuar')}
            </Button>
          </div>
        </div>
      ) : null}
      {step === 'issue' ? (
        <div id="commercial-issue-quote" className="space-y-4">
          <div>
            <h2 className="text-lg font-semibold text-foreground">{t('projects.orphan.guide_issue', 'Emetre')}</h2>
            <p className="mt-1 text-sm text-muted-foreground">
              {t('projects.orphan.issue_step_help', 'El número oficial s’assigna ara. Després ja no es reescriu aquest PDF.')}
            </p>
          </div>
          <div className="space-y-1">
            <Label htmlFor="orphan-quote-title">{t('projects.orphan.title_label', 'Títol')}</Label>
            <Input
              id="orphan-quote-title"
              value={docTitle}
              maxLength={120}
              onChange={(e) => {
                setTitleTouched(true)
                setDocTitle(e.target.value)
              }}
              onFocus={() => {
                titleFocusedRef.current = true
              }}
              onBlur={() => {
                titleFocusedRef.current = false
                void saveTitle()
              }}
            />
          </div>
          <FormalizationChoiceCards
            mode={mode}
            disabled={busy}
            onChange={(next) => {
              setModeTouched(true)
              setMode(next)
              void saveProgress({ formalizationMode: next })
            }}
          />
          {skipTemplateByDefault ? (
            <div className="flex items-center justify-between gap-2 rounded-xl border border-border bg-muted/30 px-3 py-2">
              <p className="text-sm text-muted-foreground">
                {t(
                  'projects.quotes.using_default_template',
                  'S’usarà la plantilla per defecte del tenant.',
                )}
              </p>
              <Button
                type="button"
                variant="ghost"
                size="sm"
                disabled={busy}
                onClick={() => {
                  setForceAskTemplate(true)
                  goStep('template')
                }}
              >
                {t('projects.quotes.wizard_change_default', 'Canviar')}
              </Button>
            </div>
          ) : null}
          {lines.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {t('projects.commercial.issue_needs_lines', 'Afegeix almenys una línia al full de preus.')}
            </p>
          ) : null}
          {openIssuedCount > 0 ? (
            <p className="rounded-md border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-950 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-100">
              {t(
                'projects.orphan.open_issued_warn',
                'Aquest {{contact}} ja té {{count}} pressupost(os) emès(os) sense ordre. Pots crear-ne un altre.',
                { contact: contactWord, count: openIssuedCount },
              )}
            </p>
          ) : null}
          <div className="flex flex-wrap items-center justify-between gap-2 border-t border-border pt-3">
            <Button type="button" variant="outline" onClick={goBackFromIssue}>
              {t('projects.quotes.wizard_back', 'Enrere')}
            </Button>
            <div className="flex flex-wrap gap-2">
              <Button type="button" variant="ghost" disabled={busy} onClick={() => setDiscardOpen(true)}>
                {t('projects.orphan.discard', 'Descartar')}
              </Button>
              <Button type="button" disabled={busy || issueDisabledReason != null} onClick={() => void issue()}>
                {t('projects.orphan.issue', 'Emetre pressupost')}
              </Button>
            </div>
            {issueDisabledReason ? (
              <p className="w-full text-sm text-muted-foreground">{issueDisabledReason}</p>
            ) : null}
          </div>
        </div>
      ) : null}
      <Dialog open={lineOpen} onOpenChange={setLineOpen}>
        <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-lg">
          <DialogHeader>
            <DialogTitle>{t('projects.lines.add_line', 'Afegir línia')}</DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            <div className="space-y-1">
              <Label htmlFor="orphan-catalog">{t('projects.lines.form.catalog_item_label', 'Ítem del catàleg')}</Label>
              <select
                id="orphan-catalog"
                className={fieldClass}
                value={catalogId}
                onChange={(e) => {
                  const selectedId = e.target.value
                  setCatalogId(selectedId)
                  const found = catalogItems.find((item) => item.id === selectedId)
                  if (!found) return
                  if (found.name) setName(found.name)
                  if (found.unit) setUnit(found.unit)
                  if (found.unit_price != null) setPrice(String(found.unit_price))
                  if (found.tax_rate != null) setTax(String(found.tax_rate))
                  if (found.kind === 'product' || found.kind === 'service') setKind(found.kind)
                }}
              >
                <option value="">{t('projects.lines.form.catalog_item_placeholder', 'Selecciona o escriu per cercar...')}</option>
                {catalogItems.map((item) => (
                  <option key={item.id} value={item.id ?? ''}>
                    {item.name}
                    {item.sku ? ` (${item.sku})` : ''}
                  </option>
                ))}
              </select>
            </div>
            <div className="grid grid-cols-3 gap-3">
              <div className="space-y-1">
                <Label htmlFor="orphan-kind">{t('projects.orphan.line_kind', 'Tipus')}</Label>
                <select id="orphan-kind" className={fieldClass} value={kind} onChange={(e) => setKind(e.target.value === 'product' ? 'product' : 'service')}>
                  <option value="service">{t('projects.lines.form.kind_service', 'Servei')}</option>
                  <option value="product">{t('projects.lines.form.kind_product', 'Producte')}</option>
                </select>
              </div>
              <div className="col-span-2 space-y-1">
                <Label htmlFor="orphan-line-name">{t('projects.lines.form.name_label', 'Descripció')}</Label>
                <Input id="orphan-line-name" value={name} onChange={(e) => setName(e.target.value)} />
              </div>
            </div>
            <div className="grid grid-cols-3 gap-3">
              <div className="space-y-1">
                <Label htmlFor="orphan-qty">{t('projects.lines.form.quantity_label', 'Quantitat')}</Label>
                <Input id="orphan-qty" type="number" step="0.01" min="0" value={qty} onChange={(e) => setQty(e.target.value)} />
              </div>
              <div className="space-y-1">
                <Label htmlFor="orphan-unit">{t('projects.lines.form.unit_label', 'Unitat')}</Label>
                <select id="orphan-unit" className={fieldClass} value={unit} onChange={(e) => setUnit(e.target.value)}>
                  {unitSelectOptions(unit).map((option) => (
                    <option key={option} value={option}>{option}</option>
                  ))}
                </select>
              </div>
              <div className="space-y-1">
                <Label htmlFor="orphan-price">{t('projects.lines.form.unit_price_label', 'Preu unitari')}</Label>
                <Input id="orphan-price" type="number" step="0.01" min="0" value={price} onChange={(e) => setPrice(e.target.value)} />
              </div>
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1">
                <Label htmlFor="orphan-discount">{t('projects.lines.form.discount_label', 'Descompte (%)')}</Label>
                <Input id="orphan-discount" type="number" step="0.01" min="0" max="100" value={discount} onChange={(e) => setDiscount(e.target.value)} />
              </div>
              <div className="space-y-1">
                <Label htmlFor="orphan-tax">{t('projects.lines.form.tax_rate_label', 'IVA (%)')}</Label>
                <select id="orphan-tax" className={fieldClass} value={tax} onChange={(e) => setTax(e.target.value)}>
                  {TAX_RATE_OPTIONS.map((rate) => (
                    <option key={rate} value={rate}>{rate}%</option>
                  ))}
                </select>
              </div>
            </div>
            <div className="space-y-1">
              <Label htmlFor="orphan-notes">{t('projects.lines.form.notes_label', 'Notes')}</Label>
              <textarea id="orphan-notes" rows={2} value={notes} onChange={(e) => setNotes(e.target.value)} className={`${fieldClass} resize-none`} />
            </div>
            {addLineBlocked ? (
              <p className="text-sm text-muted-foreground">
                {t('projects.orphan.add_line_blocked', 'No es pot afegir la línia: falta {{fields}}.', {
                  fields: joinGapLabels(lineGaps.map((gap) => t(`projects.orphan.line_gap_${gap}`, gap))),
                })}
              </p>
            ) : null}
          </div>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => setLineOpen(false)}>
              {t('common:cancel', 'Cancel·lar')}
            </Button>
            <Button type="button" disabled={busy || addLineBlocked} onClick={() => void addLine()}>
              {t('projects.orphan.add_line', 'Afegir línia')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      <Dialog
        open={discardOpen}
        onOpenChange={(open) => {
          setDiscardOpen(open)
          if (!open) setDiscardReason('')
        }}
      >
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>{t('projects.orphan.discard_title', 'Deixar el pressupost com a anul·lat')}</DialogTitle>
            <DialogDescription>
              {t(
                'projects.orphan.discard_help',
                'No s’esborra. Queda a l’historial amb l’estat Anul·lat, amb qui l’ha anul·lat i el motiu.',
              )}
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-2">
            <Label htmlFor="orphan-discard-reason">{t('projects.orphan.discard_reason', 'Motiu')}</Label>
            <div className="flex flex-wrap gap-2">
              {DISCARD_REASONS.map((chip) => {
                const label = t(`projects.orphan.discard_reason_${chip.id}`, chip.fallback)
                const selected = discardReason === label
                return (
                  <button
                    key={chip.id}
                    type="button"
                    aria-pressed={selected}
                    className={`rounded-full border px-2.5 py-1 text-xs ${
                      selected ? 'border-primary bg-primary/10 font-medium' : 'border-border text-muted-foreground'
                    }`}
                    onClick={() => setDiscardReason(label)}
                  >
                    {label}
                  </button>
                )
              })}
            </div>
            <textarea
              id="orphan-discard-reason"
              rows={3}
              maxLength={500}
              value={discardReason}
              onChange={(e) => setDiscardReason(e.target.value)}
              className={`${fieldClass} resize-none`}
              placeholder={t('projects.orphan.discard_reason_placeholder', 'Escriu el motiu, o tria una resposta ràpida')}
            />
          </div>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => setDiscardOpen(false)}>
              {t('common:cancel', 'Cancel·lar')}
            </Button>
            <Button type="button" disabled={busy} onClick={() => void discard()}>
              {t('projects.orphan.discard_confirm', 'Deixar com a anul·lat')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      <ApplyPricingTemplateDialog projectId="" open={templateOpen} onClose={() => setTemplateOpen(false)} onApplied={onChanged} onApplyLines={(rows) => writeRows(rows, 'append')} />
      <ApplyCalculatorDialog
        documentId={documentId}
        open={calculatorOpen}
        onClose={() => setCalculatorOpen(false)}
        onApplied={onChanged}
      />
      <CopyFromJobDialog clientId={clientId} currentLineCount={lines.length} open={copyOpen} onClose={() => setCopyOpen(false)} onCopied={onChanged} onCopySource={copyFromProject} />
      <PriceSheetAiComposer projectId="" currentLineCount={lines.length} open={aiOpen} onClose={() => setAiOpen(false)} onApplied={onChanged} onApplyLines={applyAiLines} />
    </section>
  )
}

