import type { Expr, Parameter } from '@pimed/price-calculator'

export type WhenMode = 'always' | 'never' | 'bool_param' | 'complex'

export function readWhenMode(
  when: Expr | undefined,
  booleanParams: Parameter[],
): { mode: WhenMode; paramKey?: string } {
  if (!when) return { mode: 'always' }
  if (when.op === 'const' && when.value === true) return { mode: 'always' }
  if (when.op === 'const' && when.value === false) return { mode: 'never' }
  if (when.op === 'param') {
    const ok = booleanParams.some((p) => p.key === when.key)
    if (ok) return { mode: 'bool_param', paramKey: when.key }
  }
  if (
    when.op === 'cmp' &&
    when.cmp === 'eq' &&
    when.left.op === 'param' &&
    when.right.op === 'const' &&
    when.right.value === true
  ) {
    const key = when.left.key
    if (booleanParams.some((p) => p.key === key)) {
      return { mode: 'bool_param', paramKey: key }
    }
  }
  return { mode: 'complex' }
}

export function writeWhenMode(
  mode: WhenMode,
  paramKey?: string,
): Expr | undefined {
  if (mode === 'always') return undefined
  if (mode === 'never') return { op: 'const', value: false }
  if (mode === 'bool_param' && paramKey) {
    return { op: 'param', key: paramKey }
  }
  return undefined
}
