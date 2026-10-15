import { Dec, lineNet, lineTax } from './money.ts'
import { fillPlaceholders, resolveLocale } from './locale.ts'
import { shouldDeferZeroPriceCheck } from './linePrompt.ts'
import type {
  CalcError,
  Definition,
  Expr,
  LineDef,
  LookupTable,
  OutputLine,
  ParamValues,
  PreviewTotals,
  RunResult,
  TableRow,
} from './types.ts'

type EvalValue = Dec | boolean | string | null

type Ctx = {
  definition: Definition
  params: ParamValues
  locale: string
  row: TableRow | null
  path: string
  errors: CalcError[]
}

function err(ctx: Ctx, code: CalcError['code'], path = ctx.path): null {
  ctx.errors.push({ code, path })
  return null
}

function asDec(v: EvalValue, ctx: Ctx): Dec | null {
  if (v instanceof Dec) return v
  if (typeof v === 'boolean') return Dec.from(v)
  if (typeof v === 'string' || typeof v === 'number') {
    try {
      return Dec.from(v as string | number)
    } catch {
      return err(ctx, 'type_error')
    }
  }
  if (v === null) return err(ctx, 'tariff_incomplete')
  return err(ctx, 'type_error')
}

function asBool(v: EvalValue, ctx: Ctx): boolean | null {
  if (typeof v === 'boolean') return v
  if (v instanceof Dec) return !v.isZero()
  return err(ctx, 'type_error')
}

function findTable(def: Definition, key: string): LookupTable | undefined {
  return def.tables?.find((t) => t.key === key)
}

function resolveParam(ctx: Ctx, key: string): EvalValue {
  const meta = ctx.definition.parameters.find((p) => p.key === key)
  if (!meta) return err(ctx, 'param_missing', `param.${key}`)
  let raw = ctx.params[key]
  if (raw === undefined || raw === null || raw === '') {
    if (meta.default !== undefined && meta.default !== null) {
      raw = meta.default
    } else if (meta.required !== false) {
      return err(ctx, 'param_missing', `param.${key}`)
    } else {
      return null
    }
  }
  if (meta.type === 'boolean') {
    if (typeof raw === 'boolean') return raw
    if (raw === 'true') return true
    if (raw === 'false') return false
    return err(ctx, 'type_error', `param.${key}`)
  }
  if (meta.type === 'enum') {
    return String(raw)
  }
  try {
    const d = Dec.from(raw as string | number)
    if (meta.type === 'integer' && d.round(0).cmp(d) !== 0) {
      return err(ctx, 'type_error', `param.${key}`)
    }
    if (meta.min !== undefined && d.cmp(Dec.from(meta.min)) < 0) {
      return err(ctx, 'param_out_of_range', `param.${key}`)
    }
    if (meta.max !== undefined && d.cmp(Dec.from(meta.max)) > 0) {
      return err(ctx, 'param_out_of_range', `param.${key}`)
    }
    return d
  } catch {
    return err(ctx, 'type_error', `param.${key}`)
  }
}

