import { useEffect, useMemo, useState } from 'react'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { ArrowLeft, Trash2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { Badge } from '@/components/ui/badge'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { AIGenerateAction } from '@/features/ai/components/AIGenerateAction'
import {
  applyCalculatorPatches,
  demoteUnconfirmedTariffNumbers,
  parseAiCalculatorDefinition,
  parseAiCalculatorPatches,
  type CalculatorPatch,
} from '@/features/commercial/utils/calculatorAi'
import {
  activateClonedCalculator,
  canActivateCalculator,
  checkCalculatorCase,
  getCalculatorDefinition,
  listCalculatorCases,
  listCalculatorCatalog,
  listTenantCalculatorTags,
  markCalculatorTariffsReviewed,
  previewCalculator,
  publishCalculatorVersion,
  saveCalculatorDraft,
  setCalculatorStatus,
  deleteCalculatorDefinition,
  deleteCalculatorCase,
  upsertCalculatorCase,
  type CalculatorCaseRow,
} from '@/features/commercial/api/calculatorService'
import { readWhenMode, writeWhenMode, type WhenMode } from '@/features/commercial/utils/calculatorWhenMode'
import { formatActivationGapList } from '@/features/commercial/utils/calculatorGapLabels'
import { formatCalcErrorList } from '@/features/commercial/utils/calculatorErrorLabels'
import {
  parseAiCalculatorFragment,
  parseAiParameterProposal,
  type CalculatorFragmentKind,
} from '@/features/commercial/utils/calculatorAi'
import type {
  Constant,
  Definition,
  Expr,
  LineDef,
  LineOverrides,
  Parameter,
  ParamValues,
} from '@pimed/price-calculator'
import {
  needsQtyPricePrompt,
  resolveLocale,
  validateDefinition,
} from '@pimed/price-calculator'
import {
  CalculatorExprBuilder,
  defaultBlankLineExpr,
} from './CalculatorExprBuilder'
import { CalculatorWizards, type WizardKind } from './CalculatorWizards'
import { CalculatorPreviewSheet } from './CalculatorPreviewSheet'

/** Tipus d’IVA comuns (hardcode temporal; pla futur: BD + admin). */
const TAX_RATE_OPTIONS = [0, 4, 10, 21] as const

function unwrapConstNumber(expr: Expr): number | null {
  let cur: Expr = expr
  while (cur.op === 'round') cur = cur.value
  if (cur.op === 'const' && typeof cur.value === 'number') return cur.value
  return null
}

function isSimpleConstExpr(expr: Expr): boolean {
  return unwrapConstNumber(expr) != null
}

function constExpr(n: number): Expr {
  return { op: 'const', value: n }
}

function cloneDef(def: Definition): Definition {
  return structuredClone(def)
}

export function CalculatorEditorPage() {
  const { id } = useParams<{ id: string }>()
  const [searchParams, setSearchParams] = useSearchParams()
  const { t } = useTranslation(['catalog', 'common'])
  const { activeTenant, activeRole } = useTenant()
  const { toast } = useToast()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const canEdit = activeRole === 'owner' || activeRole === 'manager'
  const archetype = activeTenant?.archetype ?? 'generic'

  const { data: row, isLoading } = useQuery({
    queryKey: ['calculator_definition', id, activeTenant?.id],
    queryFn: () => getCalculatorDefinition(id!),
    enabled: !!id && !!activeTenant,
  })

  const { data: cases = [], refetch: refetchCases } = useQuery({
    queryKey: ['calculator_cases', id, activeTenant?.id],
    queryFn: () => listCalculatorCases(id!),
    enabled: !!id && !!activeTenant,
  })

  const { data: knownTags = [] } = useQuery({
    queryKey: ['calculator_tags', activeTenant?.id],
    queryFn: listTenantCalculatorTags,
    enabled: !!activeTenant,
  })

  const { data: catalog = [] } = useQuery({
    queryKey: ['calculator_catalog', activeTenant?.id, archetype],
    queryFn: () => listCalculatorCatalog(archetype),
    enabled: !!activeTenant && canEdit && !!row?.cloned_from_catalog_id,
  })

  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [tagsText, setTagsText] = useState('')
  const [def, setDef] = useState<Definition | null>(null)
  const [previewParams, setPreviewParams] = useState<ParamValues>({})
  const [lineOverrides, setLineOverrides] = useState<LineOverrides>({})
  const [busy, setBusy] = useState(false)
  const [caseName, setCaseName] = useState('Escenari 1')
  const [editingCaseId, setEditingCaseId] = useState<string | null>(null)
  const [pendingDeleteCase, setPendingDeleteCase] = useState<CalculatorCaseRow | null>(null)
  const [aiPrompt, setAiPrompt] = useState('')
  const [pendingPatches, setPendingPatches] = useState<
    Array<CalculatorPatch & { accepted: boolean }>
  >([])
  const [wizard, setWizard] = useState<WizardKind>(null)
  const [editParameterKey, setEditParameterKey] = useState<string | null>(null)
  const [draftParameter, setDraftParameter] = useState<Parameter | null>(null)
  const [addColumnForTable, setAddColumnForTable] = useState<string | null>(null)
  const [newColumnName, setNewColumnName] = useState('eur_')
  const [newColumnHelp, setNewColumnHelp] = useState('')
  const [pendingTableDelete, setPendingTableDelete] = useState<
    | { kind: 'table'; key: string }
    | { kind: 'row'; tableKey: string; rowIndex: number }
    | { kind: 'column'; tableKey: string; col: string }
    | null
  >(null)
  const [showHelp, setShowHelp] = useState(false)
  const [showAdvancedExpr, setShowAdvancedExpr] = useState(false)
  const [sectionAiPrompt, setSectionAiPrompt] = useState<
    Record<CalculatorFragmentKind, string>
  >({
    parameter: '',
    constant: '',
    table: '',
    line: '',
  })

  useEffect(() => {
    if (!row) return
    setName(row.name)
    setDescription(row.description ?? '')
    setTagsText((row.tags ?? []).join(', '))
    setDef(cloneDef(row.draft_definition))
    const initial: ParamValues = {}
    for (const p of row.draft_definition.parameters ?? []) {
      if (p.default !== undefined && p.default !== null) initial[p.key] = p.default
      else if (p.type === 'boolean') initial[p.key] = false
      else initial[p.key] = 0
    }
    setPreviewParams(initial)
    setLineOverrides({})
  }, [row])

  const preview = useMemo(() => {
    if (!def) return null
    return previewCalculator(def, previewParams, 'ca', lineOverrides)
  }, [def, previewParams, lineOverrides])

  const promptLines = useMemo(
    () => (def?.lines ?? []).filter((l) => needsQtyPricePrompt(l)),
    [def],
  )

  const boolParams = useMemo(
    () => (def?.parameters ?? []).filter((p) => p.type === 'boolean'),
    [def],
  )

  const activateGate = useMemo(() => {
    if (!def || !row) return { ok: false, reasons: ['loading'] as string[] }
    return canActivateCalculator({
      definition: def,
      hasPassingCase: cases.some((c) => c.last_result === 'pass'),
      publishedVersionId: row.published_version_id,
    })
  }, [cases, def, row])

  function updateConstant(key: string, value: number | null) {
    if (!def) return
    const next = cloneDef(def)
    next.constants = (next.constants ?? []).map((c) =>
      c.key === key ? { ...c, value, assumed: false } : c,
    )
    setDef(next)
  }

  function defJsonRefs(next: Definition): string {
    return JSON.stringify({
      lines: next.lines,
      tables: next.tables,
      parameters: next.parameters,
      constants: next.constants,
    })
  }

  function removeParameter(key: string) {
    if (!def) return
    const next = cloneDef(def)
    const refs = defJsonRefs(next)
    if (refs.includes(`"${key}"`) && refs.split(`"${key}"`).length > 2) {
      const ok = window.confirm(
        t(
          'catalog.calculators.remove_param_confirm',
          'Aquest paràmetre pot estar referenciat. Vols treure’l igualment?',
        ),
      )
      if (!ok) return
    }
    next.parameters = next.parameters.filter((p) => p.key !== key)
    setDef(next)
  }

  function removeConstant(key: string) {
    if (!def) return
    const next = cloneDef(def)
    const blob = JSON.stringify(next.lines)
    if (blob.includes(`"key":"${key}"`) || blob.includes(`"${key}"`)) {
      const ok = window.confirm(
        t(
          'catalog.calculators.remove_const_confirm',
          'Aquesta constant pot estar referenciada a línies. Vols treure-la?',
        ),
      )
      if (!ok) return
    }
    next.constants = (next.constants ?? []).filter((c) => c.key !== key)
    setDef(next)
  }

  function removeTable(key: string) {
    if (!def) return
    const next = cloneDef(def)
    next.tables = (next.tables ?? []).filter((tb) => tb.key !== key)
    setDef(next)
  }

  function confirmPendingTableDelete() {
    if (!pendingTableDelete || !def) return
    if (pendingTableDelete.kind === 'table') {
      removeTable(pendingTableDelete.key)
    } else if (pendingTableDelete.kind === 'row') {
      removeTableRow(pendingTableDelete.tableKey, pendingTableDelete.rowIndex)
    } else {
      removeTableColumn(pendingTableDelete.tableKey, pendingTableDelete.col)
    }
    setPendingTableDelete(null)
  }

  function removeLine(key: string) {
    if (!def) return
    const next = cloneDef(def)
    next.lines = next.lines.filter((l) => l.key !== key)
    setDef(next)
  }

  function updateTableCell(tableKey: string, rowIndex: number, col: string, raw: string) {
    if (!def) return
    const next = cloneDef(def)
    const table = next.tables?.find((t) => t.key === tableKey)
    if (!table) return
    const cell = table.rows[rowIndex]
    if (!cell) return
    const trimmed = raw.trim()
    if (!trimmed) cell[col] = null
    else {
      const n = Number(trimmed.replace(',', '.'))
      cell[col] = Number.isFinite(n) ? n : trimmed
    }
    delete cell.assumed
    setDef(next)
  }

  function tableDataColumns(table: NonNullable<Definition['tables']>[number]): string[] {
    const structural =
      table.lookup === 'tier'
        ? table.bound_column
        : table.match_column
    const cols = Array.from(
      new Set(
        table.rows.flatMap((r) =>
          Object.keys(r).filter((k) => k !== 'assumed' && k !== 'label'),
        ),
      ),
    )
    if (!structural) return cols
    const rest = cols.filter((c) => c !== structural)
    // Structural always first; include it even if missing from empty rows
    return [structural, ...rest]
  }

  function isOpenTierBound(value: unknown): boolean {
    return value === null || value === undefined || value === ''
  }

  function addTableRow(tableKey: string) {
    if (!def) return
    const next = cloneDef(def)
    const table = next.tables?.find((t) => t.key === tableKey)
    if (!table) return
    const cols = tableDataColumns(table)
    const templateCols =
      cols.length > 0
        ? cols
        : table.lookup === 'tier'
          ? [table.bound_column || 'max_x', 'eur_base']
          : [table.match_column || 'id', 'eur']
    const blank: Record<string, number | string | boolean | null> = {}
    for (const col of templateCols) {
      if (table.lookup === 'exact' && col === (table.match_column || 'id')) {
        blank[col] = `opt_${table.rows.length + 1}`
      } else {
        blank[col] = null
      }
    }
    // Trams: el tram obert (límit buit) ha de quedar l’últim; la fila nova va abans.
    if (table.lookup === 'tier') {
      const bound = table.bound_column || 'max_x'
      let openIdx = -1
      for (let i = table.rows.length - 1; i >= 0; i--) {
        if (isOpenTierBound(table.rows[i]?.[bound])) {
          openIdx = i
          break
        }
      }
      // Evita dos trams oberts: la fila nova porta un límit suggerit
      const finiteBounds = table.rows
        .map((r) => r[bound])
        .filter((v): v is number => typeof v === 'number' && Number.isFinite(v))
      const suggested =
        finiteBounds.length > 0 ? Math.max(...finiteBounds) * 2 : 10
      blank[bound] = suggested
      if (openIdx >= 0) {
        table.rows.splice(openIdx, 0, blank)
      } else {
        table.rows.push(blank)
      }
    } else {
      table.rows.push(blank)
    }
    setDef(next)
  }

  function updateTableLookup(
    tableKey: string,
    lookup: 'exact' | 'tier',
  ) {
    if (!def) return
    const next = cloneDef(def)
    const table = next.tables?.find((t) => t.key === tableKey)
    if (!table || table.lookup === lookup) return
    if (lookup === 'tier') {
      const bound = table.bound_column || table.match_column || 'max_x'
      table.lookup = 'tier'
      table.bound_column = bound
      delete table.match_column
      for (const row of table.rows) {
        if (!(bound in row)) row[bound] = null
      }
    } else {
      const match = table.match_column || table.bound_column || 'id'
      table.lookup = 'exact'
      table.match_column = match
      delete table.bound_column
      for (const row of table.rows) {
        if (!(match in row)) row[match] = `opt_${table.rows.indexOf(row) + 1}`
      }
    }
    setDef(next)
  }

  function updateTableInput(tableKey: string, input: string) {
    if (!def || !input) return
    const next = cloneDef(def)
    const table = next.tables?.find((t) => t.key === tableKey)
    if (!table) return
    table.input = input
    setDef(next)
  }

  function updateColumnHelp(tableKey: string, col: string, helpCa: string) {
    if (!def) return
    const next = cloneDef(def)
    const table = next.tables?.find((t) => t.key === tableKey)
    if (!table) return
    const trimmed = helpCa.trim()
    if (!trimmed) {
      if (table.column_help) {
        delete table.column_help[col]
        if (Object.keys(table.column_help).length === 0) delete table.column_help
      }
    } else {
      table.column_help = { ...table.column_help, [col]: { ca: trimmed } }
    }
    setDef(next)
  }

  function removeTableRow(tableKey: string, rowIndex: number) {
    if (!def) return
    const next = cloneDef(def)
    const table = next.tables?.find((t) => t.key === tableKey)
    if (!table) return
    if (table.rows.length <= 1) {
      toast({
        variant: 'destructive',
        description: t(
          'catalog.calculators.table_min_rows',
          'Cal almenys una fila a la taula.',
        ),
      })
      return
    }
    table.rows.splice(rowIndex, 1)
    setDef(next)
  }

  function confirmAddTableColumn() {
    if (!def || !addColumnForTable) return
    const col = newColumnName
      .trim()
      .toLowerCase()
      .normalize('NFD')
      .replace(/\p{M}/gu, '')
      .replace(/[^a-z0-9_]+/g, '_')
      .replace(/^_|_$/g, '')
      .slice(0, 40)
    if (!col || col === 'assumed' || col === 'label') {
      toast({
        variant: 'destructive',
        description: t(
          'catalog.calculators.bad_column_name',
          'Nom de columna invàlid.',
        ),
      })
      return
    }
    const next = cloneDef(def)
    const table = next.tables?.find((t) => t.key === addColumnForTable)
    if (!table) return
    if (tableDataColumns(table).includes(col)) {
      toast({
        variant: 'destructive',
        description: t(
          'catalog.calculators.dup_column',
          'Aquesta columna ja existeix.',
        ),
      })
      return
    }
    for (const row of table.rows) {
      row[col] = null
    }
    const help = newColumnHelp.trim()
    if (help) {
      table.column_help = { ...table.column_help, [col]: { ca: help } }
    }
    setDef(next)
    setAddColumnForTable(null)
    setNewColumnName('eur_')
    setNewColumnHelp('')
  }

  function removeTableColumn(tableKey: string, col: string) {
    if (!def) return
    const next = cloneDef(def)
    const table = next.tables?.find((t) => t.key === tableKey)
    if (!table) return
    if (col === table.bound_column || col === table.match_column) {
      toast({
        variant: 'destructive',
        description: t(
          'catalog.calculators.column_structural',
          'No es pot eliminar la columna de cerca/límit ({{col}}).',
          { col },
        ),
      })
      return
    }
    const cols = tableDataColumns(table)
    if (cols.length <= 1) {
      toast({
        variant: 'destructive',
        description: t(
          'catalog.calculators.table_min_cols',
          'Cal almenys una columna a la taula.',
        ),
      })
      return
    }
    for (const row of table.rows) {
      delete row[col]
    }
    if (table.column_help?.[col]) {
      delete table.column_help[col]
      if (Object.keys(table.column_help).length === 0) delete table.column_help
    }
    setDef(next)
  }

  function updateLineMeta(
    lineKey: string,
    patch: Partial<
      Pick<
        LineDef,
        'kind' | 'unit' | 'allow_zero_price' | 'prompt_qty_price' | 'unit_cost'
      >
    > & {
      nameCa?: string
      whenMode?: WhenMode
      whenParam?: string
      quantity?: Expr
      unit_price?: Expr
      discount_pct?: Expr
      tax_rate?: Expr
      whenExpr?: Expr | undefined
      clearWhen?: boolean
    },
  ) {
    if (!def) return
    const next = cloneDef(def)
    next.lines = next.lines.map((line) => {
      if (line.key !== lineKey) return line
      const updated: LineDef = { ...line }
      if (patch.kind) updated.kind = patch.kind
      if (patch.unit != null) updated.unit = patch.unit
      if (patch.allow_zero_price != null) updated.allow_zero_price = patch.allow_zero_price
      if (patch.prompt_qty_price != null) updated.prompt_qty_price = patch.prompt_qty_price
      if ('unit_cost' in patch) {
        if (patch.unit_cost == null) delete updated.unit_cost
        else updated.unit_cost = patch.unit_cost
      }
      if (patch.nameCa != null) updated.name = { ...updated.name, ca: patch.nameCa }
      if (patch.quantity) updated.quantity = patch.quantity
      if (patch.unit_price) updated.unit_price = patch.unit_price
      if (patch.discount_pct) updated.discount_pct = patch.discount_pct
      if (patch.tax_rate) updated.tax_rate = patch.tax_rate
      if (patch.clearWhen) delete updated.when
      if (patch.whenExpr !== undefined) updated.when = patch.whenExpr
      if (patch.whenMode) {
        const mode = readWhenMode(line.when, boolParams)
        if (mode.mode === 'complex') {
          /* fase 8: complex when s’edita amb el builder */
        } else {
          updated.when = writeWhenMode(patch.whenMode, patch.whenParam)
        }
      }
      return updated
    })
    setDef(next)
  }

  function addIvaConstant(rate: number) {
    if (!def) return
    const key = `iva_${rate}`
    if ((def.constants ?? []).some((c) => c.key === key)) {
      toast({
        description: t(
          'catalog.calculators.iva_const_exists',
          'Ja existeix la constant {{key}}.',
          { key },
        ),
      })
      return
    }
    const next = cloneDef(def)
    next.constants = [
      ...(next.constants ?? []),
      {
        key,
        type: 'number',
        value: rate,
        label: { ca: `IVA ${rate}%` },
      },
    ]
    setDef(next)
  }

  function addBlankLine() {
    if (!def) return
    const next = cloneDef(def)
    const key = `line_${next.lines.length + 1}`
    next.lines.push({
      key,
      name: { ca: t('catalog.calculators.new_line', 'Nova línia') },
      kind: 'service',
      unit: 'u',
      quantity: defaultBlankLineExpr('quantity'),
      unit_price: defaultBlankLineExpr('unit_price'),
      discount_pct: defaultBlankLineExpr('discount'),
      tax_rate: defaultBlankLineExpr('tax'),
      prompt_qty_price: true,
    })
    const check = validateDefinition(next)
    if (!check.ok) {
      toast({
        variant: 'destructive',
        description: check.issues.map((i) => i.message).join('; '),
      })
      return
    }
    setDef(next)
  }

  async function handleSave() {
    if (!id || !def || !canEdit || busy) return
    setBusy(true)
    try {
      const tags = tagsText
        .split(/[,;]/)
        .map((s) => s.trim().toLowerCase())
        .filter(Boolean)
        .slice(0, 8)
      await saveCalculatorDraft({
        definitionId: id,
        name,
        description,
        draftDefinition: def,
        tags,
      })
      await queryClient.invalidateQueries({ queryKey: ['calculator_definition', id] })
      await queryClient.invalidateQueries({ queryKey: ['calculator_definitions'] })
      toast({ title: t('catalog.calculators.saved', 'Desat') })
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('common:error', 'Error'),
      })
    } finally {
      setBusy(false)
    }
  }

  async function handlePublish() {
    if (!id || !def || !canEdit || busy) return
    setBusy(true)
    try {
      const tags = tagsText
        .split(/[,;]/)
        .map((s) => s.trim().toLowerCase())
        .filter(Boolean)
        .slice(0, 8)
      await saveCalculatorDraft({
        definitionId: id,
        name,
        description,
        draftDefinition: def,
        tags,
      })
      await publishCalculatorVersion(id)
      await queryClient.invalidateQueries({ queryKey: ['calculator_definition', id] })
      await queryClient.invalidateQueries({ queryKey: ['calculator_definitions'] })
      toast({ title: t('catalog.calculators.published', 'Versió publicada') })
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('common:error', 'Error'),
      })
    } finally {
      setBusy(false)
    }
  }

  async function handleActivate() {
    if (!id || !def || !row || !canEdit || busy) return
    if (!activateGate.ok) {
      toast({
        variant: 'destructive',
        description: t(
          'catalog.calculators.activate_blocked',
          'No es pot activar: forats, sense cas verd o sense versió publicada.',
        ),
      })
      return
    }
    setBusy(true)
    try {
      await setCalculatorStatus(id, 'active')
      await queryClient.invalidateQueries({ queryKey: ['calculator_definition', id] })
      toast({ title: t('catalog.calculators.activated', 'Calculadora activa') })
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('common:error', 'Error'),
      })
    } finally {
      setBusy(false)
    }
  }

  async function handleArchive() {
    if (!id || !canEdit || busy) return
    setBusy(true)
    try {
      await setCalculatorStatus(id, 'archived')
      await queryClient.invalidateQueries({ queryKey: ['calculator_definition', id] })
      toast({ title: t('catalog.calculators.archived', 'Arxivada') })
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('common:error', 'Error'),
      })
    } finally {
      setBusy(false)
    }
  }

  async function handleDelete() {
    if (!id || !canEdit || busy) return
    const ok = window.confirm(
      t(
        'catalog.calculators.delete_confirm',
        'Vols eliminar aquesta calculadora? No es pot desfer.',
      ),
    )
    if (!ok) return
    setBusy(true)
    try {
      await deleteCalculatorDefinition(id)
      await queryClient.invalidateQueries({ queryKey: ['calculator_definitions'] })
      toast({ title: t('catalog.calculators.deleted', 'Eliminada') })
      navigate('/catalog/calculators')
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('common:error', 'Error'),
      })
    } finally {
      setBusy(false)
    }
  }

  function loadCaseIntoPreview(caseRow: CalculatorCaseRow) {
    setPreviewParams({ ...(caseRow.params ?? {}) })
    setCaseName(caseRow.name)
    setEditingCaseId(caseRow.id)
    toast({
      title: t('catalog.calculators.case_loaded', 'Cas carregat a la previsualització'),
      description: t(
        'catalog.calculators.case_loaded_hint',
        'Pots ajustar els paràmetres i tornar a desar o eliminar el cas.',
      ),
    })
    document.getElementById('calculator-preview')?.scrollIntoView({ behavior: 'smooth', block: 'start' })
  }

  function clearCaseEditing() {
    setEditingCaseId(null)
    setCaseName('Escenari 1')
  }

  async function saveCaseFromPreview() {
    if (!id || !def || !preview || preview.errors.length || !canEdit || busy) return
    setBusy(true)
    try {
      await upsertCalculatorCase({
        definitionId: id,
        caseId: editingCaseId,
        name: caseName.trim() || 'Cas',
        params: previewParams,
        expectedLines: preview.lines,
        lastResult: 'pass',
      })
      await refetchCases()
      toast({
        title: editingCaseId
          ? t('catalog.calculators.case_updated', 'Cas actualitzat')
          : t('catalog.calculators.case_saved', 'Cas desat com a verd'),
      })
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('common:error', 'Error'),
      })
    } finally {
      setBusy(false)
    }
  }

  async function recheckCase(caseRow: CalculatorCaseRow) {
    if (!def || !id || !canEdit || busy) return
    setBusy(true)
    try {
      const checked = await checkCalculatorCase({ definition: def, caseRow })
      await upsertCalculatorCase({
        definitionId: id,
        caseId: caseRow.id,
        name: caseRow.name,
        params: caseRow.params,
        expectedLines: caseRow.expected_lines,
        lastResult: checked.result,
      })
      await refetchCases()
      toast({
        title:
          checked.result === 'pass'
            ? t('catalog.calculators.case_pass', 'Cas correcte')
            : t('catalog.calculators.case_fail', 'Cas fallit'),
        description: checked.diffs.length ? checked.diffs.join(', ') : undefined,
      })
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('common:error', 'Error'),
      })
    } finally {
      setBusy(false)
    }
  }

  async function confirmDeleteCase() {
    const rowCase = pendingDeleteCase
    if (!rowCase || !canEdit || busy) return
    setBusy(true)
    try {
      await deleteCalculatorCase(rowCase.id)
      if (editingCaseId === rowCase.id) clearCaseEditing()
      setPendingDeleteCase(null)
      await refetchCases()
      toast({ title: t('catalog.calculators.case_deleted', 'Cas eliminat') })
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('common:error', 'Error'),
      })
    } finally {
      setBusy(false)
    }
  }

  if (!canEdit) {
    return (
      <p className="text-sm text-muted-foreground">
        {t(
          'catalog.calculators.owner_only',
          'Només el propietari o el gestor poden editar calculadores.',
        )}
      </p>
    )
  }

  if (isLoading || !def || !row) {
    return <p className="text-sm text-muted-foreground">{t('common:loading', 'Carregant…')}</p>
  }

  const gaps = preview?.gaps ?? []

  const showPlatformBanner =
    !!row.cloned_from_catalog_id && !row.tariffs_reviewed_at
  const catalogEntry = catalog.find((c) => c.id === row.cloned_from_catalog_id) ?? null
  const showRetryActivate =
    !!row.cloned_from_catalog_id &&
    row.status !== 'active' &&
    !!catalogEntry?.default_case?.params &&
    (searchParams.get('retryActivate') === '1' || row.status === 'incomplete')

  async function handleRetryActivate() {
    if (!id || !def || !catalogEntry?.default_case || busy) return
    setBusy(true)
    try {
      await activateClonedCalculator({
        definitionId: id,
        definition: catalogEntry.definition,
        defaultCase: catalogEntry.default_case,
      })
      await queryClient.invalidateQueries({ queryKey: ['calculator_definition', id] })
      await queryClient.invalidateQueries({ queryKey: ['calculator_definitions'] })
      await queryClient.invalidateQueries({ queryKey: ['calculator_cases', id] })
      setSearchParams({}, { replace: true })
      toast({
        title: t(
          'catalog.calculators.clone_ready',
          'Clonada i activa. Ja disponible al flux ràpid.',
        ),
      })
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('common:error', 'Error'),
      })
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="space-y-6">
      <CalculatorWizards
        open={wizard}
        onClose={() => {
          setWizard(null)
          setEditParameterKey(null)
          setDraftParameter(null)
        }}
        definition={def}
        editParameterKey={editParameterKey}
        draftParameter={draftParameter}
        onApply={(next) => {
          setDef(next)
          setDraftParameter(null)
        }}
      />

      <div className="flex flex-wrap items-center gap-2">
        <Button type="button" variant="ghost" size="sm" asChild>
          <Link to="/catalog/calculators">
            <ArrowLeft className="mr-1 h-4 w-4" />
            {t('catalog.calculators.back', 'Llista')}
          </Link>
        </Button>
        <Badge variant="outline">{row.status}</Badge>
        {row.published_version_id ? (
          <Badge variant="secondary">
            {t('catalog.calculators.has_version', 'Versió publicada')}
          </Badge>
        ) : null}
        <Button type="button" variant="ghost" size="sm" onClick={() => setShowHelp((v) => !v)}>
          {showHelp
            ? t('catalog.calculators.hide_help', 'Amagar ajuda')
            : t('catalog.calculators.show_help', 'Com funciona')}
        </Button>
      </div>

      {showHelp ? (
        <section className="space-y-2 rounded-xl border border-border bg-muted/30 p-4 text-sm">
          <h2 className="text-base font-semibold">
            {t('catalog.calculators.help_title', 'Com funciona una calculadora')}
          </h2>
          <ol className="list-decimal space-y-1 pl-5 text-muted-foreground">
            <li>
              {t(
                'catalog.calculators.help_1',
                'Paràmetres: el que demanaràs al pressupost (km, m², coberts…).',
              )}
            </li>
            <li>
              {t(
                'catalog.calculators.help_2',
                'Constants i taules: les teves tarifes (€/hora, trams de km, models…).',
              )}
            </li>
            <li>
              {t(
                'catalog.calculators.help_3',
                'Línies: el que surt al document (quantitat × preu). Usa l’assistent o plantilles.',
              )}
            </li>
            <li>
              {t(
                'catalog.calculators.help_4',
                'Prova: desa un escenari correcte abans d’activar. Després surt al flux ràpid.',
              )}
            </li>
          </ol>
          <p className="text-muted-foreground">
            {t(
              'catalog.calculators.help_library',
              'Si vols començar de pressa: Catàleg → Biblioteca i clona un model llest.',
            )}
          </p>
        </section>
      ) : null}

      {showRetryActivate ? (
        <section className="space-y-2 rounded-xl border border-destructive/40 bg-destructive/10 p-4">
          <p className="text-sm">
            {t(
              'catalog.calculators.retry_activate_help',
              'Aquest clon de biblioteca encara no està actiu. Pots reintentar l’activació (cas + publicar).',
            )}
          </p>
          <Button
            type="button"
            size="sm"
            disabled={busy}
            onClick={() => void handleRetryActivate()}
          >
            {t('catalog.calculators.retry_activate', 'Reintentar activació')}
          </Button>
        </section>
      ) : null}

      {showPlatformBanner ? (
        <section className="space-y-2 rounded-xl border border-amber-500/40 bg-amber-500/10 p-4">
          <p className="text-sm">
            {t(
              'catalog.calculators.platform_prices_banner',
              'Aquesta calculadora ve de la biblioteca de plataforma amb preus d’exemple. Revisa’ls abans d’usar-la en pressupostos reals.',
            )}
          </p>
          <Button
            type="button"
            size="sm"
            variant="outline"
            disabled={busy}
            onClick={() => {
              void (async () => {
                if (!id) return
                setBusy(true)
                try {
                  await markCalculatorTariffsReviewed(id)
                  await queryClient.invalidateQueries({
                    queryKey: ['calculator_definition', id],
                  })
                  toast({
                    title: t(
                      'catalog.calculators.tariffs_reviewed',
                      'Tarifes marcades com a revisades',
                    ),
                  })
                } catch (err) {
                  toast({
                    variant: 'destructive',
                    description:
                      err instanceof Error ? err.message : t('common:error', 'Error'),
                  })
                } finally {
                  setBusy(false)
                }
              })()
            }}
          >
            {t('catalog.calculators.mark_tariffs_reviewed', 'He revisat les tarifes')}
          </Button>
        </section>
      ) : null}

      <section className="space-y-3 rounded-xl border border-dashed border-border p-4">
        <h2 className="text-base font-semibold">
          {t('catalog.calculators.ai_title', 'Proposar amb IA')}
        </h2>
        <Textarea
          value={aiPrompt}
          onChange={(e) => setAiPrompt(e.target.value)}
          rows={3}
          placeholder={t(
            'catalog.calculators.ai_ph',
            'Ex.: Cobra 40 €/hora i 1,2 €/km a partir de 30 km…',
          )}
        />
        <div className="flex flex-wrap gap-2">
          <AIGenerateAction
            feature="commercial.calculator_definition"
            responseFormat="json"
            hideStatusBanners={false}
            disabled={!aiPrompt.trim() || busy}
            label={t('catalog.calculators.ai_create', 'Generar definició')}
            messages={[
              {
                role: 'user',
                content: `Crea una Definition schema_version=1 a partir d’això (sense inventar preus no dits):\n${aiPrompt}`,
              },
            ]}
            onSuccess={(result) => {
              try {
                const parsed = parseAiCalculatorDefinition(result.content)
                setDef(demoteUnconfirmedTariffNumbers(parsed, aiPrompt))
                setPendingPatches([])
                toast({
                  title: t('catalog.calculators.ai_applied', 'Proposta carregada (esborrany)'),
                })
              } catch (err) {
                toast({
                  variant: 'destructive',
                  description: err instanceof Error ? err.message : t('common:error', 'Error'),
                })
              }
            }}
          />
          <AIGenerateAction
            feature="commercial.calculator_definition"
            responseFormat="json"
            hideStatusBanners
            disabled={!aiPrompt.trim() || !def || busy}
            label={t('catalog.calculators.ai_edit', 'Proposar canvis (diff)')}
            messages={[
              {
                role: 'user',
                content: `Edició: retorna només { "patches": [...] } sobre aquesta definició.\nDefinició actual:\n${JSON.stringify(def)}\nCanvi demanat:\n${aiPrompt}`,
              },
            ]}
            onSuccess={(result) => {
              try {
                const patches = parseAiCalculatorPatches(result.content)
                setPendingPatches(patches.map((p) => ({ ...p, accepted: true })))
              } catch (err) {
                toast({
                  variant: 'destructive',
                  description: err instanceof Error ? err.message : t('common:error', 'Error'),
                })
              }
            }}
          />
        </div>
        {pendingPatches.length > 0 ? (
          <div className="space-y-2 rounded-lg border border-border p-3">
            <p className="text-sm font-medium">
              {t('catalog.calculators.ai_diff_review', 'Revisa el diff (lot sencer o res)')}
            </p>
            {pendingPatches.map((p, i) => (
              <label key={`${p.path}-${i}`} className="flex items-start gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={p.accepted}
                  onChange={(e) => {
                    setPendingPatches((prev) =>
                      prev.map((row, idx) =>
                        idx === i ? { ...row, accepted: e.target.checked } : row,
                      ),
                    )
                  }}
                />
                <span className="font-mono text-xs">
                  {p.op} {p.path}
                  {p.value !== undefined ? ` = ${JSON.stringify(p.value)}` : ''}
                </span>
              </label>
            ))}
            <Button
              type="button"
              size="sm"
              disabled={busy || !pendingPatches.some((p) => p.accepted)}
              onClick={() => {
                if (!def) return
                try {
                  const accepted = pendingPatches.filter((p) => p.accepted)
                  const next = demoteUnconfirmedTariffNumbers(
                    applyCalculatorPatches(def, accepted),
                    aiPrompt,
                  )
                  setDef(next)
                  setPendingPatches([])
                  toast({
                    title: t('catalog.calculators.ai_diff_applied', 'Diff aplicat'),
                  })
                } catch (err) {
                  toast({
                    variant: 'destructive',
                    description: err instanceof Error ? err.message : t('common:error', 'Error'),
                  })
                }
              }}
            >
              {t('catalog.calculators.ai_apply_diff', 'Aplicar acceptats')}
            </Button>
          </div>
        ) : null}
      </section>

      <section className="space-y-3 rounded-xl border border-border p-4">
        <div className="grid gap-3 sm:grid-cols-2">
          <div className="space-y-1">
            <Label htmlFor="calc-name">{t('catalog.calculators.name', 'Nom')}</Label>
            <Input id="calc-name" value={name} onChange={(e) => setName(e.target.value)} />
          </div>
          <div className="space-y-1">
            <Label htmlFor="calc-tags">{t('catalog.calculators.tags', 'Tags (fins a 8)')}</Label>
            <Input
              id="calc-tags"
              value={tagsText}
              list="calc-known-tags"
              onChange={(e) => setTagsText(e.target.value)}
              placeholder="electricitat, camp"
            />
            <datalist id="calc-known-tags">
              {knownTags.map((tag) => (
                <option key={tag} value={tag} />
              ))}
            </datalist>
          </div>
        </div>
        <div className="space-y-1">
          <Label htmlFor="calc-desc">{t('catalog.calculators.description', 'Descripció')}</Label>
          <Textarea
            id="calc-desc"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            rows={2}
          />
        </div>
        <div className="flex flex-wrap gap-2">
          <Button type="button" disabled={busy} onClick={() => void handleSave()}>
            {t('catalog.calculators.save', 'Desar esborrany')}
          </Button>
          <Button type="button" variant="outline" disabled={busy} onClick={() => void handlePublish()}>
            {t('catalog.calculators.publish', 'Publicar versió')}
          </Button>
          <Button
            type="button"
            variant="secondary"
            disabled={busy || !activateGate.ok}
            onClick={() => void handleActivate()}
          >
            {t('catalog.calculators.activate', 'Activar')}
          </Button>
          <Button type="button" variant="ghost" disabled={busy} onClick={() => void handleArchive()}>
            {t('catalog.calculators.archive', 'Arxivar')}
          </Button>
          {row.status === 'draft' || row.status === 'incomplete' || row.status === 'archived' ? (
            <Button
              type="button"
              variant="destructive"
              disabled={busy}
              onClick={() => void handleDelete()}
            >
              {t('catalog.calculators.delete', 'Eliminar')}
            </Button>
          ) : null}
        </div>
        {gaps.length > 0 ? (
          <p className="text-sm text-amber-800 dark:text-amber-200">
            {t(
              'catalog.calculators.gaps',
              'Tarifes incompletes o assumides: {{list}}',
              { list: formatActivationGapList(def, gaps, 'ca') },
            )}
          </p>
        ) : null}
        {!activateGate.ok ? (
          <p className="text-sm text-muted-foreground">
            {t(
              'catalog.calculators.activate_hint',
              'Per activar cal: sense forats, versió publicada i almenys un cas verd.',
            )}
          </p>
        ) : null}
      </section>

      <section className="space-y-3 rounded-xl border border-border p-4">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h2 className="text-base font-semibold">
            {t('catalog.calculators.parameters', 'Paràmetres')}
          </h2>
          <div className="flex flex-wrap gap-2">
            <Button
              type="button"
              size="sm"
              variant="outline"
              onClick={() => {
                setEditParameterKey(null)
                setDraftParameter(null)
                setWizard('parameter')
              }}
            >
              {t('catalog.calculators.add_with_wizard', 'Afegir amb assistent')}
            </Button>
            <SectionAiButton
              kind="parameter"
              prompt={sectionAiPrompt.parameter}
              setPrompt={(v) => setSectionAiPrompt((prev) => ({ ...prev, parameter: v }))}
              definition={def}
              busy={busy}
              onMerged={(next) => setDef(next)}
              onProposeParameter={(param) => {
                setEditParameterKey(null)
                setDraftParameter(param)
                setWizard('parameter')
              }}
            />
          </div>
        </div>
        {(def.parameters ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">
            {t(
              'catalog.calculators.params_empty',
              'Encara no hi ha paràmetres. Afegeix-ne amb l’assistent o clona de la biblioteca.',
            )}
          </p>
        ) : (
          <ul className="space-y-1 text-sm">
            {def.parameters.map((p) => (
              <li key={p.key} className="flex flex-wrap items-center justify-between gap-2">
                <span className="text-muted-foreground">
                  {resolveLocale(p.label, 'ca') || p.key}
                  {p.unit ? (
                    <span className="ml-1 text-foreground">({p.unit})</span>
                  ) : null}{' '}
                  <span className="font-mono text-xs">
                    ({p.key || '—'}, {p.type || '—'}
                    {p.unit ? `, ${p.unit}` : ''})
                  </span>
                </span>
                <div className="flex flex-wrap gap-1">
                  <Button
                    type="button"
                    size="sm"
                    variant="outline"
                    onClick={() => {
                      setEditParameterKey(p.key)
                      setWizard('parameter')
                    }}
                  >
                    {t('catalog.calculators.edit', 'Editar')}
                  </Button>
                  <Button
                    type="button"
                    size="sm"
                    variant="ghost"
                    onClick={() => removeParameter(p.key)}
                  >
                    {t('catalog.calculators.remove', 'Treure')}
                  </Button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className="space-y-3 rounded-xl border border-border p-4">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h2 className="text-base font-semibold">
            {t('catalog.calculators.constants', 'Constants / tarifes')}
          </h2>
          <div className="flex flex-wrap gap-2">
            <Button type="button" size="sm" variant="outline" onClick={() => setWizard('constant')}>
              {t('catalog.calculators.add_with_wizard', 'Afegir amb assistent')}
            </Button>
            <SectionAiButton
              kind="constant"
              prompt={sectionAiPrompt.constant}
              setPrompt={(v) => setSectionAiPrompt((prev) => ({ ...prev, constant: v }))}
              definition={def}
              busy={busy}
              onMerged={(next) => setDef(next)}
            />
          </div>
        </div>
        <div className="flex flex-wrap items-center gap-1.5">
          <span className="text-xs text-muted-foreground">
            {t(
              'catalog.calculators.iva_const_pills',
              'Afegir constant d’IVA (per expressions):',
            )}
          </span>
          {TAX_RATE_OPTIONS.map((rate) => (
            <button
              key={rate}
              type="button"
              className="inline-flex items-center rounded-full border border-border bg-muted/40 px-2.5 py-0.5 text-xs hover:bg-muted"
              onClick={() => addIvaConstant(rate)}
            >
              IVA {rate}%
            </button>
          ))}
        </div>
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {(def.constants ?? []).map((c: Constant) => (
            <div key={c.key} className="space-y-1">
              <div className="flex items-center justify-between gap-2">
                <Label htmlFor={`const-${c.key}`}>
                  {resolveLocale(c.label, 'ca') || c.key}
                </Label>
                <Button
                  type="button"
                  size="sm"
                  variant="ghost"
                  className="h-7 px-2"
                  onClick={() => removeConstant(c.key)}
                >
                  {t('catalog.calculators.remove', 'Treure')}
                </Button>
              </div>
              <Input
                id={`const-${c.key}`}
                type="number"
                step="0.01"
                value={c.value ?? ''}
                placeholder={t('catalog.calculators.empty_value', 'Buit')}
                onChange={(e) => {
                  const raw = e.target.value.trim()
                  updateConstant(c.key, raw === '' ? null : Number(raw.replace(',', '.')))
                }}
              />
            </div>
          ))}
        </div>
      </section>

      <div className="flex flex-wrap items-center justify-between gap-2">
        <h2 className="text-base font-semibold">
          {t('catalog.calculators.tables', 'Taules')}
        </h2>
        <div className="flex flex-wrap gap-2">
          <Button
            type="button"
            size="sm"
            variant="outline"
            disabled={(def.parameters ?? []).length === 0}
            title={
              (def.parameters ?? []).length === 0
                ? t(
                    'catalog.calculators.tables_need_params',
                    'Primer afegeix almenys un paràmetre.',
                  )
                : undefined
            }
            onClick={() => setWizard('table')}
          >
            {t('catalog.calculators.add_with_wizard', 'Afegir amb assistent')}
          </Button>
          <SectionAiButton
            kind="table"
            prompt={sectionAiPrompt.table}
            setPrompt={(v) => setSectionAiPrompt((prev) => ({ ...prev, table: v }))}
            definition={def}
            busy={busy}
            disabled={(def.parameters ?? []).length === 0}
            onMerged={(next) => setDef(next)}
          />
        </div>
      </div>
      {(def.parameters ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t(
            'catalog.calculators.tables_need_params',
            'Les taules depenen d’un paràmetre d’entrada. Afegeix primer un paràmetre.',
          )}
        </p>
      ) : (def.tables ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t(
            'catalog.calculators.tables_empty',
            'Sense taules. Opcional si tot va amb constants. El valor d’una columna (eur_base, hours…) es llegeix a les Línies, no aquí.',
          )}
        </p>
      ) : (
        <p className="text-sm text-muted-foreground">
          {t(
            'catalog.calculators.tables_expr_hint',
            'La primera columna (límit/cerca) tria la fila. Les altres són dades. Quina dada s’usa es defineix a Línies (assistent o Avançat AST).',
          )}
        </p>
      )}
      {(def.tables ?? []).map((table) => {
        const cols = tableDataColumns(table)
        const structuralCol = table.lookup === 'tier' ? table.bound_column : table.match_column
        return (
          <section key={table.key} className="space-y-3 rounded-xl border border-border p-4">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <div className="min-w-0 space-y-1">
                <h2 className="text-base font-semibold">
                  {t('catalog.calculators.table', 'Taula')}: {table.key}
                </h2>
                <div className="flex flex-wrap items-end gap-2 text-xs">
                  <div className="space-y-0.5">
                    <Label className="text-[10px] text-muted-foreground">
                      {t('catalog.calculators.wizard_table_kind', 'Com es busca la fila?')}
                    </Label>
                    <select
                      className="flex h-8 rounded-md border border-input bg-background px-2 text-xs"
                      value={table.lookup}
                      onChange={(e) =>
                        updateTableLookup(table.key, e.target.value as 'exact' | 'tier')
                      }
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
                  <div className="space-y-0.5">
                    <Label className="text-[10px] text-muted-foreground">
                      {t(
                        'catalog.calculators.wizard_input_param',
                        'Paràmetre que determina la fila',
                      )}
                    </Label>
                    <select
                      className="flex h-8 min-w-[10rem] rounded-md border border-input bg-background px-2 text-xs"
                      value={table.input}
                      onChange={(e) => updateTableInput(table.key, e.target.value)}
                    >
                      {(def.parameters ?? []).map((p) => {
                        const label = resolveLocale(p.label, 'ca') || p.key
                        return (
                          <option key={p.key} value={p.key}>
                            {label === p.key ? p.key : `${label} (${p.key})`}
                          </option>
                        )
                      })}
                    </select>
                  </div>
                  {table.lookup === 'tier' ? (
                    <span className="pb-1.5 text-muted-foreground">
                      {t(
                        'catalog.calculators.tier_open_hint',
                        'Última fila amb límit buit = sense límit. Les files noves s’insereixen abans.',
                      )}
                    </span>
                  ) : null}
                </div>
              </div>
              <div className="flex flex-wrap gap-2">
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  onClick={() => addTableRow(table.key)}
                >
                  {t('catalog.calculators.add_table_row', 'Afegir fila')}
                </Button>
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  onClick={() => {
                    setNewColumnName('eur_')
                    setAddColumnForTable(table.key)
                  }}
                >
                  {t('catalog.calculators.add_table_col', 'Afegir columna')}
                </Button>
                <Button
                  type="button"
                  size="sm"
                  variant="ghost"
                  className="text-destructive hover:text-destructive"
                  onClick={() => setPendingTableDelete({ kind: 'table', key: table.key })}
                >
                  {t('catalog.calculators.remove', 'Treure')}
                </Button>
              </div>
            </div>
            <div className="overflow-x-auto">
              <table className="w-full min-w-[28rem] border-collapse text-sm">
                <thead>
                  <tr className="border-b border-border text-left">
                    {cols.map((col) => {
                      const isStructural = col === structuralCol
                      const helpText =
                        resolveLocale(table.column_help?.[col], 'ca') ||
                        (isStructural
                          ? table.lookup === 'tier'
                            ? t(
                                'catalog.calculators.col_bound_help',
                                'Límit superior del tram (no es pot eliminar)',
                              )
                            : t(
                                'catalog.calculators.col_match_help',
                                'Valor que ha de coincidir amb el paràmetre',
                              )
                          : '')
                      return (
                        <th key={col} className="px-2 py-1 align-top font-medium">
                          <div className="flex items-center gap-1.5">
                            <span className="font-mono text-xs">{col}</span>
                            {isStructural ? (
                              <Badge variant="outline" className="text-[10px] font-normal">
                                {table.lookup === 'tier'
                                  ? t('catalog.calculators.col_bound', 'límit')
                                  : t('catalog.calculators.col_match', 'cerca')}
                              </Badge>
                            ) : (
                              <Button
                                type="button"
                                size="icon"
                                variant="outline"
                                className="h-7 w-7 shrink-0 border-destructive/30 text-destructive hover:bg-destructive/10 hover:text-destructive"
                                title={t('catalog.calculators.delete_col', 'Eliminar columna')}
                                onClick={() =>
                                  setPendingTableDelete({
                                    kind: 'column',
                                    tableKey: table.key,
                                    col,
                                  })
                                }
                              >
                                <Trash2 className="h-3.5 w-3.5" />
                              </Button>
                            )}
                          </div>
                          <Input
                            className="mt-1 h-7 min-w-[7rem] border-dashed text-[10px] font-normal text-muted-foreground"
                            value={resolveLocale(table.column_help?.[col], 'ca') || ''}
                            placeholder={
                              helpText ||
                              t('catalog.calculators.column_help_ph', 'Explicació…')
                            }
                            title={t(
                              'catalog.calculators.column_help',
                              'Explicació de la columna',
                            )}
                            onChange={(e) =>
                              updateColumnHelp(table.key, col, e.target.value)
                            }
                          />
                        </th>
                      )
                    })}
                    <th className="w-10 px-2 py-1" />
                  </tr>
                </thead>
                <tbody>
                  {table.rows.map((r, ri) => (
                    <tr key={ri} className="border-b border-border/60">
                      {cols.map((col) => {
                        const val = r[col]
                        const display =
                          val == null
                            ? ''
                            : typeof val === 'object'
                              ? resolveLocale(val as never, 'ca')
                              : String(val)
                        const editable = typeof val !== 'object' || val == null
                        return (
                          <td key={col} className="px-2 py-1">
                            {editable ? (
                              <Input
                                className="h-8 min-w-[4.5rem]"
                                value={display}
                                onChange={(e) =>
                                  updateTableCell(table.key, ri, col, e.target.value)
                                }
                              />
                            ) : (
                              <span>{display}</span>
                            )}
                          </td>
                        )
                      })}
                      <td className="px-2 py-1 text-right">
                        <Button
                          type="button"
                          size="icon"
                          variant="ghost"
                          className="h-8 w-8 text-muted-foreground hover:text-destructive"
                          disabled={table.rows.length <= 1}
                          title={t('catalog.calculators.delete_row', 'Eliminar fila')}
                          onClick={() =>
                            setPendingTableDelete({
                              kind: 'row',
                              tableKey: table.key,
                              rowIndex: ri,
                            })
                          }
                        >
                          <Trash2 className="h-4 w-4" />
                        </Button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </section>
        )
      })}

      <Dialog
        open={addColumnForTable != null}
        onOpenChange={(open) => {
          if (!open) {
            setAddColumnForTable(null)
            setNewColumnName('eur_')
            setNewColumnHelp('')
          }
        }}
      >
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>
              {t('catalog.calculators.add_table_col', 'Afegir columna')}
            </DialogTitle>
            <DialogDescription>
              {t(
                'catalog.calculators.add_column_help',
                'Nom tècnic (snake_case). Després el pots usar a les expressions (p. ex. eur_base, hours).',
              )}
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-3 py-1">
            <div className="space-y-1">
              <Label>{t('catalog.calculators.column_key', 'Nom tècnic')}</Label>
              <Input
                value={newColumnName}
                onChange={(e) => setNewColumnName(e.target.value)}
                placeholder="eur_base"
                autoFocus
              />
            </div>
            <div className="space-y-1">
              <Label>
                {t('catalog.calculators.column_help', 'Explicació (opcional)')}
              </Label>
              <Input
                value={newColumnHelp}
                onChange={(e) => setNewColumnHelp(e.target.value)}
                placeholder={t(
                  'catalog.calculators.column_help_ph',
                  'Ex.: preu base del tram en €',
                )}
              />
            </div>
          </div>
          <DialogFooter className="gap-2 sm:gap-0">
            <Button
              type="button"
              variant="outline"
              onClick={() => {
                setAddColumnForTable(null)
                setNewColumnName('eur_')
                setNewColumnHelp('')
              }}
            >
              {t('common:cancel', 'Cancel·lar')}
            </Button>
            <Button type="button" onClick={confirmAddTableColumn}>
              {t('common:add', 'Afegir')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog
        open={pendingTableDelete != null}
        onOpenChange={(open) => {
          if (!open) setPendingTableDelete(null)
        }}
      >
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>
              {pendingTableDelete?.kind === 'table'
                ? t('catalog.calculators.remove_table_title', 'Treure taula')
                : pendingTableDelete?.kind === 'row'
                  ? t('catalog.calculators.delete_row_title', 'Eliminar fila')
                  : t('catalog.calculators.delete_col_title', 'Eliminar columna')}
            </DialogTitle>
            <DialogDescription>
              {pendingTableDelete?.kind === 'table'
                ? t(
                    'catalog.calculators.remove_table_confirm',
                    'Treure la taula «{{key}}»? Si alguna línia la referencia, deixarà de funcionar.',
                    { key: pendingTableDelete.key },
                  )
                : pendingTableDelete?.kind === 'row'
                  ? t(
                      'catalog.calculators.delete_row_confirm',
                      'Eliminar aquesta fila de la taula?',
                    )
                  : t(
                      'catalog.calculators.delete_col_confirm',
                      'Eliminar la columna «{{col}}» de totes les files?',
                      { col: pendingTableDelete?.kind === 'column' ? pendingTableDelete.col : '' },
                    )}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter className="gap-2 sm:gap-0">
            <Button
              type="button"
              variant="outline"
              onClick={() => setPendingTableDelete(null)}
            >
              {t('common:cancel', 'Cancel·lar')}
            </Button>
            <Button
              type="button"
              variant="destructive"
              onClick={confirmPendingTableDelete}
            >
              {t('catalog.calculators.confirm_delete', 'Eliminar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <section className="space-y-3 rounded-xl border border-border p-4">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h2 className="text-base font-semibold">
            {t('catalog.calculators.lines', 'Línies')}
          </h2>
          <div className="flex flex-wrap gap-2">
            <Button type="button" size="sm" onClick={() => setWizard('line')}>
              {t('catalog.calculators.add_with_wizard', 'Afegir amb assistent')}
            </Button>
            <SectionAiButton
              kind="line"
              prompt={sectionAiPrompt.line}
              setPrompt={(v) => setSectionAiPrompt((prev) => ({ ...prev, line: v }))}
              definition={def}
              busy={busy}
              onMerged={(next) => setDef(next)}
            />
            <Button type="button" size="sm" variant="outline" onClick={addBlankLine}>
              {t('catalog.calculators.add_line', 'Línia buida')}
            </Button>
            <Button
              type="button"
              size="sm"
              variant="ghost"
              onClick={() => setShowAdvancedExpr((v) => !v)}
            >
              {showAdvancedExpr
                ? t('catalog.calculators.hide_advanced', 'Amagar avançat')
                : t('catalog.calculators.show_advanced', 'Avançat (AST)')}
            </Button>
          </div>
        </div>
        <p className="text-sm text-muted-foreground">
          {t(
            'catalog.calculators.logic_blocks',
            'Prefereix l’assistent amb plantilles. L’editor avançat de blocs queda sota «Avançat».',
          )}
        </p>
        {(def.lines ?? []).length === 0 ? (
          <p className="rounded-lg border border-amber-500/40 bg-amber-500/10 px-3 py-2 text-sm text-amber-900 dark:text-amber-100">
            {t(
              'catalog.calculators.lines_empty_banner',
              'Afegeix almenys una línia (assistent) abans de publicar o activar.',
            )}
          </p>
        ) : null}
        <div className="space-y-3">
          {def.lines.map((line) => {
            const mode = readWhenMode(line.when, boolParams)
            return (
              <div
                key={line.key}
                className="space-y-3 rounded-lg border border-border/70 p-3"
              >
                <div className="flex justify-end">
                  <Button
                    type="button"
                    size="sm"
                    variant="ghost"
                    onClick={() => removeLine(line.key)}
                  >
                    {t('catalog.calculators.remove', 'Treure')}
                  </Button>
                </div>
                <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
                  <div className="space-y-1">
                    <Label>{t('catalog.calculators.line_name', 'Nom')}</Label>
                    <Input
                      value={resolveLocale(line.name, 'ca')}
                      onChange={(e) => updateLineMeta(line.key, { nameCa: e.target.value })}
                    />
                  </div>
                  <div className="space-y-1">
                    <Label>{t('catalog.calculators.line_unit', 'Unitat')}</Label>
                    <Input
                      value={line.unit}
                      onChange={(e) => updateLineMeta(line.key, { unit: e.target.value })}
                    />
                  </div>
                  <div className="space-y-1">
                    <Label>{t('catalog.calculators.line_kind', 'Tipus')}</Label>
                    <select
                      className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                      value={line.kind}
                      onChange={(e) =>
                        updateLineMeta(line.key, {
                          kind: e.target.value as 'product' | 'service',
                        })
                      }
                    >
                      <option value="service">service</option>
                      <option value="product">product</option>
                    </select>
                  </div>
                  <div className="space-y-1">
                    <Label>{t('catalog.calculators.line_when_simple', 'Quan (ràpid)')}</Label>
                    <select
                      className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                      value={
                        mode.mode === 'bool_param'
                          ? `bool:${mode.paramKey}`
                          : mode.mode === 'complex'
                            ? 'complex'
                            : mode.mode
                      }
                      onChange={(e) => {
                        const v = e.target.value
                        if (v === 'always' || v === 'never') {
                          updateLineMeta(line.key, { whenMode: v })
                          return
                        }
                        if (v.startsWith('bool:')) {
                          updateLineMeta(line.key, {
                            whenMode: 'bool_param',
                            whenParam: v.slice(5),
                          })
                        }
                      }}
                    >
                      <option value="always">
                        {t('catalog.calculators.when_always', 'Sempre')}
                      </option>
                      <option value="never">
                        {t('catalog.calculators.when_never', 'Mai')}
                      </option>
                      {boolParams.map((p) => (
                        <option key={p.key} value={`bool:${p.key}`}>
                          {t('catalog.calculators.when_if', 'Si')}{' '}
                          {resolveLocale(p.label, 'ca') || p.key}
                        </option>
                      ))}
                      {mode.mode === 'complex' ? (
                        <option value="complex">
                          {t('catalog.calculators.when_complex_opt', 'Condició avançada')}
                        </option>
                      ) : null}
                    </select>
                  </div>
                </div>
                <div className="flex flex-wrap gap-4">
                  <label className="flex items-center gap-2 text-sm">
                    <input
                      type="checkbox"
                      checked={Boolean(line.allow_zero_price)}
                      onChange={(e) =>
                        updateLineMeta(line.key, { allow_zero_price: e.target.checked })
                      }
                    />
                    {t('catalog.calculators.allow_zero', 'Permet preu 0')}
                  </label>
                  <label className="flex items-center gap-2 text-sm">
                    <input
                      type="checkbox"
                      checked={Boolean(line.prompt_qty_price)}
                      onChange={(e) => {
                        const on = e.target.checked
                        updateLineMeta(line.key, { prompt_qty_price: on })
                        if (!on) {
                          setLineOverrides((prev) => {
                            if (!(line.key in prev)) return prev
                            const next = { ...prev }
                            delete next[line.key]
                            return next
                          })
                        }
                      }}
                    />
                    {t(
                      'catalog.calculators.prompt_qty_price',
                      'Demanar quantitat i preu',
                    )}
                  </label>
                </div>
                <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
                  <div className="space-y-1">
                    <Label>{t('catalog.calculators.line_discount', 'Descompte %')}</Label>
                    {isSimpleConstExpr(line.discount_pct) ? (
                      <Input
                        type="number"
                        step="0.01"
                        value={unwrapConstNumber(line.discount_pct) ?? 0}
                        onChange={(e) => {
                          const n = Number(e.target.value.replace(',', '.'))
                          updateLineMeta(line.key, {
                            discount_pct: constExpr(Number.isFinite(n) ? n : 0),
                          })
                        }}
                      />
                    ) : (
                      <p className="text-xs text-muted-foreground">
                        {t(
                          'catalog.calculators.expr_advanced_field',
                          'Definit amb expressió avançada (AST).',
                        )}
                      </p>
                    )}
                  </div>
                  <div className="space-y-1">
                    <Label>{t('catalog.calculators.line_tax', 'IVA %')}</Label>
                    {isSimpleConstExpr(line.tax_rate) ? (
                      <select
                        className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                        value={String(unwrapConstNumber(line.tax_rate) ?? 21)}
                        onChange={(e) =>
                          updateLineMeta(line.key, {
                            tax_rate: constExpr(Number(e.target.value)),
                          })
                        }
                      >
                        {TAX_RATE_OPTIONS.map((r) => (
                          <option key={r} value={r}>
                            {r}%
                          </option>
                        ))}
                        {!TAX_RATE_OPTIONS.includes(
                          (unwrapConstNumber(line.tax_rate) ?? 21) as (typeof TAX_RATE_OPTIONS)[number],
                        ) ? (
                          <option value={String(unwrapConstNumber(line.tax_rate))}>
                            {unwrapConstNumber(line.tax_rate)}%
                          </option>
                        ) : null}
                      </select>
                    ) : (
                      <p className="text-xs text-muted-foreground">
                        {t(
                          'catalog.calculators.expr_advanced_field',
                          'Definit amb expressió avançada (AST).',
                        )}
                      </p>
                    )}
                  </div>
                  <div className="space-y-1">
                    <Label>
                      {t('catalog.calculators.line_unit_cost', 'Cost unitari (€)')}
                    </Label>
                    <Input
                      type="number"
                      step="0.01"
                      value={line.unit_cost ?? ''}
                      placeholder={t('catalog.calculators.empty_value', 'Buit')}
                      onChange={(e) => {
                        const raw = e.target.value.trim()
                        updateLineMeta(line.key, {
                          unit_cost: raw === '' ? null : Number(raw.replace(',', '.')),
                        })
                      }}
                    />
                  </div>
                </div>
                {!showAdvancedExpr ? (
                  <p className="text-xs text-muted-foreground font-mono">
                    qty={line.quantity.op} · price={line.unit_price.op}
                    {line.when ? ` · when=${line.when.op}` : ''}
                  </p>
                ) : (
                  <>
                    <div className="space-y-1">
                      <Label>{t('catalog.calculators.expr_qty', 'Quantitat')}</Label>
                      <CalculatorExprBuilder
                        value={line.quantity}
                        definition={def}
                        onChange={(quantity) => updateLineMeta(line.key, { quantity })}
                      />
                    </div>
                    <div className="space-y-1">
                      <Label>{t('catalog.calculators.expr_price', 'Preu unitari')}</Label>
                      <CalculatorExprBuilder
                        value={line.unit_price}
                        definition={def}
                        onChange={(unit_price) => updateLineMeta(line.key, { unit_price })}
                      />
                    </div>
                    <div className="space-y-1">
                      <Label>{t('catalog.calculators.expr_when', 'Condició when')}</Label>
                      {line.when ? (
                        <CalculatorExprBuilder
                          value={line.when}
                          definition={def}
                          allowBoolean
                          onChange={(whenExpr) => updateLineMeta(line.key, { whenExpr })}
                        />
                      ) : (
                        <Button
                          type="button"
                          size="sm"
                          variant="outline"
                          onClick={() =>
                            updateLineMeta(line.key, {
                              whenExpr: {
                                op: 'cmp',
                                cmp: 'gt',
                                left: {
                                  op: 'param',
                                  key: def.parameters[0]?.key ?? 'x',
                                },
                                right: { op: 'const', value: 0 },
                              },
                            })
                          }
                        >
                          {t('catalog.calculators.add_when', 'Afegir condició')}
                        </Button>
                      )}
                    </div>
                  </>
                )}
              </div>
            )
          })}
        </div>
      </section>

      <section
        id="calculator-preview"
        className="space-y-3 rounded-xl border border-border p-4"
      >
        <div className="flex flex-wrap items-start justify-between gap-2">
          <div>
            <h2 className="text-base font-semibold">
              {t('catalog.calculators.preview', 'Prova abans d’activar')}
            </h2>
            <p className="mt-1 text-sm text-muted-foreground">
              {t(
                'catalog.calculators.preview_help',
                'Introdueix un escenari (p. ex. 20 km). El resultat es mostra com el full de preus de Preparar. Desa’l com a prova; sense una prova correcta no es pot activar.',
              )}
            </p>
          </div>
          {editingCaseId ? (
            <Badge variant="secondary">
              {t('catalog.calculators.editing_case', 'Editant cas desat')}
            </Badge>
          ) : null}
        </div>
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {(def.parameters ?? []).map((p) => (
            <div key={p.key} className="space-y-1">
              <Label htmlFor={`param-${p.key}`}>
                {resolveLocale(p.label, 'ca') || p.key}
                {p.unit ? (
                  <span className="ml-1 font-normal text-muted-foreground">({p.unit})</span>
                ) : null}
              </Label>
              {p.type === 'boolean' ? (
                <select
                  id={`param-${p.key}`}
                  className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                  value={String(Boolean(previewParams[p.key]))}
                  onChange={(e) =>
                    setPreviewParams((prev) => ({
                      ...prev,
                      [p.key]: e.target.value === 'true',
                    }))
                  }
                >
                  <option value="false">false</option>
                  <option value="true">true</option>
                </select>
              ) : (
                <div className="relative">
                  <Input
                    id={`param-${p.key}`}
                    type="number"
                    className={p.unit ? 'pr-12' : undefined}
                    value={previewParams[p.key] == null ? '' : String(previewParams[p.key])}
                    onChange={(e) => {
                      const n = Number(e.target.value.replace(',', '.'))
                      setPreviewParams((prev) => ({
                        ...prev,
                        [p.key]: Number.isFinite(n) ? n : 0,
                      }))
                    }}
                  />
                  {p.unit ? (
                    <span className="pointer-events-none absolute inset-y-0 right-3 flex items-center text-xs font-medium text-muted-foreground">
                      {p.unit}
                    </span>
                  ) : null}
                </div>
              )}
            </div>
          ))}
        </div>
        {promptLines.length > 0 ? (
          <div className="space-y-2 rounded-lg border border-dashed border-border p-3">
            <p className="text-sm font-medium">
              {t(
                'catalog.calculators.prompt_qty_price_title',
                'Quantitat i preu (línies a demanar)',
              )}
            </p>
            <div className="grid gap-3 sm:grid-cols-2">
              {promptLines.map((line) => {
                const fromRun = preview?.lines.find((l) => l.key === line.key)
                const ov = lineOverrides[line.key]
                return (
                  <div
                    key={line.key}
                    className="grid grid-cols-2 gap-2 rounded-md border border-border/60 p-2"
                  >
                    <p className="col-span-2 text-xs font-medium">
                      {resolveLocale(line.name, 'ca') || line.key}
                    </p>
                    <div className="space-y-1">
                      <Label className="text-xs">
                        {t('catalog.calculators.expr_qty', 'Quantitat')}
                      </Label>
                      <Input
                        type="number"
                        step="0.001"
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
                        {t('catalog.calculators.expr_price', 'Preu unitari')}
                      </Label>
                      <Input
                        type="number"
                        step="0.01"
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
          </div>
        ) : null}
        {gaps.length > 0 ? (
          <p className="text-sm text-amber-800 dark:text-amber-200" role="status">
            {t(
              'catalog.calculators.preview_needs_tariff',
              'Omple les tarifes incompletes a Constants o Taules abans de previsualitzar. Pendents: {{list}}',
              { list: formatActivationGapList(def, gaps, 'ca') },
            )}
          </p>
        ) : (preview?.lines.length ?? 0) === 0 && (preview?.errors.length ?? 0) > 0 ? (
          <p className="text-sm text-destructive" role="alert">
            {formatCalcErrorList(def, preview!.errors, 'ca')}
          </p>
        ) : (
          <>
            {(preview?.errors.length ?? 0) > 0 ? (
              <p className="text-sm text-amber-800 dark:text-amber-200" role="status">
                {formatCalcErrorList(def, preview!.errors, 'ca')}
              </p>
            ) : null}
            {(preview?.lines.length ?? 0) > 0 ? (
              <CalculatorPreviewSheet
                lines={preview?.lines ?? []}
                totals={preview?.totals ?? null}
              />
            ) : null}
          </>
        )}
        <div className="flex flex-wrap items-end gap-2">
          <div className="space-y-1">
            <Label htmlFor="case-name">
              {t('catalog.calculators.case_name', 'Nom de l’escenari')}
            </Label>
            <Input
              id="case-name"
              value={caseName}
              onChange={(e) => setCaseName(e.target.value)}
              placeholder={t('catalog.calculators.case_name_ph', 'p. ex. Visita 20 km / 3 kW')}
            />
          </div>
          <Button
            type="button"
            disabled={busy || gaps.length > 0 || !!preview?.errors.length}
            onClick={() => void saveCaseFromPreview()}
          >
            {editingCaseId
              ? t('catalog.calculators.update_case', 'Actualitzar prova desada')
              : t(
                  'catalog.calculators.use_preview_case',
                  'Desar aquest resultat com a prova que ha de passar',
                )}
          </Button>
          {editingCaseId ? (
            <Button type="button" variant="outline" disabled={busy} onClick={clearCaseEditing}>
              {t('catalog.calculators.new_case', 'Nou cas')}
            </Button>
          ) : null}
        </div>
      </section>

      <section className="space-y-3 rounded-xl border border-border p-4">
        <h2 className="text-base font-semibold">
          {t('catalog.calculators.cases', 'Proves desades')}
        </h2>
        <p className="text-sm text-muted-foreground">
          {t(
            'catalog.calculators.cases_help',
            'Carrega un cas a la previsualització per veure’l o editar-lo. «Tornar a calcular» compara amb el resultat esperat després de canviar tarifes.',
          )}
        </p>
        {cases.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            {t('catalog.calculators.cases_empty', 'Encara no hi ha proves desades.')}
          </p>
        ) : (
          <ul className="space-y-2">
            {cases.map((c) => (
              <li
                key={c.id}
                className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-border px-3 py-2"
              >
                <div>
                  <p className="font-medium">
                    {c.name}
                    {editingCaseId === c.id ? (
                      <Badge variant="outline" className="ml-2">
                        {t('catalog.calculators.loaded', 'Carregat')}
                      </Badge>
                    ) : null}
                  </p>
                  <p className="text-xs text-muted-foreground">
                    {c.last_result === 'pass'
                      ? t('catalog.calculators.case_pass', 'Correcte')
                      : c.last_result === 'fail'
                        ? t('catalog.calculators.case_fail', 'Fallit')
                        : t('catalog.calculators.case_unrun', 'Sense executar')}
                    {' · '}
                    {Object.keys(c.params ?? {}).length} params
                  </p>
                </div>
                <div className="flex flex-wrap gap-2">
                  <Button
                    type="button"
                    size="sm"
                    variant="secondary"
                    disabled={busy}
                    onClick={() => loadCaseIntoPreview(c)}
                  >
                    {t('catalog.calculators.load_case', 'Carregar a previsualització')}
                  </Button>
                  <Button
                    type="button"
                    size="sm"
                    variant="outline"
                    disabled={busy}
                    onClick={() => void recheckCase(c)}
                  >
                    {t('catalog.calculators.check_case', 'Tornar a calcular')}
                  </Button>
                  <Button
                    type="button"
                    size="sm"
                    variant="outline"
                    disabled={busy}
                    onClick={() => setPendingDeleteCase(c)}
                  >
                    {t('catalog.calculators.delete_case', 'Eliminar')}
                  </Button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>

      <Dialog
        open={pendingDeleteCase != null}
        onOpenChange={(open) => {
          if (!open && !busy) setPendingDeleteCase(null)
        }}
      >
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>
              {t('catalog.calculators.delete_case_title', 'Eliminar cas')}
            </DialogTitle>
            <DialogDescription>
              {t(
                'catalog.calculators.delete_case_confirm',
                'Eliminar «{{name}}»? Aquesta acció no es pot desfer.',
                { name: pendingDeleteCase?.name ?? '' },
              )}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter className="gap-2 sm:gap-0">
            <Button
              type="button"
              variant="outline"
              disabled={busy}
              onClick={() => setPendingDeleteCase(null)}
            >
              {t('common:cancel', 'Cancel·lar')}
            </Button>
            <Button
              type="button"
              variant="destructive"
              disabled={busy}
              onClick={() => void confirmDeleteCase()}
            >
              {t('catalog.calculators.delete_case', 'Eliminar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <div className="pb-8">
        <Button type="button" variant="outline" onClick={() => navigate('/catalog/calculators')}>
          {t('catalog.calculators.back', 'Llista')}
        </Button>
      </div>
    </div>
  )
}

function sectionAiSystemHint(kind: CalculatorFragmentKind): string {
  const keyRule =
    'REGLA CLAU: "key" ha de ser identificador tècnic ASCII: només [a-z][a-z0-9_]{0,40} (minúscules, snake_case). ' +
    'Exemples vàlids: weight_kg, distance_km, power_kw, hours. ' +
    'Exemples INVÀLIDS: "Pes", "Weight (kg)", "weight-kg", "WeightKg", accents o espais. ' +
    'La etiqueta humana va a label.ca (p.ex. "Pes"), NO a key.'

  if (kind === 'parameter') {
    return [
      'Retorna NOMÉS JSON {"parameter":{...}} sense markdown.',
      'Un paràmetre és una ENTRADA de l’usuari (pes, km, hores…), NO una tarifa €.',
      keyRule,
      'label.ca i key HAN de reflectir el concepte de la demanda de l’usuari.',
      'Si diu «pes» → {"key":"weight_kg","label":{"ca":"Pes"},"unit":"kg"}.',
      'MAI usis «Paràmetre»/«parametre»/«parameter» com a label o key.',
      'Camps: key, type (number|integer|boolean|enum), required, label:{ca}, unit (opcional).',
      'Exemple: {"parameter":{"key":"weight_kg","type":"number","required":true,"label":{"ca":"Pes"},"min":0,"unit":"kg"}}',
    ].join(' ')
  }
  if (kind === 'constant') {
    return [
      'Retorna NOMÉS JSON {"constant":{...}} sense markdown.',
      'Una constant és una TARIFA o valor fix (p.ex. labor_eur_h = 45).',
      keyRule,
      'Camps: key, type (money|number), value (nombre o null), label:{ca}.',
      'Exemple: {"constant":{"key":"labor_eur_h","type":"money","value":45,"label":{"ca":"€/hora mà d’obra"}}}',
    ].join(' ')
  }
  if (kind === 'table') {
    return [
      'Retorna NOMÉS JSON {"table":{...}} sense markdown.',
      keyRule,
      'Camps: key, lookup (exact|tier), input (clau d’un paràmetre existent), bound_column o match_column, rows[].',
      'Exemple tier: {"table":{"key":"travel","lookup":"tier","input":"distance_km","bound_column":"max_km","rows":[{"max_km":15,"eur_base":0},{"max_km":40,"eur_base":35},{"max_km":null,"eur_base":55}]}}',
    ].join(' ')
  }
  return [
    'Retorna NOMÉS JSON {"line":{...}} sense markdown.',
    keyRule,
    'Camps: key, name:{ca}, kind (product|service), unit, quantity (Expr), unit_price (Expr),',
    'discount_pct (Expr const), tax_rate (Expr const, p.ex. 21),',
    'prompt_qty_price (boolean opcional: true = a l’ús demanar qty/preu; la fórmula és valor inicial),',
    'unit_cost (nombre € opcional, cost intern).',
    'Exemple: {"line":{"key":"labor","name":{"ca":"Mà d’obra"},"kind":"service","unit":"h",',
    '"quantity":{"op":"round","decimals":3,"mode":"half_away_from_zero","value":{"op":"const","value":1}},',
    '"unit_price":{"op":"round","decimals":2,"mode":"half_away_from_zero","value":{"op":"const_ref","key":"hour_eur"}},',
    '"discount_pct":{"op":"const","value":0},"tax_rate":{"op":"const","value":21},',
    '"prompt_qty_price":false}}',
    'Si l’usuari diu «demanar quantitat i preu» → prompt_qty_price true.',
  ].join(' ')
}

function SectionAiButton(props: {
  kind: CalculatorFragmentKind
  prompt: string
  setPrompt: (v: string) => void
  definition: Definition
  busy: boolean
  disabled?: boolean
  onMerged: (next: Definition) => void
  /** Paràmetres: omple el modal Afegir/Editar en lloc de crear directament. */
  onProposeParameter?: (param: Parameter) => void
}) {
  const { t } = useTranslation(['catalog', 'common'])
  const { toast } = useToast()
  const [open, setOpen] = useState(false)
  const kindLabel =
    props.kind === 'parameter'
      ? 'paràmetre'
      : props.kind === 'constant'
        ? 'constant/tarifa'
        : props.kind === 'table'
          ? 'taula'
          : 'línia'

  const firstParam = props.definition.parameters?.[0]
  const firstParamLabel = firstParam
    ? resolveLocale(firstParam.label, 'ca') || firstParam.key
    : 'x'

  const placeholder =
    props.kind === 'parameter'
      ? t(
          'catalog.calculators.ai_section_ph_param',
          'Ex.: distància en km obligatòria…',
        )
      : props.kind === 'constant'
        ? t(
            'catalog.calculators.ai_section_ph_const',
            'Ex.: afegeix €/hora de 45…',
          )
        : props.kind === 'table'
          ? t(
              'catalog.calculators.ai_section_ph_table',
              'Ex.: Vull una taula pel paràmetre {{param}} amb trams de desplaçament…',
              { param: firstParamLabel },
            )
          : t('catalog.calculators.ai_section_ph', 'Descriu què vols afegir…')

  function appendParamHint(p: Parameter) {
    const label = resolveLocale(p.label, 'ca') || p.key
    const snippet =
      label === p.key
        ? `pel paràmetre ${p.key}`
        : `pel paràmetre ${label} (${p.key})`
    const current = props.prompt.trim()
    if (!current) {
      props.setPrompt(`Vull una taula ${snippet} que `)
      return
    }
    if (current.includes(p.key) || current.includes(label)) return
    props.setPrompt(`${current} ${snippet}`)
  }

  return (
    <>
      <Button
        type="button"
        size="sm"
        variant="secondary"
        disabled={props.disabled}
        title={
          props.disabled
            ? t(
                'catalog.calculators.tables_need_params',
                'Primer afegeix almenys un paràmetre.',
              )
            : undefined
        }
        onClick={() => setOpen(true)}
      >
        {t('catalog.calculators.ai_section', 'Proposar amb IA')}
      </Button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="sm:max-w-lg">
          <DialogHeader>
            <DialogTitle>
              {t('catalog.calculators.ai_section_title', 'Proposar {{kind}} amb IA', {
                kind: kindLabel,
              })}
            </DialogTitle>
            <DialogDescription>
              {props.kind === 'parameter'
                ? t(
                    'catalog.calculators.ai_section_hint_param',
                    'La IA omple el formulari «Afegir paràmetre»; tu confirmes abans de crear-lo.',
                  )
                : props.kind === 'table'
                  ? t(
                      'catalog.calculators.ai_section_hint_table',
                      'Descriu la taula. Pots clicar un paràmetre per enganxar-lo al prompt.',
                    )
                  : t(
                      'catalog.calculators.ai_section_hint',
                      'Descriu el fragment; pots ajustar model i temperatura abans de generar.',
                    )}
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-3 py-1">
            <Textarea
              value={props.prompt}
              onChange={(e) => props.setPrompt(e.target.value)}
              placeholder={placeholder}
              rows={5}
              className="min-h-[7.5rem] resize-y"
              autoFocus
            />
            {props.kind === 'table' && (props.definition.parameters ?? []).length > 0 ? (
              <div className="flex flex-wrap gap-1.5">
                <span className="w-full text-xs text-muted-foreground">
                  {t(
                    'catalog.calculators.ai_table_param_chips',
                    'Enganxa un paràmetre al prompt:',
                  )}
                </span>
                {(props.definition.parameters ?? []).map((p) => {
                  const label = resolveLocale(p.label, 'ca') || p.key
                  return (
                    <button
                      key={p.key}
                      type="button"
                      className="inline-flex items-center rounded-full border border-border bg-muted/40 px-2.5 py-0.5 text-xs hover:bg-muted"
                      onClick={() => appendParamHint(p)}
                    >
                      {label}
                      {label !== p.key ? (
                        <span className="ml-1 font-mono text-[10px] opacity-60">{p.key}</span>
                      ) : null}
                    </button>
                  )
                })}
              </div>
            ) : null}
            <AIGenerateAction
              feature="commercial.calculator_definition"
              responseFormat="json"
              hideStatusBanners
              disabled={props.busy}
              generateDisabled={!props.prompt.trim()}
              label={t('catalog.calculators.ai_section_go', 'Generar {{kind}}', {
                kind: kindLabel,
              })}
              messages={[
                {
                  role: 'system',
                  content: sectionAiSystemHint(props.kind),
                },
                {
                  role: 'user',
                  content: `Context claus actuals:\nparameters=${JSON.stringify(
                    (props.definition.parameters ?? []).map((p) => ({
                      key: p.key,
                      label: resolveLocale(p.label, 'ca') || p.key,
                      type: p.type,
                    })),
                  )}\nconstants=${JSON.stringify(props.definition.constants?.map((c) => c.key))}\ntables=${JSON.stringify(props.definition.tables?.map((tb) => tb.key))}\nDemanda:\n${props.prompt}`,
                },
              ]}
              onSuccess={(result) => {
                try {
                  if (
                    props.kind === 'parameter' &&
                    /€\s*\/\s*h|eur(?:os)?\s*\/?\s*h|tarifa|preu/i.test(props.prompt)
                  ) {
                    toast({
                      variant: 'destructive',
                      description: t(
                        'catalog.calculators.ai_use_constant',
                        'Això sembla una tarifa (€/h). Usa «Proposar amb IA» a Constants / tarifes.',
                      ),
                    })
                    return
                  }
                  if (props.kind === 'parameter' && props.onProposeParameter) {
                    const proposal = parseAiParameterProposal(
                      result.content,
                      props.prompt,
                      props.definition.parameters.map((p) => p.key),
                    )
                    props.onProposeParameter(proposal)
                    setOpen(false)
                    props.setPrompt('')
                    toast({
                      title: t(
                        'catalog.calculators.ai_section_review',
                        'Revisa i confirma el paràmetre',
                      ),
                    })
                    return
                  }
                  let next = parseAiCalculatorFragment(
                    result.content,
                    props.kind,
                    props.definition,
                    props.prompt,
                  )
                  if (props.kind === 'constant' || props.kind === 'table') {
                    next = demoteUnconfirmedTariffNumbers(next, props.prompt)
                  }
                  props.onMerged(next)
                  setOpen(false)
                  props.setPrompt('')
                  toast({
                    title: t(
                      'catalog.calculators.ai_section_ok',
                      'Fragment afegit a l’esborrany',
                    ),
                  })
                } catch (err) {
                  toast({
                    variant: 'destructive',
                    description:
                      err instanceof Error ? err.message : t('common:error', 'Error'),
                  })
                }
              }}
            />
          </div>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => setOpen(false)}>
              {t('common:cancel', 'Cancel·lar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  )
}
