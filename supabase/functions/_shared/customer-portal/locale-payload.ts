/** Locale entitlement fields returned by customer_portal_locale_fields RPCs. */
export function pickLocalePayload(row: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  if (typeof row.preferred_locale === "string" || row.preferred_locale === null) {
    out.preferred_locale = row.preferred_locale
  }
  if (row.supported_locales !== undefined) {
    out.supported_locales = row.supported_locales
  }
  if (typeof row.default_locale === "string" || row.default_locale === null) {
    out.default_locale = row.default_locale
  }
  if (typeof row.allow_client_locale_change === "boolean") {
    out.allow_client_locale_change = row.allow_client_locale_change
  }
  if (typeof row.content_locale === "string" || row.content_locale === null) {
    out.content_locale = row.content_locale
  }
  if (row.tenant_profile && typeof row.tenant_profile === "object") {
    out.tenant_profile = row.tenant_profile
  }
  return out
}
