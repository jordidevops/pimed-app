import type {
  CalcError,
  Definition,
  Expr,
  LineDef,
  LineOverrides,
  OutputLine,
} from './types.ts'

/** Desembolica round(...) fins al nucli. */
function unwrapRound(expr: Expr): Expr {
  let cur = expr
  while (cur.op === 'round') cur = cur.value
  return cur
}

function isConstNumber(expr: Expr, n: number): boolean {
  const core = unwrapRound(expr)
  return core.op === 'const' && core.value === n
}

/** Línia buida de l’editor: qty≈1 i preu≈0 com a const. */
export function isPlaceholderBlankLine(line: LineDef): boolean {
  return isConstNumber(line.quantity, 1) && isConstNumber(line.unit_price, 0)
}

/** Només el flag explícit (desmarcar = no demanar a Previsualització/aplicar). */
export function needsQtyPricePrompt(line: LineDef): boolean {
  return line.prompt_qty_price === true
}

/** Evita zero_price_not_allowed fins després dels overrides. */
export function shouldDeferZeroPriceCheck(line: LineDef): boolean {
  return needsQtyPricePrompt(line)
}

function parseDec(raw: string | undefined): number | null {
  if (raw == null || raw.trim() === '') return null
  const n = Number(String(raw).replace(',', '.'))
  return Number.isFinite(n) ? n : null
}

/**
 * Aplica overrides de qty/preu. Només línies amb prompt_qty_price.
 * Amb validate=true (defecte): errors si manca qty/preu o preu 0 no permès.
 * Amb validate=false: només fusiona (previsualització mentre s’edita).
 */
export function applyLineOverrides(
  lines: OutputLine[],
  overrides: LineOverrides | undefined,
  definition: Definition,
  opts?: { validate?: boolean },
): { lines: OutputLine[]; errors: CalcError[] } {
  const validate = opts?.validate !== false
  const errors: CalcError[] = []
  const byKey = new Map(definition.lines.map((l) => [l.key, l]))
  const next = lines.map((ol) => {
    const def = byKey.get(ol.key)
    if (!def || !needsQtyPricePrompt(def)) return ol
    const ov = overrides?.[ol.key]
    let quantity = ol.quantity
    let unit_price = ol.unit_price
    if (ov?.quantity != null && ov.quantity.trim() !== '') quantity = ov.quantity.trim()
    if (ov?.unit_price != null && ov.unit_price.trim() !== '') unit_price = ov.unit_price.trim()

    const qtyN = parseDec(quantity)
    const priceN = parseDec(unit_price)
    const path = `lines.${ol.key}`
    if (validate) {
      if (qtyN == null || qtyN <= 0) {
        errors.push({ code: 'param_out_of_range', path: `${path}.quantity` })
      }
      if (priceN == null) {
        errors.push({ code: 'param_missing', path: `${path}.unit_price` })
      } else if (priceN === 0 && !def.allow_zero_price && !ol.allow_zero_price) {
        errors.push({ code: 'zero_price_not_allowed', path: `${path}.unit_price` })
      }
    }

    const out: OutputLine = {
      ...ol,
      quantity: qtyN != null ? qtyN.toFixed(3) : quantity,
      unit_price: priceN != null ? priceN.toFixed(2) : unit_price,
    }
    return out
  })
  return { lines: next, errors }
}
