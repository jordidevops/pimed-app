import type { CalcError, Definition, Expr, LineDef } from '@pimed/price-calculator'
import { resolveLocale } from '@pimed/price-calculator'

function lineAtPath(definition: Definition, path: string): { line: LineDef; index: number } | null {
  const byIndex = /^lines\[(\d+)\]/.exec(path)
  if (byIndex) {
    const index = Number(byIndex[1])
    const line = definition.lines[index]
    if (!line) return null
    return { line, index }
  }
  const byKey = /^lines\.([^.]+)/.exec(path)
  if (byKey) {
    const key = byKey[1]!
    const index = definition.lines.findIndex((l) => l.key === key)
    if (index < 0) return null
    return { line: definition.lines[index]!, index }
  }
  return null
}

function lineTitle(definition: Definition, path: string, locale: string): string {
  const hit = lineAtPath(definition, path)
  if (!hit) return path
  const name = resolveLocale(hit.line.name, locale) || hit.line.key
  return name
}

/** Detecta el placeholder de «línia buida» (round(const 0)). */
function isPlaceholderZeroPrice(expr: Expr): boolean {
  if (expr.op === 'round') return isPlaceholderZeroPrice(expr.value)
  return expr.op === 'const' && (expr.value === 0 || expr.value === null)
}

function isPlaceholderQuantity(expr: Expr): boolean {
  if (expr.op === 'round') return isPlaceholderQuantity(expr.value)
  return expr.op === 'const' && expr.value === 1
}

function fieldHint(path: string): 'quantity' | 'unit_price' | 'discount_pct' | 'tax_rate' | 'when' | null {
  if (path.endsWith('.quantity')) return 'quantity'
  if (path.endsWith('.unit_price')) return 'unit_price'
  if (path.endsWith('.discount_pct')) return 'discount_pct'
  if (path.endsWith('.tax_rate')) return 'tax_rate'
  if (path.endsWith('.when')) return 'when'
  return null
}

/** Missatge llegible per errors del motor (previsualització i ús). */
export function formatCalcError(
  definition: Definition,
  error: CalcError,
  locale = 'ca',
): string {
  const title = lineTitle(definition, error.path, locale)
  const hit = lineAtPath(definition, error.path)
  const field = fieldHint(error.path)

  switch (error.code) {
    case 'zero_price_not_allowed': {
      const blankish =
        hit &&
        isPlaceholderZeroPrice(hit.line.unit_price) &&
        isPlaceholderQuantity(hit.line.quantity)
      if (blankish) {
        return `La línia «${title}» encara no té expressió de càlcul: defineix la quantitat i el preu unitari (assistent, IA o Avançat), o marca «permet preu 0» si el zero és intencional.`
      }
      return `La línia «${title}» té preu unitari 0. Omple l’expressió de preu o marca «permet preu 0» si és correcte.`
    }
    case 'tariff_incomplete':
      return `Falta una tarifa a «${error.path.replace(/^table\./, '')}». Omple el valor a Constants o Taules.`
    case 'lookup_miss':
      return `No s’ha trobat fila a la taula per als paràmetres actuals (${error.path}). Revisa el valor d’entrada o les files.`
    case 'param_missing':
      return `Falta el paràmetre «${error.path.replace(/^param\./, '')}».`
    case 'param_out_of_range':
      if (field === 'discount_pct') {
        return `La línia «${title}»: el descompte ha d’estar entre 0 i 100.`
      }
      if (field === 'tax_rate') {
        return `La línia «${title}»: l’IVA ha d’estar entre 0 i 100.`
      }
      return `Valor fora de rang a «${title}» (${error.path}).`
    case 'division_by_zero':
      return `Divisió per zero a la línia «${title}». Revisa l’expressió.`
    case 'type_error':
      return `Tipus incorrecte a la línia «${title}» (${error.path}).`
    case 'limit_exceeded':
      return `S’ha excedit un límit del motor (${error.path}).`
    default:
      return `${error.code} (${title})`
  }
}

export function formatCalcErrorList(
  definition: Definition,
  errors: CalcError[],
  locale = 'ca',
): string {
  return errors.map((e) => formatCalcError(definition, e, locale)).join(' · ')
}
