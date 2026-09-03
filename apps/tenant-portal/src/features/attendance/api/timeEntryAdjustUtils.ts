/** Converteix minuts totals a hores + minuts (sempre positius en UI). */
export function splitMinutes(total: number | null | undefined): { hours: number; minutes: number } {
  const abs = Math.max(0, Math.round(total ?? 0))
  return { hours: Math.floor(abs / 60), minutes: abs % 60 }
}

/** Converteix hores i minuts a minuts totals. */
export function combineHm(hours: number, minutes: number): number {
  const h = Math.max(0, Math.floor(hours))
  const m = Math.max(0, Math.min(59, Math.floor(minutes)))
  return h * 60 + m
}
