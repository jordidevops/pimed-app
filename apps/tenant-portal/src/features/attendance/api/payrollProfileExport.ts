import type {
  PayrollConceptMapping,
  PayrollExportColumnMapping,
  PayrollExportProfile,
  PayrollExportProfileMapping,
} from './payrollConnectorTypes'
import type {
  PayrollExportAggregateRow,
  PayrollExportDailyRow,
  PayrollExportPayload,
} from './payrollExportService'

type ExportRow = PayrollExportDailyRow | PayrollExportAggregateRow

function minutesToHm(min: number | null | undefined): string {
  if (min == null) return ''
  const h = Math.floor(Math.abs(min) / 60)
  const m = Math.abs(min) % 60
  return `${h}:${String(m).padStart(2, '0')}`
}

function formatDateDdMmYyyy(value: string | null | undefined): string {
  if (!value) return ''
  const d = value.slice(0, 10)
  const [y, mo, day] = d.split('-')
  if (!y || !mo || !day) return d
  return `${day}/${mo}/${y}`
}

function formatBoolean01(value: unknown): string {
  if (value == null || value === '') return ''
  return value === true || value === 'true' || value === 1 || value === '1' ? '1' : '0'
}

function rawFieldValue(row: ExportRow, field: string): unknown {
  return (row as unknown as Record<string, unknown>)[field]
}

function formatSourceValue(value: unknown, format?: PayrollExportColumnMapping['format']): string {
  if (value == null) return ''
  switch (format) {
    case 'date_dd_mm_yyyy':
      return formatDateDdMmYyyy(String(value))
    case 'hours_hh_mm':
      return minutesToHm(Number(value))
    case 'minutes_decimal':
      return String(Number(value))
    case 'boolean_01':
      return formatBoolean01(value)
    case 'text':
    default:
      if (Array.isArray(value)) return value.join(', ')
      return String(value)
  }
}

function conceptValue(
  row: ExportRow,
  concept: PayrollConceptMapping,
  columnFormat?: PayrollExportColumnMapping['format'],
): string {
  const field = concept.source_field
  if (!field) return ''
  const raw = rawFieldValue(row, field)

  if (concept.unit === 'days') {
    return raw == null ? '' : String(raw)
  }

  if (concept.unit === 'hours') {
    const minutes = Number(raw ?? 0)
    if (columnFormat === 'minutes_decimal') return String(minutes)
    if (columnFormat === 'hours_hh_mm') return minutesToHm(minutes)
    const hours = minutes / 60
    return Number.isInteger(hours) ? String(hours) : hours.toFixed(2)
  }

  if (concept.unit === 'minutes') {
    return raw == null ? '' : String(raw)
  }

  return raw == null ? '' : String(raw)
}

function resolveColumnValue(
  row: ExportRow,
  column: PayrollExportColumnMapping,
  concepts: PayrollConceptMapping[],
): string {
  if (column.literal != null) return column.literal

  if (column.concept_key) {
    const concept = concepts.find((c) => c.concept_key === column.concept_key)
    if (!concept) return ''
    return conceptValue(row, concept, column.format)
  }

  if (column.source) {
    return formatSourceValue(rawFieldValue(row, column.source), column.format)
  }

  return ''
}

function escapeCsvCell(value: string): string {
  return `"${String(value).replace(/"/g, '""')}"`
}

export function profileMappingFromDbRow(row: {
  column_mapping: unknown
  concept_mapping: unknown
  header_row?: number | null
}): PayrollExportProfileMapping {
  const columnMapping = (row.column_mapping ?? {}) as PayrollExportProfileMapping
  const conceptsRaw = row.concept_mapping
  const concepts = Array.isArray(conceptsRaw)
    ? (conceptsRaw as PayrollConceptMapping[])
    : ((conceptsRaw as { concepts?: PayrollConceptMapping[] } | null)?.concepts ?? [])

  return {
    columns: columnMapping.columns ?? [],
    concepts,
    header_row: columnMapping.header_row ?? row.header_row ?? 1,
    csv_delimiter: columnMapping.csv_delimiter ?? ';',
  }
}

export function profileMappingToDbPayload(mapping: PayrollExportProfileMapping): {
  column_mapping: Record<string, unknown>
  concept_mapping: PayrollConceptMapping[]
  header_row: number
} {
  const { columns, concepts, header_row, csv_delimiter } = mapping
  return {
    column_mapping: {
      columns: columns ?? [],
      header_row: header_row ?? 1,
      csv_delimiter: csv_delimiter ?? ';',
    },
    concept_mapping: concepts ?? [],
    header_row: header_row ?? 1,
  }
}

export function applyPayrollExportProfile(
  payload: PayrollExportPayload,
  profile: PayrollExportProfile,
): string {
  const mapping = profile.mapping
  const delimiter = mapping.csv_delimiter ?? ';'
  const concepts = mapping.concepts ?? []
  const columns = mapping.columns ?? []

  const headerLine = columns.map((c) => escapeCsvCell(c.header)).join(delimiter)
  const dataLines = payload.rows.map((row) =>
    columns
      .map((col) => escapeCsvCell(resolveColumnValue(row, col, concepts)))
      .join(delimiter),
  )

  const blankLines =
    mapping.header_row && mapping.header_row > 1
      ? Array.from({ length: mapping.header_row - 1 }, () => '').join('\r\n')
      : ''

  const body = [headerLine, ...dataLines].join('\r\n')
  return blankLines ? `${blankLines}\r\n${body}` : body
}

export function downloadProfilePayrollCsv(
  payload: PayrollExportPayload,
  profile: PayrollExportProfile,
): void {
  const csv = applyPayrollExportProfile(payload, profile)
  const siteSlug = (payload.site_name || 'site').replace(/\s+/g, '-')
  const profileSlug = profile.name.replace(/\s+/g, '-').slice(0, 40)
  const blob = new Blob(['\uFEFF' + csv], { type: 'text/csv;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = `export-nomina_${siteSlug}_${profileSlug}_${payload.from}_${payload.to}.csv`
  anchor.click()
  URL.revokeObjectURL(url)
}
