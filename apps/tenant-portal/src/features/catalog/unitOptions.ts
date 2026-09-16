/** Shared catalog / project-line unit presets and quantity chips (CF-0). */

export const UNIT_OPTIONS = ['u', 'h', 'km', 'm2', 'm', 'kg', 'visita', 'dia', 'm3'] as const

export type UnitOption = (typeof UNIT_OPTIONS)[number]

/** Quantity chips by unit — prices come from catalog / tenant, not hardcoded. */
export const QUANTITY_CHIPS_BY_UNIT: Record<string, number[]> = {
  h: [1, 1.5, 2, 2.5, 3, 3.5, 4, 6, 8],
  km: [5, 10, 15, 20, 30, 50],
  visita: [1, 2, 3],
}

/** Discount chips (%); only shown when caller has commercial permission. */
export const DISCOUNT_CHIPS = [0, 5, 10, 15, 20] as const

/** Ensure current unit appears in the select even if not in the preset list. */
export function unitSelectOptions(current?: string | null): string[] {
  const base = [...UNIT_OPTIONS]
  if (current && !base.includes(current as UnitOption)) {
    return [current, ...base]
  }
  return base
}

export function quantityChipsForUnit(unit?: string | null): number[] {
  if (!unit) return []
  return QUANTITY_CHIPS_BY_UNIT[unit] ?? []
}

export function formatQuantityChip(value: number): string {
  return Number.isInteger(value) ? String(value) : String(value).replace('.', ',')
}
