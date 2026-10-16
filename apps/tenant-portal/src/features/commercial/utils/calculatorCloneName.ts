import { nextUniqueNumberedName } from '@/lib/uniqueNumberedName'

/**
 * Nom únic per a una còpia de catàleg: Base, Base (2), Base (3), …
 * Només considera noms exactes (case-sensitive) de definicions no arxivades.
 */
export function nextCalculatorCloneName(
  baseName: string,
  existingNames: Iterable<string>,
): string {
  return nextUniqueNumberedName(baseName, existingNames, 'Calculadora')
}
