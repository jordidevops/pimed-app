/** CF-19: PVP is euros; private cost is integer cents. Keep conversions explicit. */

export function eurosToCents(raw: string | number): number | null {
  if (typeof raw === 'string' && raw.trim() === '') return null
  const n = typeof raw === 'number' ? raw : Number(String(raw).trim().replace(',', '.'))
  if (!Number.isFinite(n) || n < 0) return null
  return Math.round(n * 100)
}

export function centsToEuros(cents: number | null | undefined): string {
  if (cents == null) return ''
  return (cents / 100).toFixed(2)
}

export function marginBpsToPercent(bps: number | null | undefined): string {
  if (bps == null) return ''
  return (bps / 100).toFixed(2)
}

export function percentToMarginBps(raw: string | number): number | null {
  const n = typeof raw === 'number' ? raw : Number(String(raw).trim().replace(',', '.'))
  if (!Number.isFinite(n) || n < 0 || n > 99) return null
  return Math.round(n * 100)
}

/** Margin on sale: pvp = cost / (1 - bps/10000). Twin of data.suggest_pvp_euros_from_cost. */
export function suggestPvpEurosFromCost(
  costCents: number,
  marginBps: number,
): number | null {
  if (!Number.isFinite(costCents) || costCents < 0) return null
  if (!Number.isFinite(marginBps) || marginBps < 0 || marginBps >= 10000) return null
  return Math.round((costCents / 100 / (1 - marginBps / 10000)) * 10000) / 10000
}