function evalExpr(expr: Expr, ctx: Ctx): EvalValue {
  if (ctx.errors.length) return null

  switch (expr.op) {
    case 'const': {
      if (expr.value === null) return null
      if (typeof expr.value === 'boolean') return expr.value
      if (typeof expr.value === 'string') {
        // numeric string → Dec; non-numeric stays string (rare)
        try {
          return Dec.from(expr.value)
        } catch {
          return expr.value
        }
      }
      return Dec.from(expr.value)
    }
    case 'param':
      return resolveParam(ctx, expr.key)
    case 'const_ref': {
      const c = ctx.definition.constants?.find((x) => x.key === expr.key)
      if (!c) return err(ctx, 'tariff_incomplete', `const.${expr.key}`)
      if (c.value === null || c.assumed) {
        return err(ctx, 'tariff_incomplete', `const.${expr.key}`)
      }
      return Dec.from(c.value)
    }
    case 'add':
    case 'mul':
    case 'min':
    case 'max': {
      if (expr.args.length < 2) return err(ctx, 'type_error')
      const nums = expr.args.map((a) => asDec(evalExpr(a, ctx), ctx))
      if (nums.some((n) => n === null) || ctx.errors.length) return null
      let acc = nums[0]!
      for (let i = 1; i < nums.length; i++) {
        const n = nums[i]!
        if (expr.op === 'add') acc = acc.add(n)
        else if (expr.op === 'mul') acc = acc.mul(n)
        else if (expr.op === 'min') acc = acc.min(n)
        else acc = acc.max(n)
      }
      return acc
    }
    case 'sub': {
      const l = asDec(evalExpr(expr.left, ctx), ctx)
      const r = asDec(evalExpr(expr.right, ctx), ctx)
      if (!l || !r || ctx.errors.length) return null
      return l.sub(r)
    }
    case 'div': {
      const l = asDec(evalExpr(expr.left, ctx), ctx)
      const r = asDec(evalExpr(expr.right, ctx), ctx)
      if (!l || !r || ctx.errors.length) return null
      if (r.isZero()) return err(ctx, 'division_by_zero')
      return l.div(r)
    }
    case 'round': {
      const v = asDec(evalExpr(expr.value, ctx), ctx)
      if (!v || ctx.errors.length) return null
      return v.round(expr.decimals)
    }
    case 'if': {
      const c = asBool(evalExpr(expr.cond, ctx), ctx)
      if (c === null || ctx.errors.length) return null
      return evalExpr(c ? expr.then : expr.else, ctx)
    }
    case 'cmp': {
      const l = asDec(evalExpr(expr.left, ctx), ctx)
      const r = asDec(evalExpr(expr.right, ctx), ctx)
      if (!l || !r || ctx.errors.length) return null
      const c = l.cmp(r)
      switch (expr.cmp) {
        case 'gt':
          return c > 0
        case 'gte':
          return c >= 0
        case 'lt':
          return c < 0
        case 'lte':
          return c <= 0
        case 'eq':
          return c === 0
        case 'neq':
          return c !== 0
      }
      break
    }
    case 'and': {
      for (const a of expr.args) {
        const b = asBool(evalExpr(a, ctx), ctx)
        if (b === null || ctx.errors.length) return null
        if (!b) return false
      }
      return true
    }
    case 'or': {
      for (const a of expr.args) {
        const b = asBool(evalExpr(a, ctx), ctx)
        if (b === null || ctx.errors.length) return null
        if (b) return true
      }
      return false
    }
    case 'not': {
      const b = asBool(evalExpr(expr.arg, ctx), ctx)
      if (b === null || ctx.errors.length) return null
      return !b
    }
    case 'lookup_exact': {
      const table = findTable(ctx.definition, expr.table)
      if (!table || table.lookup !== 'exact' || !table.match_column) {
        return err(ctx, 'lookup_miss', `table.${expr.table}`)
      }
      const input = resolveParam(ctx, table.input)
      if (ctx.errors.length) return null
      const match = input instanceof Dec ? input.toFixed(3) : String(input ?? '')
      const row = table.rows.find((r) => String(r[table.match_column!]) === match)
      if (!row) return err(ctx, 'lookup_miss', `table.${expr.table}`)
      const field = row[expr.field]
      if (field === null || field === undefined) {
        return err(ctx, 'tariff_incomplete', `table.${expr.table}.${expr.field}`)
      }
      if (typeof field === 'object' && !Array.isArray(field)) {
        return err(ctx, 'type_error', `table.${expr.table}.${expr.field}`)
      }
      if (typeof field === 'boolean') return field
      if (typeof field === 'string') {
        try {
          return Dec.from(field)
        } catch {
          return field
        }
      }
      return Dec.from(field as number)
    }
    case 'lookup_tier': {
      const table = findTable(ctx.definition, expr.table)
      if (!table || table.lookup !== 'tier' || !table.bound_column) {
        return err(ctx, 'lookup_miss', `table.${expr.table}`)
      }
      const inputVal = resolveParam(ctx, table.input)
      const inputDec = asDec(inputVal, ctx)
      if (!inputDec || ctx.errors.length) return null
      let chosen: TableRow | null = null
      for (const row of table.rows) {
        const bound = row[table.bound_column]
        if (bound === null || bound === undefined) {
          chosen = row
          break
        }
        const b = Dec.from(bound as number | string)
        if (inputDec.cmp(b) <= 0) {
          chosen = row
          break
        }
      }
      if (!chosen) return err(ctx, 'lookup_miss', `table.${expr.table}`)
      const innerCtx: Ctx = { ...ctx, row: chosen }
      return evalExpr(expr.value, innerCtx)
    }
    case 'row': {
      if (!ctx.row) return err(ctx, 'type_error', 'row')
      const field = ctx.row[expr.field]
      if (field === null || field === undefined) {
        return err(ctx, 'tariff_incomplete', `row.${expr.field}`)
      }
      if (typeof field === 'object') return err(ctx, 'type_error', `row.${expr.field}`)
      if (typeof field === 'boolean') return field
      return Dec.from(field as number | string)
    }
    case 'coalesce': {
      for (const a of expr.args) {
        const v = evalExpr(a, ctx)
        if (ctx.errors.length) {
          // coalesce swallows tariff_incomplete / null, not hard errors
          const last = ctx.errors[ctx.errors.length - 1]
          if (last.code === 'tariff_incomplete' || last.code === 'lookup_miss') {
            ctx.errors.pop()
            continue
          }
          return null
        }
        if (v !== null) return v
      }
      return null
    }
    default:
      return err(ctx, 'type_error')
  }
  return err(ctx, 'type_error')
}

