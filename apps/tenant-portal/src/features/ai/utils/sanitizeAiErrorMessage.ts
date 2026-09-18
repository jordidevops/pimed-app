const UUID_RE =
  /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi

export function stripTenantIdsFromMessage(message: string): string {
  return message
    .replace(UUID_RE, '')
    .replace(/\s{2,}/g, ' ')
    .replace(/\s+([.,;:])/g, '$1')
    .trim()
}

export function sanitizeAiErrorMessage(raw: string): string {
  if (/No AI config enabled/i.test(raw)) {
    return 'La IA no està activada. Configura una clau verificada a Configuració > IA.'
  }
  if (
    /AI API key for provider .+ is not verified/i.test(raw) ||
    (/is not verified/i.test(raw) && /AI API key/i.test(raw))
  ) {
    return "La clau d'API d'aquest proveïdor no està verificada."
  }
  if (/No AI API key configured for provider/i.test(raw)) {
    return "No hi ha cap clau d'API configurada per a aquest proveïdor."
  }
  if (/AI API key not found in vault/i.test(raw)) {
    return "No s'ha trobat la clau d'API."
  }
  return stripTenantIdsFromMessage(raw)
}
