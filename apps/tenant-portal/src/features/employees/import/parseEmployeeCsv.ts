import {
  CSV_HEADER_ALIASES,
  CSV_TEMPLATE_EXAMPLE,
  CSV_TEMPLATE_HEADERS,
  type EmployeeImportRecord,
} from './employeeImportTypes'

function detectDelimiter(headerLine: string): ';' | ',' {
  const semis = (headerLine.match(/;/g) ?? []).length
  const commas = (headerLine.match(/,/g) ?? []).length
  return semis >= commas ? ';' : ','
}

/** Parse CSV simple amb cometes dobles i separador ; o , */
export function parseCsv(text: string): string[][] {
  const src = text.replace(/^\uFEFF/, '')
  const firstLine = src.split(/\r?\n/)[0] ?? ''
  return parseCsvWithDelimiter(src, detectDelimiter(firstLine))
}

function parseCsvWithDelimiter(text: string, delimiter: ';' | ','): string[][] {
  const rows: string[][] = []
  let row: string[] = []
  let cell = ''
  let inQuotes = false
  const src = text.replace(/^\uFEFF/, '')

  for (let i = 0; i < src.length; i++) {
    const ch = src[i]
    const next = src[i + 1]
    if (inQuotes) {
      if (ch === '"' && next === '"') {
        cell += '"'
        i++
      } else if (ch === '"') {
        inQuotes = false
      } else {
        cell += ch
      }
      continue
    }
    if (ch === '"') {
      inQuotes = true
      continue
    }
    if (ch === delimiter) {
      row.push(cell)
      cell = ''
      continue
    }
    if (ch === '\n' || (ch === '\r' && next === '\n')) {
      row.push(cell)
      cell = ''
      if (row.some((c) => c.trim() !== '')) rows.push(row)
      row = []
      if (ch === '\r') i++
      continue
    }
    if (ch === '\r') {
      row.push(cell)
      cell = ''
      if (row.some((c) => c.trim() !== '')) rows.push(row)
      row = []
      continue
    }
    cell += ch
  }
  row.push(cell)
  if (row.some((c) => c.trim() !== '')) rows.push(row)
  return rows
}

export function csvRowsToImportRecords(rows: string[][]): {
  records: EmployeeImportRecord[]
  errors: string[]
} {
  const errors: string[] = []
  if (rows.length < 2) {
    return { records: [], errors: ['El CSV ha de tenir capçalera i almenys una fila de dades.'] }
  }

  const headers = rows[0].map((h) => h.trim().toLowerCase())
  const fieldIndexes: Partial<Record<keyof EmployeeImportRecord, number>> = {}
  for (let i = 0; i < headers.length; i++) {
    const alias = CSV_HEADER_ALIASES[headers[i]]
    if (alias && fieldIndexes[alias] === undefined) fieldIndexes[alias] = i
  }

  if (fieldIndexes.full_name === undefined) {
    return {
      records: [],
      errors: ['Falta la columna full_name (o nombre / name / nom).'],
    }
  }

  const records: EmployeeImportRecord[] = []
  for (let r = 1; r < rows.length; r++) {
    const cols = rows[r]
    const get = (key: keyof EmployeeImportRecord) => {
      const idx = fieldIndexes[key]
      if (idx === undefined) return null
      const raw = cols[idx]?.trim() ?? ''
      return raw === '' ? null : raw
    }
    const fullName = get('full_name')
    if (!fullName) {
      errors.push(`Fila ${r + 1}: full_name buit`)
      continue
    }
    const weeklyRaw = get('weekly_hours')
    records.push({
      full_name: fullName,
      document_id: get('document_id'),
      email: get('email'),
      phone: get('phone'),
      employee_code: get('employee_code'),
      legal_name: get('legal_name'),
      preferred_name: get('preferred_name'),
      job_position_ref: get('job_position_ref'),
      manager_external_ref: get('manager_external_ref'),
      tags: get('tags'),
      status: get('status') ?? 'active',
      starts_on: get('starts_on'),
      ends_on: get('ends_on'),
      weekly_hours: weeklyRaw,
      external_id: get('external_id'),
      provider: get('provider'),
      site_id: get('site_id'),
      personal_email: get('personal_email'),
      personal_phone: get('personal_phone'),
      birth_date: get('birth_date'),
      address: get('address'),
      postal_code: get('postal_code'),
      city: get('city'),
      social_security_number: get('social_security_number'),
      iban: get('iban'),
      emergency_contact_name: get('emergency_contact_name'),
      emergency_contact_phone: get('emergency_contact_phone'),
    })
  }

  return { records, errors }
}

export function buildCsvTemplateContent(): string {
  return `${CSV_TEMPLATE_HEADERS.join(';')}\n${CSV_TEMPLATE_EXAMPLE}\n`
}

export function downloadCsvTemplate(filename = 'plantilla-empleats.csv') {
  const blob = new Blob([buildCsvTemplateContent()], { type: 'text/csv;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  a.click()
  URL.revokeObjectURL(url)
}
