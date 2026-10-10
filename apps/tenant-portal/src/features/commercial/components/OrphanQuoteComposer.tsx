import { useEffect, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Plus, Trash2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useEffectiveSettings } from '@/hooks/useSettings'
import { getCatalogItems, type CatalogItem } from '@/features/catalog/api/catalogService'
import { unitSelectOptions } from '@/features/catalog/unitOptions'
import { useDocumentTemplates } from '@/features/signing/api/useDocumentTemplates'
import { formatMoney, type CommercialDocumentLine } from '../utils/commercialDocumentModel'
import {
  deleteCommercialDocumentLine,
  issueOrphanCommercialDocument,
  cancelOrphanQuoteDraft,
  setCommercialDocumentTitle,
  upsertCommercialDocumentLine,
} from '../api/commercialFlowService'
import { commercialErrorMessage } from '../utils/commercialErrorMessage'
import {
  parseFormalizationModeDefault,
  type FormalizationMode,
} from '../utils/deviationApprovalThreshold'
import { OrphanCommercialGuide } from './OrphanCommercialGuide'
import { QuoteFormalizationFields } from './QuoteFormalizationFields'

const TAX_RATE_OPTIONS = [0, 4, 10, 21] as const
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

type Props = {
  documentId: string
  status: string
  projectId: string | null
  lines: CommercialDocumentLine[]
  title?: string | null
  formalizationMode?: string | null
  hasAgreement?: boolean
  onChanged: () => void
}

