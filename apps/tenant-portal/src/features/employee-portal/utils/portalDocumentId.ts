/** Mirrors api.normalize_employee_document_id (trim, uppercase, alphanumeric only). */
export function normalizeEmployeeDocumentId(value?: string | null): string | null {
  const normalized = (value ?? '')
    .trim()
    .replace(/[^a-zA-Z0-9]/g, '')
    .toUpperCase()
  return normalized.length > 0 ? normalized : null
}

export function hasEmployeeDocumentId(value?: string | null): boolean {
  return normalizeEmployeeDocumentId(value) !== null
}

/** «Nom · DNI · URL» line for batch copy/export helpers. */
export function formatPortalAccessCopyLine(input: {
  employeeName: string
  employeeCode: string
  portalUrl: string
}): string {
  const name = input.employeeName.trim() || '—'
  const code = input.employeeCode.trim() || '—'
  return `${name} · ${code} · ${input.portalUrl}`
}
