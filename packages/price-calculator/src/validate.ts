import { KEY_RE, LIMITS, type Definition, type Expr } from './types.ts'

export type ValidationIssue = {
  path: string
  message: string
}

function endsWithRound(expr: Expr, decimals: 2 | 3): boolean {
  if (expr.op === 'round' && expr.decimals === decimals && expr.mode === 'half_away_from_zero') {
    return true
  }
  if (expr.op === 'if') {
    return endsWithRound(expr.then, decimals) && endsWithRound(expr.else, decimals)
  }
  // lookup_tier.value pot ser l'expressió arrodonida (exemple electricista)
  if (expr.op === 'lookup_tier') {
    return endsWithRound(expr.value, decimals)
  }
  return false
}

function walkExpr(
  expr: Expr,
  path: string,
  depth: number,
  nodes: { n: number },
  issues: ValidationIssue[],
  allowRow: boolean,
): void {
  nodes.n += 1
  if (nodes.n > LIMITS.nodesPerExpr) {
    issues.push({ path, message: 'limit_exceeded:nodes' })
    return
  }
  if (depth > LIMITS.astDepth) {
    issues.push({ path, message: 'limit_exceeded:depth' })
    return
  }
  if (!expr || typeof expr !== 'object' || !('op' in expr)) {
    issues.push({ path, message: 'invalid_expr' })
    return
  }
  // Reject unknown keys beyond known ones per op — strict-ish
  const known = new Set(['op'])
  switch (expr.op) {
    case 'const':
      known.add('value')
      break
    case 'param':
    case 'const_ref':
      known.add('key')
      break
    case 'add':
    case 'mul':
    case 'min':
    case 'max':
    case 'and':
    case 'or':
    case 'coalesce':
      known.add('args')
      if (!Array.isArray(expr.args) || expr.args.length < 2) {
        issues.push({ path, message: 'args_min_2' })
      } else {
        expr.args.forEach((a, i) => walkExpr(a, `${path}.args[${i}]`, depth + 1, nodes, issues, allowRow))
      }
      break
    case 'sub':
    case 'div':
      known.add('left')
      known.add('right')
      walkExpr(expr.left, `${path}.left`, depth + 1, nodes, issues, allowRow)
      walkExpr(expr.right, `${path}.right`, depth + 1, nodes, issues, allowRow)
      break
    case 'round':
      known.add('value')
      known.add('decimals')
      known.add('mode')
      if (expr.mode !== 'half_away_from_zero') {
        issues.push({ path, message: 'bad_round_mode' })
      }
      if (![0, 2, 3].includes(expr.decimals)) {
        issues.push({ path, message: 'bad_decimals' })
      }
      walkExpr(expr.value, `${path}.value`, depth + 1, nodes, issues, allowRow)
      break
    case 'if':
      known.add('cond')
      known.add('then')
      known.add('else')
      walkExpr(expr.cond, `${path}.cond`, depth + 1, nodes, issues, allowRow)
      walkExpr(expr.then, `${path}.then`, depth + 1, nodes, issues, allowRow)
      walkExpr(expr.else, `${path}.else`, depth + 1, nodes, issues, allowRow)
      break
    case 'cmp':
      known.add('cmp')
      known.add('left')
      known.add('right')
      walkExpr(expr.left, `${path}.left`, depth + 1, nodes, issues, allowRow)
      walkExpr(expr.right, `${path}.right`, depth + 1, nodes, issues, allowRow)
      break
    case 'not':
      known.add('arg')
      walkExpr(expr.arg, `${path}.arg`, depth + 1, nodes, issues, allowRow)
      break
    case 'lookup_exact':
      known.add('table')
      known.add('field')
      break
    case 'lookup_tier':
      known.add('table')
      known.add('value')
      walkExpr(expr.value, `${path}.value`, depth + 1, nodes, issues, true)
      break
    case 'row':
      known.add('field')
      if (!allowRow) {
        issues.push({ path, message: 'row_outside_lookup_tier' })
      }
      break
    default:
      issues.push({ path, message: `unknown_op:${(expr as { op: string }).op}` })
      return
  }
  for (const key of Object.keys(expr)) {
    if (!known.has(key)) {
      issues.push({ path: `${path}.${key}`, message: `unknown_key:${key}` })
    }
  }
}

