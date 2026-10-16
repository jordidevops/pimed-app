/**
 * Nom únic amb sufix numèric: Base, Base (2), Base (3), …
 * Comparació exacta (case-sensitive) després de trim.
 */
export function nextUniqueNumberedName(
  baseName: string,
  existingNames: Iterable<string>,
  emptyFallback = 'Còpia',
): string {
  const base = baseName.trim() || emptyFallback
  const taken = new Set(
    [...existingNames].map((n) => n.trim()).filter(Boolean),
  )
  if (!taken.has(base)) return base
  let n = 2
  while (taken.has(`${base} (${n})`)) n += 1
  return `${base} (${n})`
}
