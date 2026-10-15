/**
 * Aritmètica decimal amb BigInt.
 * ROUND half away from zero = Postgres ROUND(numeric, scale).
 * No usar Math.round ni floats binaris per a diners.
 */

const INTERNAL_SCALE = 12n
const TEN = 10n

function pow10(n: bigint): bigint {
  let r = 1n
  for (let i = 0n; i < n; i++) r *= TEN
  return r
}

export class Dec {
  /** valor * 10^INTERNAL_SCALE */
  readonly n: bigint

  private constructor(n: bigint) {
    this.n = n
  }

  static zero(): Dec {
    return new Dec(0n)
  }

  static from(value: number | string | boolean | null | undefined): Dec {
    if (value === null || value === undefined) {
      throw new Error('null_decimal')
    }
    if (typeof value === 'boolean') {
      return new Dec(value ? pow10(INTERNAL_SCALE) : 0n)
    }
    if (typeof value === 'number') {
      if (!Number.isFinite(value)) throw new Error('non_finite')
      return Dec.from(String(value))
    }
    const s = value.trim()
    if (!s) throw new Error('empty_decimal')
    const neg = s.startsWith('-')
    const raw = neg ? s.slice(1) : s
    const [intPart, fracPart = ''] = raw.split('.')
    if (!/^\d+$/.test(intPart) || (fracPart && !/^\d+$/.test(fracPart))) {
      throw new Error('bad_decimal')
    }
    const frac = (fracPart + '0'.repeat(Number(INTERNAL_SCALE))).slice(0, Number(INTERNAL_SCALE))
    const units = BigInt(intPart) * pow10(INTERNAL_SCALE) + BigInt(frac || '0')
    return new Dec(neg ? -units : units)
  }

  add(o: Dec): Dec {
    return new Dec(this.n + o.n)
  }

  sub(o: Dec): Dec {
    return new Dec(this.n - o.n)
  }

  mul(o: Dec): Dec {
    // (a/S)*(b/S) = ab/S^2 → divide by S to return scale S
    return new Dec((this.n * o.n) / pow10(INTERNAL_SCALE))
  }

  div(o: Dec): Dec {
    if (o.n === 0n) throw new Error('division_by_zero')
    // (a/S)/(b/S) = a/b → multiply by S first
    return new Dec((this.n * pow10(INTERNAL_SCALE)) / o.n)
  }

  min(o: Dec): Dec {
    return this.n <= o.n ? this : o
  }

  max(o: Dec): Dec {
    return this.n >= o.n ? this : o
  }

  cmp(o: Dec): number {
    if (this.n < o.n) return -1
    if (this.n > o.n) return 1
    return 0
  }

  isZero(): boolean {
    return this.n === 0n
  }

  isNegative(): boolean {
    return this.n < 0n
  }

  /**
   * Postgres ROUND(numeric, scale): half away from zero.
   */
  round(decimals: 0 | 2 | 3): Dec {
    const d = BigInt(decimals)
    if (d > INTERNAL_SCALE) throw new Error('decimals_too_large')
    const factor = pow10(INTERNAL_SCALE - d)
    const half = factor / 2n
    let q: bigint
    if (this.n >= 0n) {
      q = (this.n + half) / factor
    } else {
      q = (this.n - half) / factor
    }
    return new Dec(q * factor)
  }

  toFixed(decimals: 0 | 2 | 3): string {
    const rounded = this.round(decimals)
    const neg = rounded.n < 0n
    const abs = neg ? -rounded.n : rounded.n
    const scalePow = pow10(INTERNAL_SCALE)
    const intPart = abs / scalePow
    const fracFull = abs % scalePow
    const fracStr = fracFull.toString().padStart(Number(INTERNAL_SCALE), '0').slice(0, decimals)
    const body = decimals === 0 ? intPart.toString() : `${intPart}.${fracStr}`
    return neg ? `-${body}` : body
  }

  toNumberApprox(): number {
    return Number(this.toFixed(3))
  }
}

/** data.line_net */
export function lineNet(qty: Dec | string, price: Dec | string, discountPct: Dec | string): Dec {
  const q = qty instanceof Dec ? qty : Dec.from(qty)
  const p = price instanceof Dec ? price : Dec.from(price)
  const d = discountPct instanceof Dec ? discountPct : Dec.from(discountPct)
  const one = Dec.from(1)
  const hundred = Dec.from(100)
  const factor = one.sub(d.div(hundred))
  return q.mul(p).mul(factor).round(2)
}

export function lineTax(net: Dec | string, taxRate: Dec | string): Dec {
  const n = net instanceof Dec ? net : Dec.from(net)
  const r = taxRate instanceof Dec ? taxRate : Dec.from(taxRate)
  return n.mul(r).div(Dec.from(100)).round(2)
}
