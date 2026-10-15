import { useEffect, useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
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
import { Badge } from '@/components/ui/badge'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import {
  applyCalculatorRun,
  getCalculatorVersion,
  listActiveCalculators,
  previewCalculator,
  type CalculatorDefinitionRow,
} from '../api/calculatorService'
import { commercialErrorMessage } from '../utils/commercialErrorMessage'
import { formatCalcErrorList } from '../utils/calculatorErrorLabels'
import {
  needsQtyPricePrompt,
  resolveLocale,
  type Definition,
  type LineOverrides,
  type ParamValues,
} from '@pimed/price-calculator'

type Props = {
  open: boolean
  onClose: () => void
  onApplied: () => void
  projectId?: string | null
  documentId?: string | null
  /** Preselecció (p. ex. tornar a calcular). */
  initialDefinitionId?: string | null
  initialParams?: ParamValues | null
}

function defaultParams(definition: Definition): ParamValues {
  const out: ParamValues = {}
  for (const p of definition.parameters ?? []) {
    if (p.default !== undefined && p.default !== null) out[p.key] = p.default
    else if (p.type === 'boolean') out[p.key] = false
    else if (p.type === 'enum') out[p.key] = ''
    else out[p.key] = p.min ?? 0
  }
  return out
}

function enumOptions(definition: Definition, optionsFrom: string | undefined): string[] {
  if (!optionsFrom) return []
  const table = definition.tables?.find((t) => t.key === optionsFrom)
  if (!table) return []
  return table.rows
    .map((r) => (typeof r.id === 'string' ? r.id : null))
    .filter((x): x is string => Boolean(x))
}

export function ApplyCalculatorDialog({
  open,
  onClose,
  onApplied,
  projectId = null,
  documentId = null,
  initialDefinitionId = null,
  initialParams = null,
}: Props) {
  const { t } = useTranslation(['projects', 'common'])
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const [tagFilter, setTagFilter] = useState<string | null>(null)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [params, setParams] = useState<ParamValues>({})
  const [lineOverrides, setLineOverrides] = useState<LineOverrides>({})
  const [busy, setBusy] = useState(false)

  const { data: calculators = [], isLoading } = useQuery({
    queryKey: ['calculator_definitions_active', activeTenant?.id],
    queryFn: listActiveCalculators,
    enabled: open && !!activeTenant,
  })

  const tags = useMemo(() => {
    const set = new Set<string>()
    for (const row of calculators) for (const tag of row.tags ?? []) set.add(tag)
    return [...set].sort((a, b) => a.localeCompare(b, 'ca'))
  }, [calculators])

  const filtered = useMemo(() => {
    if (!tagFilter) return calculators
    return calculators.filter((c) => (c.tags ?? []).includes(tagFilter))
  }, [calculators, tagFilter])

  const selected: CalculatorDefinitionRow | null =
    filtered.find((c) => c.id === selectedId) ??
    calculators.find((c) => c.id === selectedId) ??
    null

  const publishedDefinition = useQuery({
    queryKey: ['calculator_version', selected?.published_version_id],
    queryFn: () => getCalculatorVersion(selected!.published_version_id!),
    enabled: open && !!selected?.published_version_id,
  })

  // Actives: draft === publicada. Fallback evita UI bloquejada si la versió triga o falla.
  const definition =
    publishedDefinition.data?.definition ??
    (selected?.published_version_id ? selected.draft_definition : null)

  useEffect(() => {
    if (!open) {
      setSelectedId(null)
      setParams({})
      setLineOverrides({})
      setTagFilter(null)
      setBusy(false)
      return
    }
    if (initialDefinitionId) setSelectedId(initialDefinitionId)
  }, [open, initialDefinitionId])

  useEffect(() => {
    if (!definition) return
    setParams(initialParams ?? defaultParams(definition))
    setLineOverrides({})
  }, [definition, initialParams])

  const preview = useMemo(() => {
    if (!definition) return null
    return previewCalculator(definition, params, 'ca', lineOverrides)
  }, [definition, params, lineOverrides])

  const promptLines = useMemo(
    () => (definition?.lines ?? []).filter((l) => needsQtyPricePrompt(l)),
    [definition],
  )

  async function handleApply() {
    if (!selected?.published_version_id || !definition || busy) return
    if (!projectId && !documentId) return
    if (preview?.errors.length) {
      toast({
        variant: 'destructive',
        description: formatCalcErrorList(definition, preview.errors, 'ca'),
      })
      return
    }
    setBusy(true)
    try {
      await applyCalculatorRun({
        versionId: selected.published_version_id,
        params,
        projectId,
        documentId,
        clientOpId: crypto.randomUUID(),
        definition,
        lineOverrides,
      })
      toast({ title: t('projects.lines.calculator_applied', 'Calculadora aplicada') })
      onApplied()
      onClose()
    } catch (err) {
      const msg = commercialErrorMessage(err, t('common:error', 'Error'))
      toast({
        variant: 'destructive',
        description:
          msg.includes('calculator_parity_mismatch')
            ? t(
                'projects.lines.calculator_parity',
                'La previsualització no coincideix amb el servidor. No s’han escrit línies.',
              )
            : msg,
      })
    } finally {
      setBusy(false)
    }
  }

  return (
    <Dialog open={open} onOpenChange={(next) => !busy && !next && onClose()}>
      <DialogContent className="flex max-h-[90vh] max-w-lg flex-col gap-0 overflow-hidden p-0">
        <div className="shrink-0 space-y-2 border-b border-border px-6 pb-4 pt-6 pr-12">
          <DialogHeader>
            <DialogTitle>
              {t('projects.lines.calculator_title', 'Calculadora')}
            </DialogTitle>
            <DialogDescription>
              {t(
                'projects.lines.calculator_help',
                'Tria una calculadora activa, omple els paràmetres i confirma.',
              )}
            </DialogDescription>
          </DialogHeader>
        </div>

        <div className="min-h-0 flex-1 space-y-4 overflow-y-auto px-6 py-4">
          {isLoading ? (
            <p className="text-sm text-muted-foreground">{t('common:loading', 'Carregant…')}</p>
          ) : calculators.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {t(
                'projects.lines.calculator_empty',
                'No hi ha cap calculadora activa. Activa’n una a Catàleg → Calculadores.',
              )}
            </p>
          ) : (
            <>
              {tags.length > 0 ? (
                <div className="flex flex-wrap gap-1.5">
                  <Button
                    type="button"
                    size="sm"
                    variant={tagFilter == null ? 'secondary' : 'outline'}
                    onClick={() => setTagFilter(null)}
                  >
                    {t('projects.lines.calculator_all_tags', 'Tots')}
                  </Button>
                  {tags.map((tag) => (
                    <Button
                      key={tag}
                      type="button"
                      size="sm"
                      variant={tagFilter === tag ? 'secondary' : 'outline'}
                      onClick={() => setTagFilter(tag)}
                    >
                      {tag}
                    </Button>
                  ))}
                </div>
              ) : null}

              <div className="space-y-1">
                <Label htmlFor="calc-pick">
                  {t('projects.lines.calculator_pick', 'Calculadora')}
                </Label>
                <select
                  id="calc-pick"
                  className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                  value={selectedId ?? ''}
                  disabled={busy}
                  onChange={(e) => setSelectedId(e.target.value || null)}
                >
                  <option value="">
                    {t('projects.lines.calculator_pick_ph', 'Tria…')}
                  </option>
                  {filtered.map((c) => (
                    <option key={c.id} value={c.id}>
                      {c.name}
                    </option>
                  ))}
                </select>
              </div>

              {selected && !(selected.tags ?? []).length ? null : selected ? (
                <div className="flex flex-wrap gap-1">
                  {(selected.tags ?? []).map((tag) => (
                    <Badge key={tag} variant="secondary">
                      {tag}
                    </Badge>
                  ))}
                </div>
              ) : null}

              {selected && !selected.published_version_id ? (
                <p className="text-sm text-destructive" role="alert">
                  {t(
                    'projects.lines.calculator_not_published',
                    'Aquesta calculadora no té versió publicada. Torna a Catàleg, publica i activa.',
                  )}
                </p>
              ) : null}
              {selected && publishedDefinition.isError ? (
                <p className="text-sm text-amber-800 dark:text-amber-200" role="status">
                  {t(
                    'projects.lines.calculator_version_fallback',
                    'No s’ha pogut carregar la versió publicada; s’usa l’esborrany actiu.',
                  )}
                </p>
              ) : null}
              {selected && publishedDefinition.isLoading ? (
                <p className="text-sm text-muted-foreground">
                  {t('common:loading', 'Carregant…')}
                </p>
              ) : null}

              {definition ? (
                <div className="grid gap-3 sm:grid-cols-2">
                  {definition.parameters.map((p) => (
                    <div key={p.key} className="space-y-1">
                      <Label htmlFor={`calc-p-${p.key}`}>
                        {resolveLocale(p.label, 'ca') || p.key}
                      </Label>
                      {p.type === 'boolean' ? (
                        <select
                          id={`calc-p-${p.key}`}
                          className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                          value={String(Boolean(params[p.key]))}
                          disabled={busy}
                          onChange={(e) =>
                            setParams((prev) => ({
                              ...prev,
                              [p.key]: e.target.value === 'true',
                            }))
                          }
                        >
                          <option value="false">false</option>
                          <option value="true">true</option>
                        </select>
                      ) : p.type === 'enum' ? (
                        <select
                          id={`calc-p-${p.key}`}
                          className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                          value={String(params[p.key] ?? '')}
                          disabled={busy}
                          onChange={(e) =>
                            setParams((prev) => ({ ...prev, [p.key]: e.target.value }))
                          }
                        >
                          <option value="">—</option>
                          {enumOptions(definition, p.options_from).map((opt) => (
                            <option key={opt} value={opt}>
                              {opt}
                            </option>
                          ))}
                        </select>
                      ) : (
                        <Input
                          id={`calc-p-${p.key}`}
                          type="number"
                          step={p.type === 'integer' ? '1' : '0.01'}
                          disabled={busy}
                          value={params[p.key] == null ? '' : String(params[p.key])}
                          onChange={(e) => {
                            const n = Number(e.target.value.replace(',', '.'))
                            setParams((prev) => ({
                              ...prev,
                              [p.key]: Number.isFinite(n) ? n : 0,
                            }))
                          }}
                        />
                      )}
                    </div>
                  ))}
                </div>
              ) : null}

              {definition && promptLines.length > 0 ? (
                <div className="space-y-2 rounded-lg border border-dashed border-border p-3">
                  <p className="text-sm font-medium">
                    {t(
                      'projects.lines.calculator_prompt_qty_price',
                      'Quantitat i preu unitari',
                    )}
                  </p>
                  {promptLines.map((line) => {
                    const fromRun = preview?.lines.find((l) => l.key === line.key)
                    const ov = lineOverrides[line.key]
                    return (
                      <div key={line.key} className="grid grid-cols-2 gap-2">
                        <p className="col-span-2 text-xs font-medium">
                          {resolveLocale(line.name, 'ca') || line.key}
                        </p>
                        <div className="space-y-1">
                          <Label className="text-xs">
                            {t('projects.lines.form.quantity_label', 'Quantitat')}
                          </Label>
                          <Input
                            type="number"
                            step="0.001"
                            disabled={busy}
                            value={ov?.quantity ?? fromRun?.quantity ?? ''}
                            onChange={(e) =>
                              setLineOverrides((prev) => ({
                                ...prev,
                                [line.key]: {
                                  ...prev[line.key],
                                  quantity: e.target.value,
                                },
                              }))
                            }
                          />
                        </div>
                        <div className="space-y-1">
                          <Label className="text-xs">
                            {t('projects.lines.form.unit_price_label', 'Preu unitari')}
                          </Label>
                          <Input
                            type="number"
                            step="0.01"
                            disabled={busy}
                            value={ov?.unit_price ?? fromRun?.unit_price ?? ''}
                            onChange={(e) =>
                              setLineOverrides((prev) => ({
                                ...prev,
                                [line.key]: {
                                  ...prev[line.key],
                                  unit_price: e.target.value,
                                },
                              }))
                            }
                          />
                        </div>
                      </div>
                    )
                  })}
                </div>
              ) : null}

              {preview?.errors.length ? (
                <p className="text-sm text-destructive" role="alert">
                  {definition
                    ? formatCalcErrorList(definition, preview.errors, 'ca')
                    : preview.errors.map((e) => e.code).join('; ')}
                </p>
              ) : preview?.lines.length ? (
                <div className="space-y-1 rounded-lg border border-border p-3 text-sm">
                  {preview.lines.map((line) => (
                    <div key={line.key} className="flex justify-between gap-2">
                      <span>
                        {line.name} × {line.quantity}
                      </span>
                      <span>{line.unit_price} €</span>
                    </div>
                  ))}
                  {preview.totals ? (
                    <p className="pt-2 font-medium">
                      {t('projects.lines.calculator_total', 'Total')}: {preview.totals.total} €
                    </p>
                  ) : null}
                </div>
              ) : null}
            </>
          )}
        </div>

        <DialogFooter className="shrink-0 border-t border-border px-6 py-4">
          <Button type="button" variant="outline" disabled={busy} onClick={onClose}>
            {t('common:cancel', 'Cancel·lar')}
          </Button>
          <Button
            type="button"
            disabled={
              busy ||
              !selected?.published_version_id ||
              !definition ||
              !!preview?.errors.length ||
              calculators.length === 0
            }
            onClick={() => void handleApply()}
          >
            {t('projects.lines.calculator_confirm', 'Aplicar')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