export function validateDefinition(raw: unknown): {
  ok: boolean
  definition?: Definition
  issues: ValidationIssue[]
} {
  const issues: ValidationIssue[] = []
  if (!raw || typeof raw !== 'object') {
    return { ok: false, issues: [{ path: '', message: 'not_object' }] }
  }
  const def = raw as Definition
  if (def.schema_version !== 1) {
    issues.push({ path: 'schema_version', message: 'must_be_1' })
  }
  const parameters = Array.isArray(def.parameters) ? def.parameters : null
  const constants = Array.isArray(def.constants) ? def.constants : def.constants == null ? [] : null
  const tables = Array.isArray(def.tables) ? def.tables : def.tables == null ? [] : null
  const lines = Array.isArray(def.lines) ? def.lines : null

  if (!parameters || parameters.length > LIMITS.parameters) {
    issues.push({ path: 'parameters', message: 'limit_or_missing' })
  }
  if (constants == null) {
    issues.push({ path: 'constants', message: 'not_array' })
  } else if (constants.length > LIMITS.constants) {
    issues.push({ path: 'constants', message: 'limit_exceeded' })
  }
  if (tables == null) {
    issues.push({ path: 'tables', message: 'not_array' })
  } else if (tables.length > LIMITS.tables) {
    issues.push({ path: 'tables', message: 'limit_exceeded' })
  }
  if (!lines || lines.length === 0 || lines.length > LIMITS.lines) {
    issues.push({ path: 'lines', message: 'limit_or_missing' })
  }

  for (const p of parameters ?? []) {
    if (!KEY_RE.test(p.key)) issues.push({ path: `parameters.${p.key}`, message: 'bad_key' })
  }
  for (const c of constants ?? []) {
    if (!KEY_RE.test(c.key)) issues.push({ path: `constants.${c.key}`, message: 'bad_key' })
  }
  for (const t of tables ?? []) {
    if (!KEY_RE.test(t.key)) issues.push({ path: `tables.${t.key}`, message: 'bad_key' })
    if (!Array.isArray(t.rows)) {
      issues.push({ path: `tables.${t.key}.rows`, message: 'not_array' })
    } else if (t.rows.length > LIMITS.rowsPerTable) {
      issues.push({ path: `tables.${t.key}`, message: 'rows_limit' })
    }
  }

  for (let i = 0; i < (lines?.length ?? 0); i++) {
    const line = lines![i]!
    if (!KEY_RE.test(line.key)) {
      issues.push({ path: `lines[${i}].key`, message: 'bad_key' })
    }
    if (line.kind !== 'product' && line.kind !== 'service') {
      issues.push({ path: `lines[${i}].kind`, message: 'bad_kind' })
    }
    if (!endsWithRound(line.quantity, 3)) {
      issues.push({ path: `lines[${i}].quantity`, message: 'must_end_round_3' })
    }
    if (!endsWithRound(line.unit_price, 2)) {
      issues.push({ path: `lines[${i}].unit_price`, message: 'must_end_round_2' })
    }
    const nodes = { n: 0 }
    walkExpr(line.quantity, `lines[${i}].quantity`, 0, nodes, issues, false)
    const nodesP = { n: 0 }
    walkExpr(line.unit_price, `lines[${i}].unit_price`, 0, nodesP, issues, false)
    const nodesD = { n: 0 }
    walkExpr(line.discount_pct, `lines[${i}].discount_pct`, 0, nodesD, issues, false)
    const nodesT = { n: 0 }
    walkExpr(line.tax_rate, `lines[${i}].tax_rate`, 0, nodesT, issues, false)
    if (line.when) {
      const nodesW = { n: 0 }
      walkExpr(line.when, `lines[${i}].when`, 0, nodesW, issues, false)
    }
  }

  // Reject top-level unknown keys
  const topKnown = new Set(['schema_version', 'parameters', 'constants', 'tables', 'lines'])
  for (const key of Object.keys(def)) {
    if (!topKnown.has(key)) {
      issues.push({ path: key, message: `unknown_key:${key}` })
    }
  }
  if ('eval' in (def as object)) {
    issues.push({ path: 'eval', message: 'forbidden' })
  }

  return {
    ok: issues.length === 0,
    definition: issues.length === 0 ? def : undefined,
    issues,
  }
}

/** Porta d'activació (D11/D12): forats i assumed. */
export function activationGaps(definition: Definition): ValidationIssue[] {
  const issues: ValidationIssue[] = []
  for (const c of definition.constants ?? []) {
    if (c.value === null || c.assumed) {
      issues.push({ path: `constants.${c.key}`, message: 'incomplete' })
    }
  }
  for (const t of definition.tables ?? []) {
    if (!Array.isArray(t.rows)) continue
    // Tram obert (últim tier): bound_column = null és intencional, no un forat.
    const openBoundKey = t.lookup === 'tier' && t.bound_column ? t.bound_column : null
    for (let i = 0; i < t.rows.length; i++) {
      const row = t.rows[i]!
      if (row.assumed) {
        issues.push({ path: `tables.${t.key}[${i}]`, message: 'assumed' })
      }
      for (const [k, v] of Object.entries(row)) {
        if (k === 'id' || k === 'label' || k === 'assumed') continue
        if (openBoundKey && k === openBoundKey) continue
        if (v === null) {
          issues.push({ path: `tables.${t.key}[${i}].${k}`, message: 'incomplete' })
        }
      }
    }
  }
  return issues
}
