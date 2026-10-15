import type { Definition, Expr, LocaleMap } from '@pimed/price-calculator'
import { resolveLocale } from '@pimed/price-calculator'

type Locale = 'ca' | 'es' | 'en'

function labelOf(map: LocaleMap | undefined, key: string, locale: Locale): string {
  return resolveLocale(map, locale) || key
}

function paramLabel(def: Definition, key: string, locale: Locale): string {
  const p = def.parameters.find((x) => x.key === key)
  return p ? labelOf(p.label, key, locale) : key
}

function constLabel(def: Definition, key: string, locale: Locale): string {
  const c = (def.constants ?? []).find((x) => x.key === key)
  return c ? labelOf(c.label, key, locale) : key
}

function tableLabel(def: Definition, key: string): string {
  return key
}

function columnHelp(def: Definition, tableKey: string, field: string, locale: Locale): string {
  const t = (def.tables ?? []).find((x) => x.key === tableKey)
  const help = t?.column_help?.[field]
  if (help) return labelOf(help, field, locale)
  return field
}

function needsParens(child: Expr, parentOp: string): boolean {
  if (child.op === 'const' || child.op === 'param' || child.op === 'const_ref') return false
  if (child.op === 'round' || child.op === 'lookup_exact' || child.op === 'lookup_tier' || child.op === 'row')
    return false
  if (parentOp === 'mul' || parentOp === 'div') {
    return child.op === 'add' || child.op === 'sub' || child.op === 'if' || child.op === 'coalesce'
  }
  return child.op === 'add' || child.op === 'sub' || child.op === 'mul' || child.op === 'div'
}

function wrap(child: Expr, parentOp: string, def: Definition, locale: Locale): string {
  const s = formatCalculatorExpr(child, def, locale)
  return needsParens(child, parentOp) ? `(${s})` : s
}

/** Textte humà d’una expressió AST (etiquetes de param/const/taula). */
export function formatCalculatorExpr(
  expr: Expr,
  def: Definition,
  locale: Locale = 'ca',
): string {
  switch (expr.op) {
    case 'const': {
      if (typeof expr.value === 'boolean') return expr.value ? 'sí' : 'no'
      if (expr.value === null) return '—'
      return String(expr.value)
    }
    case 'param':
      return paramLabel(def, expr.key, locale)
    case 'const_ref':
      return constLabel(def, expr.key, locale)
    case 'round':
      return formatCalculatorExpr(expr.value, def, locale)
    case 'add':
      return expr.args.map((a) => wrap(a, 'add', def, locale)).join(' + ')
    case 'mul':
      return expr.args.map((a) => wrap(a, 'mul', def, locale)).join(' × ')
    case 'sub':
      return `${wrap(expr.left, 'sub', def, locale)} − ${wrap(expr.right, 'sub', def, locale)}`
    case 'div':
      return `${wrap(expr.left, 'div', def, locale)} ÷ ${wrap(expr.right, 'div', def, locale)}`
    case 'min':
      return `mín(${expr.args.map((a) => formatCalculatorExpr(a, def, locale)).join(', ')})`
    case 'max':
      return `màx(${expr.args.map((a) => formatCalculatorExpr(a, def, locale)).join(', ')})`
    case 'coalesce':
      return expr.args.map((a) => formatCalculatorExpr(a, def, locale)).join(' o si no ')
    case 'if':
      return `si ${formatCalculatorExpr(expr.cond, def, locale)} → ${formatCalculatorExpr(expr.then, def, locale)} / sinó ${formatCalculatorExpr(expr.else, def, locale)}`
    case 'cmp': {
      const sym: Record<string, string> = {
        gt: '>',
        gte: '≥',
        lt: '<',
        lte: '≤',
        eq: '=',
        neq: '≠',
      }
      return `${formatCalculatorExpr(expr.left, def, locale)} ${sym[expr.cmp] ?? expr.cmp} ${formatCalculatorExpr(expr.right, def, locale)}`
    }
    case 'and':
      return expr.args.map((a) => formatCalculatorExpr(a, def, locale)).join(' i ')
    case 'or':
      return expr.args.map((a) => formatCalculatorExpr(a, def, locale)).join(' o ')
    case 'not':
      return `no (${formatCalculatorExpr(expr.arg, def, locale)})`
    case 'lookup_exact': {
      const t = (def.tables ?? []).find((x) => x.key === expr.table)
      const input = t ? paramLabel(def, t.input, locale) : '?'
      const field = columnHelp(def, expr.table, expr.field, locale)
      return `${field} de la taula «${tableLabel(def, expr.table)}» pel paràmetre ${input}`
    }
    case 'lookup_tier': {
      const t = (def.tables ?? []).find((x) => x.key === expr.table)
      const input = t ? paramLabel(def, t.input, locale) : '?'
      if (expr.value.op === 'row') {
        const field = columnHelp(def, expr.table, expr.value.field, locale)
        return `${field} de la taula «${tableLabel(def, expr.table)}» pel paràmetre ${input}`
      }
      return `${formatCalculatorExpr(expr.value, def, locale)} de la taula «${tableLabel(def, expr.table)}» pel paràmetre ${input}`
    }
    case 'row':
      return expr.field
    default:
      return '?'
  }
}

export type LineFormulaSummary = {
  quantity: string
  unitPrice: string
  /** «qty × preu» en una sola línia. */
  product: string
}

export function formatLineFormula(
  quantity: Expr,
  unitPrice: Expr,
  def: Definition,
  locale: Locale = 'ca',
): LineFormulaSummary {
  const q = formatCalculatorExpr(quantity, def, locale)
  const p = formatCalculatorExpr(unitPrice, def, locale)
  return { quantity: q, unitPrice: p, product: `${q} × ${p}` }
}