export function OrphanQuoteComposer({
  documentId,
  status,
  projectId,
  lines,
  title,
  formalizationMode,
  hasAgreement = false,
  onChanged,
}: Props) {
  const { t } = useTranslation(['projects', 'common'])
  const { toast } = useToast()
  const { activeTenant } = useTenant()
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
  const [templateId, setTemplateId] = useState('')

  const { data: effective } = useEffectiveSettings(
    { tenantId: activeTenant?.id ?? '' },
    { enabled: !!activeTenant?.id },
  )
  const { data: templates = [] } = useDocumentTemplates(activeTenant?.id)
  const { data: catalogItems = [] } = useQuery<CatalogItem[]>({
    queryKey: ['catalog_items', activeTenant?.id],
    queryFn: () => getCatalogItems(),
    enabled: !!activeTenant?.id,
  })

  const isDraft = status === 'draft' && !projectId
  const isOrphan = !projectId

  const lineGaps = lineFieldGaps({ name, qty, price, unit })
  const addLineBlocked = lineGaps.length > 0

  useEffect(() => {
    setDocTitle(title ?? '')
  }, [title])

  useEffect(() => {
    if (modeTouched) return
    if (formalizationMode === 'signed_quote' || formalizationMode === 'separate_agreement') {
      setMode(formalizationMode)
      return
    }
    setMode(parseFormalizationModeDefault(effective))
  }, [formalizationMode, effective, modeTouched])

  async function saveTitle() {
    const next = docTitle.trim()
    if (next === (title ?? '').trim()) return
    setBusy(true)
    try {
      await setCommercialDocumentTitle({ documentId, title: next })
      onChanged()
    } catch (err) {
      toast({
        variant: 'destructive',
        description: commercialErrorMessage(err, t('common:error', 'Error')),
      })
    } finally {
      setBusy(false)
    }
  }

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
      await cancelOrphanQuoteDraft(documentId)
      toast({ title: t('projects.orphan.discarded', 'Esborrany descartat') })
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

  if (!isOrphan) return null

  return (
    <section className="space-y-3 rounded-xl border border-amber-200/80 bg-amber-50/30 p-4 dark:border-amber-900/40 dark:bg-amber-950/20">
      <OrphanCommercialGuide
        hasClient
        hasLines={lines.length > 0}
        status={status}
        hasProject={!!projectId}
        formalizationMode={formalizationMode}
        hasAgreement={hasAgreement}
      />

      {isDraft ? (
        <>
          <div className="space-y-1">
            <Label htmlFor="orphan-quote-title">
              {t('projects.orphan.title_label', 'Títol')}
            </Label>
            <Input
              id="orphan-quote-title"
              value={docTitle}
              maxLength={120}
              placeholder={t(
                'projects.orphan.title_placeholder',
                'Per exemple: Reforma bany',
              )}
              onChange={(e) => setDocTitle(e.target.value)}
              onBlur={() => void saveTitle()}
            />
            <p className="text-xs text-muted-foreground">
              {t(
                'projects.orphan.title_help',
                'Nom de treball. El número oficial (P-…) s’assigna en emetre.',
              )}
            </p>
          </div>

          <div className="space-y-2">
            <h3 className="text-sm font-medium text-foreground">
              {t('projects.orphan.lines_added', 'Full de preus')}
            </h3>
            {lines.length === 0 ? (
              <div className="flex flex-col items-center justify-center gap-2 rounded-xl border border-dashed border-border py-10">
                <p className="text-sm text-muted-foreground">
                  {t('projects.lines.empty', "No hi ha línies d'imports")}
                </p>
              </div>
            ) : (
              <OrphanPriceSheetTable lines={lines} busy={busy} onRemove={(id) => void removeLine(id)} />
            )}
          </div>

          <fieldset className="max-w-xl space-y-3 rounded-lg border border-dashed border-border bg-muted/30 p-3">
            <legend className="px-1 text-sm font-medium">
              {t('projects.orphan.new_line', 'Línies')}
            </legend>

            <div className="space-y-1">
              <Label htmlFor="orphan-catalog">
                {t('projects.lines.form.catalog_item_label', 'Ítem del catàleg')}
              </Label>
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
                <option value="">
                  {t('projects.lines.form.catalog_item_placeholder', 'Selecciona o escriu per cercar...')}
                </option>
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
                <select
                  id="orphan-kind"
                  className={fieldClass}
                  value={kind}
                  onChange={(e) => setKind(e.target.value === 'product' ? 'product' : 'service')}
                >
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
                    <option key={option} value={option}>
                      {option}
                    </option>
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
                    <option key={rate} value={rate}>
                      {rate}%
                    </option>
                  ))}
                  {!TAX_RATE_OPTIONS.some((rate) => String(rate) === tax) ? (
                    <option value={tax}>{tax}%</option>
                  ) : null}
                </select>
              </div>
            </div>

            <div className="space-y-1">
              <Label htmlFor="orphan-notes">{t('projects.lines.form.notes_label', 'Notes')}</Label>
              <textarea
                id="orphan-notes"
                rows={2}
                value={notes}
                onChange={(e) => setNotes(e.target.value)}
                className={`${fieldClass} resize-none`}
              />
            </div>

            <p className="text-xs text-muted-foreground">
              {t(
                'projects.lines.form.unit_cost_help',
                'El cost unitari només es porta a l’ordre, quan el pressupost s’accepta. No surt al pressupost ni al PDF.',
              )}
            </p>

            <div className="space-y-1">
              <Button
                type="button"
                variant="outline"
                disabled={busy || addLineBlocked}
                aria-describedby={addLineBlocked ? 'orphan-add-line-reason' : undefined}
                onClick={() => void addLine()}
              >
                <Plus className="mr-1.5 h-4 w-4" />
                {t('projects.orphan.add_line', 'Afegir línia')}
              </Button>
              {addLineBlocked ? (
                <p id="orphan-add-line-reason" className="text-sm text-muted-foreground">
                  {t('projects.orphan.add_line_blocked', 'No es pot afegir la línia: falta {{fields}}.', {
                    fields: joinGapLabels(
                      lineGaps.map((gap) => t(`projects.orphan.line_gap_${gap}`, gap)),
                    ),
                  })}
                </p>
              ) : null}
            </div>
          </fieldset>

          <div id="commercial-issue-quote" className="space-y-3">
            <QuoteFormalizationFields
              mode={mode}
              templateId={templateId}
              templates={templates}
              disabled={busy}
              onModeChange={(next) => {
                setModeTouched(true)
                setMode(next)
              }}
              onTemplateChange={setTemplateId}
            />
            <div className="flex flex-wrap gap-2">
              <Button type="button" disabled={busy || lines.length === 0} onClick={() => void issue()}>
                {t('projects.orphan.issue', 'Emetre pressupost')}
              </Button>
              <Button type="button" variant="ghost" disabled={busy} onClick={() => void discard()}>
                {t('projects.orphan.discard', 'Descartar')}
              </Button>
            </div>
          </div>
        </>
      ) : null}
    </section>
  )
}
