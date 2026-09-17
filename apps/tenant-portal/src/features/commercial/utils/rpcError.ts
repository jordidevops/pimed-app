const COMMERCIAL_TEMPLATE_LEGAL_GAPS_PREFIX = 'commercial_template_legal_gaps:'

export function rpcErrorMessage(err: unknown): string {
  if (err instanceof Error && err.message.trim()) return err.message
  if (typeof err === 'object' && err !== null && 'message' in err) {
    const message = (err as { message?: unknown }).message
    if (typeof message === 'string' && message.trim()) return message
  }
  return ''
}

export function isCommercialPricingPermissionDenied(err: unknown): boolean {
  return rpcErrorMessage(err).includes('permission_denied:commercial.pricing.edit')
}

export function parseCommercialTemplateLegalGaps(err: unknown): string[] | null {
  const message = rpcErrorMessage(err)
  const idx = message.indexOf(COMMERCIAL_TEMPLATE_LEGAL_GAPS_PREFIX)
  if (idx === -1) return null
  const rest = message.slice(idx + COMMERCIAL_TEMPLATE_LEGAL_GAPS_PREFIX.length).trim()
  if (!rest) return []
  return rest.split(',').map((token) => token.trim()).filter(Boolean)
}
