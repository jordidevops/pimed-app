export interface PortalLabelExportRow {
  employeeName: string
  employeeCode: string
  portalUrl: string
  label: string
}

export const PORTAL_LABEL_CSV_HEADERS = [
  'employee_name',
  'employee_code',
  'portal_url',
  'qr_payload',
  'label',
] as const

/** Delimiter per Excel ca/ES (regional settings amb punt i coma). */
export const PORTAL_LABEL_CSV_DELIMITER = ';'

export function escapePortalLabelCsvCell(value: string): string {
  return `"${String(value).replace(/"/g, '""')}"`
}

export function buildPortalLabelCsv(
  rows: PortalLabelExportRow[],
  delimiter: string = PORTAL_LABEL_CSV_DELIMITER,
): string {
  const headerLine = PORTAL_LABEL_CSV_HEADERS.map(escapePortalLabelCsvCell).join(delimiter)
  const dataLines = rows.map((row) =>
    [
      escapePortalLabelCsvCell(row.employeeName),
      escapePortalLabelCsvCell(row.employeeCode),
      escapePortalLabelCsvCell(row.portalUrl),
      escapePortalLabelCsvCell(row.portalUrl),
      escapePortalLabelCsvCell(row.label),
    ].join(delimiter),
  )

  return [headerLine, ...dataLines].join('\r\n')
}

function slugifyFilenamePart(value: string): string {
  const trimmed = value.trim().replace(/\s+/g, '-').slice(0, 40)
  return trimmed || 'empleat'
}

export function buildPortalLabelExportFilename(row: PortalLabelExportRow): string {
  return `portal-qr_${slugifyFilenamePart(row.employeeName)}.csv`
}

export function buildPortalBatchExportFilename(date = new Date()): string {
  const stamp = date.toISOString().slice(0, 10)
  return `portal-qr_batch_${stamp}.csv`
}

function triggerDownload(blob: Blob, filename: string): void {
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = filename
  anchor.click()
  URL.revokeObjectURL(url)
}

export function downloadPortalLabelCsv(
  rows: PortalLabelExportRow[],
  filename?: string,
): void {
  if (rows.length === 0) return

  const csv = buildPortalLabelCsv(rows)
  const blob = new Blob(['\uFEFF' + csv], { type: 'text/csv;charset=utf-8' })
  triggerDownload(blob, filename ?? buildPortalLabelExportFilename(rows[0]))
}
