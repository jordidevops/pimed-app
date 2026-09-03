import { isAutoInjectedLiquidRef } from '../../constants/entityFieldCatalog'

/** Extreu referències Liquid {{ ... }} del contingut (sense camps *-field). */
export function extractLiquidReferences(content: string): string[] {
  const stripped = content
    .replace(/<[a-z]+-field\b[^>]*>[\s\S]*?<\/[a-z]+-field>/gi, '')
    .replace(/<[a-z]+-field\b[^>]*\/>/gi, '')
  const refs = [...stripped.matchAll(/\{\{\s*([\w.]+)\s*\}\}/g)].map(m => m[1])
  return [...new Set(refs)]
}

export function isGlobalLiquidRef(ref: string): boolean {
  return isAutoInjectedLiquidRef(ref)
}

export function isPathBasedRef(ref: string): boolean {
  return ref.includes('.')
}
