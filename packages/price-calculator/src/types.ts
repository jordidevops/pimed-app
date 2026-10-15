/** CF-29 schema_version 1 — tipus del motor. */

export type LocaleMap = { ca?: string; es?: string; en?: string }

export type Parameter = {
  key: string
  type: 'number' | 'integer' | 'money' | 'boolean' | 'enum'
  label: LocaleMap
  required?: boolean
  default?: number | string | boolean | null
  min?: number
  max?: number
  unit?: string
  options_from?: string
  help?: LocaleMap
}

export type Constant = {
  key: string
  type: 'number' | 'money'
  label?: LocaleMap
  value: number | null
  assumed?: boolean
}

export type TableRow = Record<string, number | string | boolean | null | LocaleMap> & {
  assumed?: boolean
}

export type LookupTable = {
  key: string
  lookup: 'exact' | 'tier'
  input: string
  match_column?: string
  bound_column?: string
  /** Explicació humana per columna (clau tècnica → textos). */
  column_help?: Record<string, LocaleMap>
  rows: TableRow[]
}

export type Expr =
  | { op: 'const'; value: number | string | boolean | null }
  | { op: 'param'; key: string }
  | { op: 'const_ref'; key: string }
  | { op: 'add' | 'mul' | 'min' | 'max'; args: Expr[] }
  | { op: 'sub' | 'div'; left: Expr; right: Expr }
  | { op: 'round'; value: Expr; decimals: 0 | 2 | 3; mode: 'half_away_from_zero' }
  | { op: 'if'; cond: Expr; then: Expr; else: Expr }
  | { op: 'cmp'; cmp: 'gt' | 'gte' | 'lt' | 'lte' | 'eq' | 'neq'; left: Expr; right: Expr }
  | { op: 'and' | 'or'; args: Expr[] }
  | { op: 'not'; arg: Expr }
  | { op: 'lookup_exact'; table: string; field: string }
  | { op: 'lookup_tier'; table: string; value: Expr }
  | { op: 'row'; field: string }
  | { op: 'coalesce'; args: Expr[] }

export type LineDef = {
  key: string
  name: LocaleMap
  description?: LocaleMap
  kind: 'product' | 'service'
  unit: string
  quantity: Expr
  unit_price: Expr
  discount_pct: Expr
  tax_rate: Expr
  when?: Expr
  allow_zero_price?: boolean
  /** A Previsualització/aplicar: qty i preu editables (fórmula = valor inicial). */
  prompt_qty_price?: boolean
  /** Cost unitari opcional (€); es persisteix a project_line_financials. */
  unit_cost?: number | null
}

export type Definition = {
  schema_version: 1
  parameters: Parameter[]
  constants?: Constant[]
  tables?: LookupTable[]
  lines: LineDef[]
}

export type OutputLine = {
  key: string
  kind: 'product' | 'service'
  name: string
  description: string | null
  unit: string
  quantity: string
  unit_price: string
  discount_pct: string
  tax_rate: string
  allow_zero_price: boolean
  /** Present només si la LineDef tenia unit_cost definit (string decimal). */
  unit_cost?: string | null
}

export type LineQtyPriceOverride = {
  quantity?: string
  unit_price?: string
}

export type LineOverrides = Record<string, LineQtyPriceOverride>

export type CalcErrorCode =
  | 'division_by_zero'
  | 'lookup_miss'
  | 'tariff_incomplete'
  | 'param_missing'
  | 'param_out_of_range'
  | 'type_error'
  | 'limit_exceeded'
  | 'zero_price_not_allowed'

export type CalcError = {
  code: CalcErrorCode
  path: string
}

export type RunResult = {
  lines: OutputLine[]
  errors: CalcError[]
}

export type TaxBreakdownRow = {
  tax_rate: string
  tax_base: string
  tax_amount: string
}

export type PreviewTotals = {
  subtotal: string
  tax_total: string
  total: string
  tax_breakdown: TaxBreakdownRow[]
}

export type ParamValues = Record<string, number | string | boolean | null | undefined>

export const LIMITS = {
  parameters: 30,
  constants: 30,
  tables: 10,
  rowsPerTable: 500,
  lines: 40,
  astDepth: 12,
  nodesPerExpr: 200,
} as const

export const KEY_RE = /^[a-z][a-z0-9_]{0,40}$/
