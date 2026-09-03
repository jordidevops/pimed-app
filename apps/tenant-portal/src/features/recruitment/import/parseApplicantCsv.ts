import {
  CSV_HEADER_ALIASES,
  CSV_TEMPLATE_EXAMPLE,
  CSV_TEMPLATE_HEADERS,
  MAX_IMPORT_ROWS,
  type ApplicantImportRecord,
} from './applicantImportTypes'

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

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
  records: ApplicantImportRecord[]
  errors: string[]
} {
  const errors: string[] = []
  if (rows.length < 2) {
    return { records: [], errors: ['El CSV ha de tenir capçalera i almenys una fila de dades.'] }
  }

  const headers = rows[0].map((h) => h.trim().toLowerCase())
  const fieldIndexes: Partial<Record<keyof ApplicantImportRecord, number>> = {}
  for (let i = 0; i < headers.length; i++) {
    const alias = CSV_HEADER_ALIASES[headers[i]]
    if (alias && fieldIndexes[alias] === undefined) fieldIndexes[alias] = i
  }

  if (fieldIndexes.full_name === undefined || fieldIndexes.email === undefined) {
    return {
      records: [],
      errors: ['Falten columnes obligatòries: full_name i email (o alias).'],
    }
  }

  const records: ApplicantImportRecord[] = []
  for (let r = 1; r < rows.length; r++) {
    if (records.length >= MAX_IMPORT_ROWS) {
      errors.push(`S'ha truncat a ${MAX_IMPORT_ROWS} files (màxim per import).`)
      break
    }
    const cols = rows[r]
    const get = (key: keyof ApplicantImportRecord) => {
      const idx = fieldIndexes[key]
      if (idx === undefined) return null
      const raw = cols[idx]?.trim() ?? ''
      return raw === '' ? null : raw
    }
    const fullName = get('full_name')
    const email = get('email')?.toLowerCase() ?? null
    if (!fullName || !email) {
      errors.push(`Fila ${r + 1}: full_name i email són obligatoris`)
      continue
    }
    if (!EMAIL_RE.test(email)) {
      errors.push(`Fila ${r + 1}: email invàlid (${email})`)
      continue
    }
    records.push({
      full_name: fullName,
      email,
      phone: get('phone'),
      locale: get('locale'),
      cover_message: get('cover_message'),
    })
  }

  return { records, errors }
}

export function buildCsvTemplateContent(): string {
  return `${CSV_TEMPLATE_HEADERS.join(';')}\n${CSV_TEMPLATE_EXAMPLE}\n`
}

export function downloadCsvTemplate(filename = 'plantilla-candidatures.csv') {
  const blob = new Blob([buildCsvTemplateContent()], { type: 'text/csv;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  a.click()
  URL.revokeObjectURL(url)
}