function enumLabel(
  def: Definition,
  paramKey: string,
  value: string,
  locale: string,
): string {
  const param = def.parameters.find((p) => p.key === paramKey)
  if (!param?.options_from) return value
  const table = findTable(def, param.options_from)
  if (!table) return value
  const row = table.rows.find((r) => String(r.id) === value)
  if (!row) return value
  const label = row.label
  if (label && typeof label === 'object') {
    const resolved = resolveLocale(label as { ca?: string; es?: string; en?: string }, locale)
    if (resolved) return resolved
  }
  return value
}

function buildNamePlaceholders(ctx: Ctx): Record<string, string> {
  const out: Record<string, string> = {}
  for (const p of ctx.definition.parameters) {
    const raw = ctx.params[p.key] ?? p.default
    if (raw === undefined || raw === null) continue
    if (p.type === 'enum') {
      out[p.key] = enumLabel(ctx.definition, p.key, String(raw), ctx.locale)
    } else if (typeof raw === 'boolean') {
      out[p.key] = raw ? 'true' : 'false'
    } else {
      out[p.key] = String(raw)
    }
  }
  return out
}

function evalLine(line: LineDef, ctx: Ctx, index: number): OutputLine | 'skip' | null {
  const linePath = `lines[${index}]`
  if (line.when) {
    const whenCtx: Ctx = { ...ctx, path: `${linePath}.when` }
    const w = asBool(evalExpr(line.when, whenCtx), whenCtx)
    if (whenCtx.errors.length) {
      ctx.errors.push(...whenCtx.errors)
      return null
    }
    if (!w) return 'skip'
  }

  const qCtx: Ctx = { ...ctx, path: `${linePath}.quantity`, errors: [] }
  const pCtx: Ctx = { ...ctx, path: `${linePath}.unit_price`, errors: [] }
  const dCtx: Ctx = { ...ctx, path: `${linePath}.discount_pct`, errors: [] }
  const tCtx: Ctx = { ...ctx, path: `${linePath}.tax_rate`, errors: [] }

  const qty = asDec(evalExpr(line.quantity, qCtx), qCtx)
  const price = asDec(evalExpr(line.unit_price, pCtx), pCtx)
  let disc = asDec(evalExpr(line.discount_pct, dCtx), dCtx)
  let tax = asDec(evalExpr(line.tax_rate, tCtx), tCtx)

  for (const e of [...qCtx.errors, ...pCtx.errors, ...dCtx.errors, ...tCtx.errors]) {
    ctx.errors.push(e)
  }
  if (ctx.errors.length || !qty || !price || !disc || !tax) return null

  disc = disc.round(2)
  tax = tax.round(2)

  if (disc.cmp(Dec.from(0)) < 0 || disc.cmp(Dec.from(100)) > 0) {
    return err(ctx, 'param_out_of_range', `${linePath}.discount_pct`)
  }
  if (tax.cmp(Dec.from(0)) < 0 || tax.cmp(Dec.from(100)) > 0) {
    return err(ctx, 'param_out_of_range', `${linePath}.tax_rate`)
  }

  if (price.isZero() && !line.allow_zero_price && !shouldDeferZeroPriceCheck(line)) {
    return err(ctx, 'zero_price_not_allowed', `${linePath}.unit_price`)
  }

  const placeholders = buildNamePlaceholders(ctx)
  const name = fillPlaceholders(resolveLocale(line.name, ctx.locale), placeholders)
  const description = line.description
    ? fillPlaceholders(resolveLocale(line.description, ctx.locale), placeholders)
    : null

  const out: OutputLine = {
    key: line.key,
    kind: line.kind,
    name,
    description: description || null,
    unit: line.unit,
    quantity: qty.toFixed(3),
    unit_price: price.toFixed(2),
    discount_pct: disc.toFixed(2),
    tax_rate: tax.toFixed(2),
    allow_zero_price: !!line.allow_zero_price,
  }
  if (line.unit_cost != null && Number.isFinite(line.unit_cost)) {
    out.unit_cost = Number(line.unit_cost).toFixed(2)
  } else if (line.unit_cost === null) {
    out.unit_cost = null
  }
  return out
}

