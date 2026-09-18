const COMMERCIAL_TEMPLATE_LEGAL_GAPS_PREFIX = 'commercial_template_legal_gaps:'

export type PriceSheetRpcErrorKind =
  | 'pricing_permission'
  | 'quote_in_progress'
  | 'lines_immutable'
  | 'waiver_blocked'
  | 'unknown'

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

export function classifyPriceSheetRpcError(err: unknown): PriceSheetRpcErrorKind {
  const message = rpcErrorMessage(err)
  if (message.includes('permission_denied:commercial.pricing.edit')) {
    return 'pricing_permission'
  }
  if (message.includes('price_sheet_locked:quote_in_progress')) {
    return 'quote_in_progress'
  }
  if (message.includes('commercial_document_lines_immutable')) {
    return 'lines_immutable'
  }
  if (message.includes('waiver_blocked:quote_active')) {
    return 'waiver_blocked'
  }
  return 'unknown'
}

/** i18n keys for price-sheet RPC failures (two-arg t). */
export function priceSheetRpcErrorCopy(
  err: unknown,
  priceSheetTitle?: string,
): {
  titleKey: string
  titleFallback: string
  descriptionKey: string
  descriptionFallback: string
  rawMessage: string
  preferFallbackTitle: boolean
} {
  const kind = classifyPriceSheetRpcError(err)
  const rawMessage = rpcErrorMessage(err)
  const sheet = priceSheetTitle?.trim() || 'Full de preus'
  const lockedTitle = `${sheet} bloquejat`
  switch (kind) {
    case 'pricing_permission':
      return {
        titleKey: 'projects.lines.errors.pricing_denied_title',
        titleFallback: 'No es pot canviar el preu',
        descriptionKey: 'projects.lines.errors.pricing_denied_help',
        descriptionFallback:
          'Cal el permís «Editar preus, descompte i IVA», o tria un ítem del catàleg sense canviar el PVP.',
        rawMessage,
        preferFallbackTitle: false,
      }
    case 'quote_in_progress':
      return {
        titleKey: 'projects.lines.errors.quote_locked_title',
        titleFallback: lockedTitle,
        descriptionKey: 'projects.lines.errors.quote_locked_help',
        descriptionFallback:
          'Hi ha un pressupost o una ampliació emesos. Descarta’ls o espera la resposta del client abans de modificar el full.',
        rawMessage,
        preferFallbackTitle: Boolean(priceSheetTitle?.trim()),
      }
    case 'lines_immutable':
      return {
        titleKey: 'projects.lines.errors.immutable_title',
        titleFallback: 'No es pot modificar aquesta línia',
        descriptionKey: 'projects.lines.errors.immutable_help',
        descriptionFallback:
          'La línia forma part d’un document comercial ja emès i no es pot canviar.',
        rawMessage,
        preferFallbackTitle: false,
      }
    case 'waiver_blocked':
      return {
        titleKey: 'projects.commercial.waiver_blocked_title',
        titleFallback: 'No es pot registrar la renúncia',
        descriptionKey: 'projects.commercial.waiver_blocked_help',
        descriptionFallback:
          'Hi ha un pressupost o una ampliació actius. Descarta’ls o espera abans de treballar sense pressupost.',
        rawMessage,
        preferFallbackTitle: false,
      }
    default:
      return {
        titleKey: 'projects.lines.errors.generic_title',
        titleFallback: 'No s’ha pogut desar',
        descriptionKey: 'projects.lines.errors.generic_help',
        descriptionFallback: 'Torna-ho a provar. Si continua, contacta amb l’oficina.',
        rawMessage,
        preferFallbackTitle: false,
      }
  }
}

export function priceSheetRpcErrorTitle(
  t: (key: string, fallback: string) => string,
  copy: ReturnType<typeof priceSheetRpcErrorCopy>,
): string {
  return copy.preferFallbackTitle ? copy.titleFallback : t(copy.titleKey, copy.titleFallback)
}

export function parseCommercialTemplateLegalGaps(err: unknown): string[] | null {
  const message = rpcErrorMessage(err)
  const idx = message.indexOf(COMMERCIAL_TEMPLATE_LEGAL_GAPS_PREFIX)
  if (idx === -1) return null
  const rest = message.slice(idx + COMMERCIAL_TEMPLATE_LEGAL_GAPS_PREFIX.length).trim()
  if (!rest) return []
  return rest.split(',').map((token) => token.trim()).filter(Boolean)
}
