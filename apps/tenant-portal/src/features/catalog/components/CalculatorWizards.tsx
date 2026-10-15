import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import type {
  Constant,
  Definition,
  Expr,
  LineDef,
  LookupTable,
  Parameter,
} from '@pimed/price-calculator'
import { KEY_RE, resolveLocale } from '@pimed/price-calculator'

function slugify(raw: string): string {
  return raw
    .trim()
    .toLowerCase()
    .normalize('NFD')
    .replace(/\p{M}/gu, '')
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_|_$/g, '')
    .slice(0, 40)
}

type WizardKind = 'parameter' | 'constant' | 'table' | 'line' | null

type Props = {
  open: WizardKind
  onClose: () => void
  definition: Definition
  onApply: (next: Definition) => void
  /** Quan s’edita un paràmetre existent (només open === 'parameter'). */
  editParameterKey?: string | null
  /** Esborrany proposat per IA per omplir el modal (sense crear encara). */
  draftParameter?: Parameter | null
}

function round3(value: Expr): Expr {
  return { op: 'round', decimals: 3, mode: 'half_away_from_zero', value }
}

function round2(value: Expr): Expr {
  return { op: 'round', decimals: 2, mode: 'half_away_from_zero', value }
}

export function CalculatorWizards({
  open,
  onClose,
  definition,
  onApply,
  editParameterKey = null,
  draftParameter = null,
}: Props) {
  const { t } = useTranslation(['catalog', 'common'])
  const { toast } = useToast()
  const [label, setLabel] = useState('')
  const [key, setKey] = useState('')
  const [paramType, setParamType] = useState<Parameter['type']>('number')
  const [paramUnit, setParamUnit] = useState('')
  const [optionsFrom, setOptionsFrom] = useState('')
  const [constValue, setConstValue] = useState('0')
  const [tableKind, setTableKind] = useState<'exact' | 'tier'>('tier')
  const [boundCol, setBoundCol] = useState('max_km')
  const [matchCol, setMatchCol] = useState('id')
  const [inputParam, setInputParam] = useState(definition.parameters[0]?.key ?? '')
  const [lineTemplate, setLineTemplate] = useState<'fixed' | 'lookup_qty' | 'm2'>('fixed')
  const [lineUnit, setLineUnit] = useState('u')
  const [taxRate, setTaxRate] = useState('21')
  const [promptQtyPrice, setPromptQtyPrice] = useState(false)
  const [qtyParam, setQtyParam] = useState(definition.parameters[0]?.key ?? '')
  const [priceConst, setPriceConst] = useState(definition.constants?.[0]?.key ?? '')
  const [lookupTable, setLookupTable] = useState(definition.tables?.[0]?.key ?? '')
  const [lookupField, setLookupField] = useState('hours')
  const [widthParam, setWidthParam] = useState('width_cm')
  const [heightParam, setHeightParam] = useState('height_cm')
  const [unitsParam, setUnitsParam] = useState('units')
  const [priceField, setPriceField] = useState('eur_m2')
  const [minField, setMinField] = useState('min_m2')
  const editingParam = open === 'parameter' && !!editParameterKey

  function fail(message: string) {
    toast({ variant: 'destructive', description: message })
  }

  function reset() {
    setLabel('')
    setKey('')
    setParamType('number')
    setParamUnit('')
    setOptionsFrom('')
    setConstValue('0')
    setTableKind('tier')
    setBoundCol('max_km')
    setMatchCol('id')
    setLineTemplate('fixed')
    setLineUnit('u')
    setTaxRate('21')
    setPromptQtyPrice(false)
    setMinField('min_m2')
  }

  useEffect(() => {
    if (open !== 'parameter') return
    if (editParameterKey) {
      const existing = definition.parameters.find((p) => p.key === editParameterKey)
      if (!existing) return
      setKey(existing.key)
      setLabel(resolveLocale(existing.label, 'ca') || existing.key)
      setParamType(existing.type)
      setParamUnit(existing.unit ?? '')
      setOptionsFrom(existing.options_from ?? '')
      return
    }
    if (draftParameter) {
      setKey(draftParameter.key)
      setLabel(resolveLocale(draftParameter.label, 'ca') || draftParameter.key)
      setParamType(draftParameter.type)
      setParamUnit(draftParameter.unit ?? '')
      setOptionsFrom(draftParameter.options_from ?? '')
    }
  }, [open, editParameterKey, draftParameter, definition.parameters])

  function close() {
    reset()
    onClose()
  }

  function ensureKey(preferred: string): string | null {
    const k = (preferred || slugify(label) || 'item').replace(/[^a-z0-9_]/g, '_')
    if (!KEY_RE.test(k)) return null
    return k
  }

  function submit() {
    const next = structuredClone(definition)
    next.parameters = next.parameters ?? []
    next.constants = next.constants ?? []
    next.tables = next.tables ?? []
    next.lines = next.lines ?? []

    if (open === 'parameter') {
      const k = ensureKey(key)
      if (!k) {
        fail(t('catalog.calculators.wizard_bad_key', 'Clau tècnica invàlida.'))
        return
      }
      const existingIdx = editingParam
        ? next.parameters.findIndex((p) => p.key === editParameterKey)
        : -1
      if (!editingParam && next.parameters.some((p) => p.key === k)) {
        fail(t('catalog.calculators.wizard_dup_key', 'Ja existeix un element amb aquesta clau.'))
        return
      }
      if (
        editingParam &&
        k !== editParameterKey &&
        next.parameters.some((p) => p.key === k)
      ) {
        fail(t('catalog.calculators.wizard_dup_key', 'Ja existeix un element amb aquesta clau.'))
        return
      }
      const prev = existingIdx >= 0 ? next.parameters[existingIdx] : undefined
      const unit = paramUnit.trim()
      const p: Parameter = {
        ...(prev ?? {}),
        key: k,
        type: paramType,
        required: prev?.required ?? true,
        label: { ca: label || k },
        unit: unit || undefined,
        min:
          paramType === 'number' || paramType === 'integer'
            ? (prev?.min ?? 0)
            : undefined,
      }
      if (!unit) delete p.unit
      if (paramType === 'enum') {
        const tableKey = ensureKey(optionsFrom || `${k}_options`)
        if (!tableKey) {
          fail(t('catalog.calculators.wizard_bad_options', 'Clau de taula d’opcions invàlida.'))
          return
        }
        if (!next.tables.some((tb) => tb.key === tableKey)) {
          next.tables.push({
            key: tableKey,
            lookup: 'exact',
            input: k,
            match_column: 'id',
            rows: [
              { id: 'a', label: { ca: 'Opció A' }, eur: 0 },
              { id: 'b', label: { ca: 'Opció B' }, eur: 0 },
            ],
          })
        }
        p.options_from = tableKey
      } else {
        delete p.options_from
      }
      if (existingIdx >= 0) next.parameters[existingIdx] = p
      else next.parameters.push(p)
    } else if (open === 'constant') {
      const k = ensureKey(key)
      if (!k) {
        fail(t('catalog.calculators.wizard_bad_key', 'Clau tècnica invàlida.'))
        return
      }
      if (next.constants.some((c) => c.key === k)) {
        fail(t('catalog.calculators.wizard_dup_key', 'Ja existeix un element amb aquesta clau.'))
        return
      }
      const n = Number(constValue.replace(',', '.'))
      const c: Constant = {
        key: k,
        type: 'money',
        value: Number.isFinite(n) ? n : null,
        label: { ca: label || k },
      }
      next.constants.push(c)
    } else if (open === 'table') {
      const k = ensureKey(key)
      if (!k) {
        fail(t('catalog.calculators.wizard_bad_key', 'Clau tècnica invàlida.'))
        return
      }
      if (next.tables.some((tb) => tb.key === k)) {
        fail(t('catalog.calculators.wizard_dup_key', 'Ja existeix un element amb aquesta clau.'))
        return
      }
      const input = inputParam || next.parameters[0]?.key
      if (!input) {
        fail(
          t(
            'catalog.calculators.wizard_need_param',
            'Primer afegeix un paràmetre d’entrada.',
          ),
        )
        return
      }
      let table: LookupTable
      if (tableKind === 'tier') {
        const bound = boundCol || 'max_x'
        table = {
          key: k,
          lookup: 'tier',
          input,
          bound_column: bound,
          column_help: {
            [bound]: {
              ca: 'Límit superior del tram (buit a l’última fila = sense límit)',
            },
            eur_base: { ca: 'Import en € d’aquest tram (el llegeixen les línies)' },
          },
          rows: [
            { [bound]: 10, eur_base: 0 },
            { [bound]: null, eur_base: 0 },
          ],
        }
      } else {
        const match = matchCol.trim() || 'id'
        table = {
          key: k,
          lookup: 'exact',
          input,
          match_column: match,
          column_help: {
            [match]: {
              ca: 'Valor que ha de coincidir amb el paràmetre d’entrada',
            },
            eur: { ca: 'Import en € d’aquesta opció (el llegeixen les línies)' },
          },
          rows: [
            { [match]: 'a', label: { ca: 'Opció A' }, eur: 0 },
            { [match]: 'b', label: { ca: 'Opció B' }, eur: 0 },
          ],
        }
      }
      next.tables.push(table)
    } else if (open === 'line') {
      const k = ensureKey(key)
      if (!k) {
        fail(t('catalog.calculators.wizard_bad_key', 'Clau tècnica invàlida.'))
        return
      }
      if (next.lines.some((l) => l.key === k)) {
        fail(t('catalog.calculators.wizard_dup_key', 'Ja existeix un element amb aquesta clau.'))
        return
      }
      const tax = Number(taxRate.replace(',', '.'))
      const taxExpr: Expr = {
        op: 'const',
        value: Number.isFinite(tax) ? tax : 21,
      }
      let line: LineDef
      if (lineTemplate === 'fixed') {
        const qty = round3(
          qtyParam && next.parameters.some((p) => p.key === qtyParam)
            ? { op: 'param', key: qtyParam }
            : { op: 'const', value: 1 },
        )
        const price = round2(
          priceConst && next.constants.some((c) => c.key === priceConst)
            ? { op: 'const_ref', key: priceConst }
            : { op: 'const', value: 0 },
        )
        line = {
          key: k,
          name: { ca: label || k },
          kind: 'service',
          unit: lineUnit || 'u',
          quantity: qty,
          unit_price: price,
          discount_pct: { op: 'const', value: 0 },
          tax_rate: taxExpr,
          prompt_qty_price: promptQtyPrice || undefined,
        }
      } else if (lineTemplate === 'lookup_qty') {
        const tableKey = lookupTable || next.tables[0]?.key
        if (!tableKey) {
          fail(t('catalog.calculators.wizard_need_table', 'Primer afegeix una taula.'))
          return
        }
        const tableMeta = next.tables.find((tb) => tb.key === tableKey)
        const field = lookupField || 'hours'
        const qtyValue: Expr =
          tableMeta?.lookup === 'exact'
            ? { op: 'lookup_exact', table: tableKey, field }
            : {
                op: 'lookup_tier',
                table: tableKey,
                value: { op: 'row', field },
              }
        line = {
          key: k,
          name: { ca: label || k },
          kind: 'service',
          unit: lineUnit || 'h',
          quantity: round3(qtyValue),
          unit_price: round2(
            priceConst && next.constants.some((c) => c.key === priceConst)
              ? { op: 'const_ref', key: priceConst }
              : { op: 'const', value: 0 },
          ),
          discount_pct: { op: 'const', value: 0 },
          tax_rate: taxExpr,
          prompt_qty_price: promptQtyPrice || undefined,
        }
      } else {
        const tableKey = lookupTable || next.tables[0]?.key
        if (!tableKey) {
          fail(t('catalog.calculators.wizard_need_table', 'Primer afegeix una taula.'))
          return
        }
        const w = widthParam || 'width_cm'
        const h = heightParam || 'height_cm'
        const u = unitsParam || 'units'
        const minF = minField || 'min_m2'
        const priceF = priceField || 'eur_m2'
        for (const needed of [w, h, u]) {
          if (!next.parameters.some((p) => p.key === needed)) {
            fail(
              t(
                'catalog.calculators.wizard_m2_params',
                'Calen els paràmetres {{list}} (o canvia’n els noms al formulari).',
                { list: `${w}, ${h}, ${u}` },
              ),
            )
            return
          }
        }
        line = {
          key: k,
          name: { ca: label || k },
          kind: 'product',
          unit: 'm2',
          quantity: round3({
            op: 'mul',
            args: [
              { op: 'param', key: u },
              {
                op: 'max',
                args: [
                  { op: 'lookup_exact', table: tableKey, field: minF },
                  {
                    op: 'div',
                    left: {
                      op: 'mul',
                      args: [
                        { op: 'param', key: w },
                        { op: 'param', key: h },
                      ],
                    },
                    right: { op: 'const', value: 10000 },
                  },
                ],
              },
            ],
          }),
          unit_price: round2({
            op: 'lookup_exact',
            table: tableKey,
            field: priceF,
          }),
          discount_pct: { op: 'const', value: 0 },
          tax_rate: taxExpr,
          prompt_qty_price: promptQtyPrice || undefined,
        }
      }
      next.lines.push(line)
    }

    onApply(next)
    close()
  }

  const title =
    open === 'parameter'
      ? editingParam
        ? t('catalog.calculators.wizard_param_edit', 'Editar paràmetre')
        : t('catalog.calculators.wizard_param', 'Afegir paràmetre')
      : open === 'constant'
        ? t('catalog.calculators.wizard_const', 'Afegir tarifa / constant')
        : open === 'table'
          ? t('catalog.calculators.wizard_table', 'Afegir taula')
          : open === 'line'
            ? t('catalog.calculators.wizard_line', 'Afegir línia')
            : ''

  return (
    <Dialog open={!!open} onOpenChange={(v) => !v && close()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
        </DialogHeader>
        <div className="space-y-3 py-2">
          <div className="space-y-1">
            <Label>{t('catalog.calculators.wizard_label', 'Etiqueta')}</Label>
            <Input
              value={label}
              onChange={(e) => {
                setLabel(e.target.value)
                if (!key) setKey(slugify(e.target.value))
              }}
            />
          </div>
          <div className="space-y-1">
            <Label>{t('catalog.calculators.wizard_key', 'Clau tècnica')}</Label>
            <Input value={key} onChange={(e) => setKey(slugify(e.target.value))} />
          </div>

          {open === 'parameter' ? (
            <>
              <div className="space-y-1">
                <Label>{t('catalog.calculators.wizard_type', 'Tipus')}</Label>
                <select
                  className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                  value={paramType}
                  onChange={(e) => setParamType(e.target.value as Parameter['type'])}
                >
                  <option value="number">number</option>
                  <option value="integer">integer</option>
                  <option value="boolean">boolean</option>
                  <option value="enum">enum</option>
                </select>
              </div>
              {paramType === 'number' || paramType === 'integer' || paramType === 'money' ? (
                <div className="space-y-1">
                  <Label>{t('catalog.calculators.wizard_param_unit', 'Unitat')}</Label>
                  <Input
                    value={paramUnit}
                    onChange={(e) => setParamUnit(e.target.value)}
                    placeholder={t(
                      'catalog.calculators.wizard_param_unit_ph',
                      'p. ex. km, m, kW, W, h, u…',
                    )}
                    list="calculator-param-unit-suggestions"
                  />
                  <datalist id="calculator-param-unit-suggestions">
                    <option value="km" />
                    <option value="m" />
                    <option value="kW" />
                    <option value="W" />
                    <option value="h" />
                    <option value="min" />
                    <option value="u" />
                    <option value="m²" />
                    <option value="kg" />
                  </datalist>
                  <p className="text-xs text-muted-foreground">
                    {t(
                      'catalog.calculators.wizard_param_unit_help',
                      'Es mostra a la previsualització perquè quedi clar (km vs m, kW vs W).',
                    )}
                  </p>
                </div>
              ) : null}
              {paramType === 'enum' ? (
                <div className="space-y-1">
                  <Label>
                    {t(
                      'catalog.calculators.wizard_options_from',
                      'Taula d’opcions (es crea si no existeix)',
                    )}
                  </Label>
                  <Input
                    value={optionsFrom}
                    onChange={(e) => setOptionsFrom(slugify(e.target.value))}
                    placeholder={key ? `${key}_options` : 'opcions'}
                  />
                </div>
              ) : null}
            </>
          ) : null}

          {open === 'constant' ? (
            <div className="space-y-1">
              <Label>{t('catalog.calculators.wizard_value', 'Valor (€)')}</Label>
              <Input
                type="number"
                step="0.01"
                value={constValue}
                onChange={(e) => setConstValue(e.target.value)}
              />
            </div>
          ) : null}

          {open === 'table' ? (
            <>
              <p className="text-xs text-muted-foreground">
                {t(
                  'catalog.calculators.wizard_table_help',
                  'La taula tria una fila segons el paràmetre. Després, a les línies, decides quin camp de aquella fila usar (qty o preu).',
                )}
              </p>
              <div className="space-y-1">
                <Label>
                  {t('catalog.calculators.wizard_table_kind', 'Com es busca la fila?')}
                </Label>
                <select
                  className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                  value={tableKind}
                  onChange={(e) => setTableKind(e.target.value as 'exact' | 'tier')}
                >
                  <option value="tier">
                    {t(
                      'catalog.calculators.wizard_tier',
                      'Per trams (nombre ≤ límit superior)',
                    )}
                  </option>
                  <option value="exact">
                    {t(
                      'catalog.calculators.wizard_exact',
                      'Per valor exacte (llista / enum)',
                    )}
                  </option>
                </select>
              </div>
              <div className="space-y-1">
                <Label>
                  {t(
                    'catalog.calculators.wizard_input_param',
                    'Paràmetre que determina la fila',
                  )}
                </Label>
                <select
                  className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                  value={inputParam}
                  onChange={(e) => setInputParam(e.target.value)}
                >
                  {definition.parameters.length === 0 ? (
                    <option value="">
                      {t('catalog.calculators.wizard_no_params', 'Sense paràmetres')}
                    </option>
                  ) : null}
                  {definition.parameters.map((p) => {
                    const label = resolveLocale(p.label, 'ca') || p.key
                    return (
                      <option key={p.key} value={p.key}>
                        {label === p.key ? p.key : `${label} (${p.key})`}
                      </option>
                    )
                  })}
                </select>
              </div>
              {tableKind === 'tier' ? (
                <div className="space-y-1">
                  <Label>
                    {t(
                      'catalog.calculators.wizard_bound',
                      'Nom de la columna de límit (bound_column)',
                    )}
                  </Label>
                  <Input
                    value={boundCol}
                    onChange={(e) => setBoundCol(e.target.value)}
                    placeholder="max_km"
                  />
                  <p className="text-xs text-muted-foreground">
                    {t(
                      'catalog.calculators.wizard_bound_help',
                      'Cada fila té un límit superior (p. ex. max_km). Es tria la primera fila amb paràmetre ≤ límit. L’última fila amb límit buit = sense límit. Això NO és el preu: el valor (eur_base, hours…) va a columnes de dades i es llegeix des de la línia.',
                    )}
                  </p>
                </div>
              ) : (
                <div className="space-y-1">
                  <Label>
                    {t(
                      'catalog.calculators.wizard_match',
                      'Nom de la columna de coincidència (match_column)',
                    )}
                  </Label>
                  <Input
                    value={matchCol}
                    onChange={(e) => setMatchCol(e.target.value)}
                    placeholder="id"
                  />
                  <p className="text-xs text-muted-foreground">
                    {t(
                      'catalog.calculators.wizard_match_help',
                      'Es compara el paràmetre amb el valor d’aquesta columna (p. ex. id = «a»). Les altres columnes (eur, hours…) són dades que llegiràs des de la línia.',
                    )}
                  </p>
                </div>
              )}
            </>
          ) : null}

          {open === 'line' ? (
            <>
              <div className="space-y-1">
                <Label>{t('catalog.calculators.wizard_line_tpl', 'Plantilla')}</Label>
                <select
                  className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                  value={lineTemplate}
                  onChange={(e) =>
                    setLineTemplate(e.target.value as 'fixed' | 'lookup_qty' | 'm2')
                  }
                >
                  <option value="fixed">
                    {t('catalog.calculators.tpl_fixed', 'Preu fix / qty param')}
                  </option>
                  <option value="lookup_qty">
                    {t('catalog.calculators.tpl_lookup', 'Qty des de taula + preu constant')}
                  </option>
                  <option value="m2">
                    {t('catalog.calculators.tpl_m2', 'Producte m² (ample × alt)')}
                  </option>
                </select>
                <p className="text-xs text-muted-foreground">
                  {lineTemplate === 'fixed'
                    ? t(
                        'catalog.calculators.tpl_fixed_help',
                        'Línia simple: quantitat = un paràmetre (o 1 si el deixes buit) × preu d’una constant (€/h, €/u…). Útil per materials, hores manuals o un import fix. No consulta taules.',
                      )
                    : lineTemplate === 'lookup_qty'
                      ? t(
                          'catalog.calculators.tpl_lookup_help',
                          'La quantitat surt d’una columna de la taula (p. ex. hores segons kW) i el preu d’una constant (€/hora). La taula ja tria la fila amb el seu paràmetre d’entrada; aquí només dius quina columna llegir. Tipus: mà d’obra per trams.',
                        )
                      : t(
                          'catalog.calculators.tpl_m2_help',
                          'Producte per superfície: combina amplada × alçada (÷ 10 000 → m²), aplica un mínim de la taula i multiplica per unitats. El preu €/m² ve de la taula de models. Tipus: persianes, vidres, panells.',
                        )}
                </p>
              </div>
              <div className="grid grid-cols-2 gap-2">
                <div className="space-y-1">
                  <Label>{t('catalog.calculators.wizard_unit', 'Unitat')}</Label>
                  <Input value={lineUnit} onChange={(e) => setLineUnit(e.target.value)} />
                </div>
                <div className="space-y-1">
                  <Label>IVA %</Label>
                  <Input value={taxRate} onChange={(e) => setTaxRate(e.target.value)} />
                </div>
              </div>
              <label className="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={promptQtyPrice}
                  onChange={(e) => setPromptQtyPrice(e.target.checked)}
                />
                {t(
                  'catalog.calculators.prompt_qty_price',
                  'Demanar quantitat i preu',
                )}
              </label>
              {lineTemplate === 'fixed' ? (
                <>
                  <div className="space-y-1">
                    <Label>{t('catalog.calculators.wizard_qty_param', 'Qty (param, buit=1)')}</Label>
                    <select
                      className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                      value={qtyParam}
                      onChange={(e) => setQtyParam(e.target.value)}
                    >
                      <option value="">1</option>
                      {definition.parameters.map((p) => {
                        const label = resolveLocale(p.label, 'ca') || p.key
                        return (
                          <option key={p.key} value={p.key}>
                            {label === p.key ? p.key : `${label} (${p.key})`}
                          </option>
                        )
                      })}
                    </select>
                  </div>
                  <div className="space-y-1">
                    <Label>{t('catalog.calculators.wizard_price_const', 'Preu (constant)')}</Label>
                    <select
                      className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                      value={priceConst}
                      onChange={(e) => setPriceConst(e.target.value)}
                    >
                      <option value="">0</option>
                      {(definition.constants ?? []).map((c) => (
                        <option key={c.key} value={c.key}>
                          {c.key}
                        </option>
                      ))}
                    </select>
                  </div>
                </>
              ) : null}
              {lineTemplate === 'lookup_qty' ? (
                <>
                  <div className="space-y-1">
                    <Label>Taula</Label>
                    <select
                      className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                      value={lookupTable}
                      onChange={(e) => setLookupTable(e.target.value)}
                    >
                      {(definition.tables ?? []).map((tb) => (
                        <option key={tb.key} value={tb.key}>
                          {tb.key} ({tb.lookup})
                        </option>
                      ))}
                    </select>
                  </div>
                  <div className="space-y-1">
                    <Label>
                      {t(
                        'catalog.calculators.wizard_lookup_field',
                        'Columna de la taula → quantitat',
                      )}
                    </Label>
                    <Input
                      value={lookupField}
                      onChange={(e) => setLookupField(e.target.value)}
                      placeholder="hours"
                    />
                    <p className="text-xs text-muted-foreground">
                      {t(
                        'catalog.calculators.wizard_lookup_field_help',
                        'Nom d’una columna de dades de la taula (p. ex. hours, eur_base). No és la columna de límit/cerca.',
                      )}
                    </p>
                  </div>
                  <div className="space-y-1">
                    <Label>Preu (constant)</Label>
                    <select
                      className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                      value={priceConst}
                      onChange={(e) => setPriceConst(e.target.value)}
                    >
                      <option value="">0</option>
                      {(definition.constants ?? []).map((c) => (
                        <option key={c.key} value={c.key}>
                          {c.key}
                        </option>
                      ))}
                    </select>
                  </div>
                </>
              ) : null}
              {lineTemplate === 'm2' ? (
                <>
                  <div className="space-y-1">
                    <Label>Taula models</Label>
                    <select
                      className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                      value={lookupTable}
                      onChange={(e) => setLookupTable(e.target.value)}
                    >
                      {(definition.tables ?? []).map((tb) => (
                        <option key={tb.key} value={tb.key}>
                          {tb.key}
                        </option>
                      ))}
                    </select>
                  </div>
                  <div className="grid grid-cols-3 gap-2">
                    <div className="space-y-1">
                      <Label>Ample</Label>
                      <Input value={widthParam} onChange={(e) => setWidthParam(e.target.value)} />
                    </div>
                    <div className="space-y-1">
                      <Label>Alt</Label>
                      <Input value={heightParam} onChange={(e) => setHeightParam(e.target.value)} />
                    </div>
                    <div className="space-y-1">
                      <Label>Unitats</Label>
                      <Input value={unitsParam} onChange={(e) => setUnitsParam(e.target.value)} />
                    </div>
                  </div>
                  <div className="grid grid-cols-2 gap-2">
                    <div className="space-y-1">
                      <Label>Camp min m²</Label>
                      <Input value={minField} onChange={(e) => setMinField(e.target.value)} />
                    </div>
                    <div className="space-y-1">
                      <Label>Camp €/m²</Label>
                      <Input value={priceField} onChange={(e) => setPriceField(e.target.value)} />
                    </div>
                  </div>
                </>
              ) : null}
            </>
          ) : null}
        </div>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={close}>
            {t('common:cancel', 'Cancel·lar')}
          </Button>
          <Button type="button" onClick={submit}>
            {editingParam
              ? t('common:save', 'Desar')
              : t('common:add', 'Afegir')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

export type { WizardKind }
