import { Liquid } from 'liquidjs'

const validationEngine = new Liquid({ strictVariables: false, strictFilters: false })

// Legacy blocks no longer supported after clean rewrite cutover.
export const LEGACY_TEMPLATE_BLOCKS_PATTERN = /\{\{#(if|unless)\b|\{\{\/(if|unless)\}\}/i

export function hasLegacyTemplateBlocks(template: string): boolean {
  return LEGACY_TEMPLATE_BLOCKS_PATTERN.test(template)
}

export function getLiquidTemplateSyntaxError(template: string): string | null {
  try {
    validationEngine.parse(template)
    return null
  } catch (err) {
    return err instanceof Error ? err.message : String(err)
  }
}
