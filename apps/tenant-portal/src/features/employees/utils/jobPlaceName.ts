/** Resolve display name for an employee's lloc de treball from a positions map. */
export function jobPlaceName(
  jobPositionId: string | null | undefined,
  positionsById: Record<string, { name?: string | null }>,
): string | undefined {
  if (!jobPositionId) return undefined
  const name = positionsById[jobPositionId]?.name
  const trimmed = name?.trim()
  return trimmed || undefined
}
