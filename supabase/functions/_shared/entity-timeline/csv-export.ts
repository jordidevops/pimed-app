export type TimelineExportRow = {
  seq: number
  kind: string
  id: string
  created_at: string
  action_key: string
  action: string
  actor_name: string
  summary: string
  is_task: boolean
  resolved_at: string | null
  deleted: boolean
  is_background: boolean
  is_ai_context_note: boolean
  attachment_count: number
  replies_count: number
}

export type TimelineExportPayload = {
  schema_version: number
  tenant_id: string
  entity_type: string
  entity_id: string
  entity_label: string
  exported_at: string
  exported_by: { id: string; full_name: string | null }
  filters: Record<string, unknown>
  row_count: number
  integrity_hash: string
  rows: TimelineExportRow[]
}

const CSV_HEADERS = [
  'seq',
  'kind',
  'id',
  'created_at',
  'action',
  'actor_name',
  'summary',
  'is_task',
  'resolved_at',
  'deleted',
  'is_background',
  'is_ai_context_note',
  'attachment_count',
  'replies_count',
] as const

export function escapeCsvField(value: string | number | boolean | null | undefined): string {
  if (value === null || value === undefined) return ''
  const str = String(value)
  // Neutralize formula injection: =, +, -, @, tab, pipe at the start of a field
  // can trigger formula execution in Excel / LibreOffice when the CSV is opened.
  // Prepending ' forces spreadsheet apps to treat the cell as plain text.
  const safe = /^[=+\-@\t|]/.test(str) ? `'${str}` : str
  if (/[",\n\r]/.test(safe)) {
    return `"${safe.replace(/"/g, '""')}"`
  }
  return safe
}

export function buildTimelineExportCsv(payload: TimelineExportPayload): string {
  const lines: string[] = []
  lines.push(CSV_HEADERS.join(','))

  for (const row of payload.rows) {
    lines.push([
      row.seq,
      row.kind,
      row.id,
      row.created_at,
      row.action,
      row.actor_name,
      row.summary,
      row.is_task,
      row.resolved_at ?? '',
      row.deleted,
      row.is_background,
      row.is_ai_context_note,
      row.attachment_count,
      row.replies_count,
    ].map(escapeCsvField).join(','))
  }

  lines.push('')
  lines.push('# PiMed timeline export metadata')
  lines.push(`# schema_version,${payload.schema_version}`)
  lines.push(`# tenant_id,${payload.tenant_id}`)
  lines.push(`# entity_type,${payload.entity_type}`)
  lines.push(`# entity_id,${payload.entity_id}`)
  lines.push(`# entity_label,${escapeCsvField(payload.entity_label)}`)
  lines.push(`# exported_at,${payload.exported_at}`)
  lines.push(`# exported_by,${escapeCsvField(payload.exported_by?.full_name ?? payload.exported_by?.id ?? '')}`)
  lines.push(`# row_count,${payload.row_count}`)
  lines.push(`# integrity_hash,${payload.integrity_hash}`)

  return `\uFEFF${lines.join('\r\n')}`
}

export function timelineExportFilename(
  entityType: string,
  entityId: string,
  exportedAt: string,
): string {
  const date = exportedAt.slice(0, 10)
  return `timeline-${entityType}-${entityId.slice(0, 8)}-${date}.csv`
}