export function run(
  definition: Definition,
  params: ParamValues,
  locale = 'ca',
): RunResult {
  const ctx: Ctx = {
    definition,
    params,
    locale,
    row: null,
    path: '',
    errors: [],
  }
  const lines: OutputLine[] = []
  for (let i = 0; i < definition.lines.length; i++) {
    const result = evalLine(definition.lines[i]!, ctx, i)
    if (ctx.errors.length) {
      return { lines: [], errors: ctx.errors }
    }
    if (result === 'skip') continue
    if (result === null) return { lines: [], errors: ctx.errors }
    lines.push(result)
  }
  return { lines, errors: [] }
}

export function previewTotals(lines: OutputLine[]): PreviewTotals {
  const byRate = new Map<string, { base: Dec; tax: Dec }>()
  let subtotal = Dec.zero()
  let taxTotal = Dec.zero()

  for (const line of lines) {
    const net = lineNet(line.quantity, line.unit_price, line.discount_pct)
    const tax = lineTax(net, line.tax_rate)
    subtotal = subtotal.add(net)
    taxTotal = taxTotal.add(tax)
    const key = line.tax_rate
    const prev = byRate.get(key) ?? { base: Dec.zero(), tax: Dec.zero() }
    byRate.set(key, { base: prev.base.add(net), tax: prev.tax.add(tax) })
  }

  const tax_breakdown = [...byRate.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([tax_rate, v]) => ({
      tax_rate,
      tax_base: v.base.toFixed(2),
      tax_amount: v.tax.toFixed(2),
    }))

  return {
    subtotal: subtotal.toFixed(2),
    tax_total: taxTotal.toFixed(2),
    total: subtotal.add(taxTotal).toFixed(2),
    tax_breakdown,
  }
}
