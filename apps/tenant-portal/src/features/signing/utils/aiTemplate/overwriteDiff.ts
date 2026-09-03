import type { SigningRolesSchema, VariablesSchema } from '../../api/signingService'

export interface LocaleOverwriteSnapshot {
  htmlContent?: string
  variablesSchema: VariablesSchema | null
  rolesSchema: SigningRolesSchema
}

export type DiffLineKind = 'equal' | 'remove' | 'add'

export interface DiffLine {
  type: DiffLineKind
  text: string
}

export interface SchemaFieldChange {
  key: string
  field: string
  before: string
  after: string
}

export interface LocaleOverwriteDiff {
  roles: {
    added: string[]
    removed: string[]
    changed: SchemaFieldChange[]
  }
  variables: {
    added: string[]
    removed: string[]
    changed: SchemaFieldChange[]
  }
  html: {
    changed: boolean
    oldLength: number
    newLength: number
    lines: DiffLine[]
    truncated: boolean
  } | null
  hasChanges: boolean
}

const MAX_DIFF_LINES = 250

function normalizeComparableText(value: string): string {
  return value.replace(/\s+/g, ' ').trim()
}

function diffSchemaEntries(
  before: Record<string, Record<string, unknown>>,
  after: Record<string, Record<string, unknown>>,
  fields: Array<{ key: string; label: string }>,
): { added: string[]; removed: string[]; changed: SchemaFieldChange[] } {
  const beforeKeys = new Set(Object.keys(before))
  const afterKeys = new Set(Object.keys(after))

  const added = [...afterKeys].filter(k => !beforeKeys.has(k)).sort()
  const removed = [...beforeKeys].filter(k => !afterKeys.has(k)).sort()
  const changed: SchemaFieldChange[] = []

  for (const key of [...afterKeys].filter(k => beforeKeys.has(k)).sort()) {
    const oldEntry = before[key]
    const newEntry = after[key]
    for (const field of fields) {
      const oldVal = String(oldEntry[field.key] ?? '')
      const newVal = String(newEntry[field.key] ?? '')
      if (oldVal !== newVal) {
        changed.push({ key, field: field.label, before: oldVal || '—', after: newVal || '—' })
      }
    }
  }

  return { added, removed, changed }
}

function diffLines(oldText: string, newText: string): { lines: DiffLine[]; truncated: boolean } {
  const oldLines = oldText.split('\n')
  const newLines = newText.split('\n')
  const result: DiffLine[] = []
  let i = 0
  let j = 0
  let truncated = false

  while (i < oldLines.length || j < newLines.length) {
    if (result.length >= MAX_DIFF_LINES) {
      truncated = true
      break
    }

    if (i >= oldLines.length) {
      result.push({ type: 'add', text: newLines[j++] })
      continue
    }
    if (j >= newLines.length) {
      result.push({ type: 'remove', text: oldLines[i++] })
      continue
    }

    if (oldLines[i] === newLines[j]) {
      result.push({ type: 'equal', text: oldLines[i++] })
      j++
      continue
    }

    const nextOldInNew = newLines.indexOf(oldLines[i], j + 1)
    const nextNewInOld = oldLines.indexOf(newLines[j], i + 1)

    if (nextOldInNew !== -1 && (nextNewInOld === -1 || nextOldInNew - j <= nextNewInOld - i)) {
      result.push({ type: 'add', text: newLines[j++] })
    } else if (nextNewInOld !== -1) {
      result.push({ type: 'remove', text: oldLines[i++] })
    } else {
      result.push({ type: 'remove', text: oldLines[i++] })
      result.push({ type: 'add', text: newLines[j++] })
    }
  }

  if (i < oldLines.length || j < newLines.length) truncated = true

  return { lines: collapseEqualRuns(result), truncated }
}

function collapseEqualRuns(lines: DiffLine[]): DiffLine[] {
  const out: DiffLine[] = []
  let equalBuffer: string[] = []

  function flushEquals() {
    if (equalBuffer.length === 0) return
    if (equalBuffer.length <= 3) {
      for (const text of equalBuffer) out.push({ type: 'equal', text })
    } else {
      out.push({ type: 'equal', text: `… ${equalBuffer.length} línies sense canvis …` })
    }
    equalBuffer = []
  }

  for (const line of lines) {
    if (line.type === 'equal') {
      equalBuffer.push(line.text)
    } else {
      flushEquals()
      out.push(line)
    }
  }
  flushEquals()
  return out
}

export function computeLocaleOverwriteDiff(
  existing: LocaleOverwriteSnapshot,
  incoming: LocaleOverwriteSnapshot,
  templateType: 'html' | 'docx',
): LocaleOverwriteDiff {
  const roles = diffSchemaEntries(
    (existing.rolesSchema ?? {}) as unknown as Record<string, Record<string, unknown>>,
    (incoming.rolesSchema ?? {}) as unknown as Record<string, Record<string, unknown>>,
    [
      { key: 'label', label: 'label' },
      { key: 'entity_type', label: 'entity_type' },
      { key: 'for_signing', label: 'for_signing' },
      { key: 'order', label: 'order' },
    ],
  )

  const variables = diffSchemaEntries(
    (existing.variablesSchema ?? {}) as unknown as Record<string, Record<string, unknown>>,
    (incoming.variablesSchema ?? {}) as unknown as Record<string, Record<string, unknown>>,
    [
      { key: 'label', label: 'label' },
      { key: 'type', label: 'type' },
      { key: 'required', label: 'required' },
      { key: 'role', label: 'role' },
      { key: 'order', label: 'order' },
    ],
  )

  let html: LocaleOverwriteDiff['html'] = null
  if (templateType === 'html') {
    const oldContent = existing.htmlContent ?? ''
    const newContent = incoming.htmlContent ?? ''
    const changed = normalizeComparableText(oldContent) !== normalizeComparableText(newContent)
    const { lines, truncated } = changed ? diffLines(oldContent, newContent) : { lines: [], truncated: false }
    html = {
      changed,
      oldLength: oldContent.length,
      newLength: newContent.length,
      lines,
      truncated,
    }
  }

  const hasChanges =
    roles.added.length > 0
    || roles.removed.length > 0
    || roles.changed.length > 0
    || variables.added.length > 0
    || variables.removed.length > 0
    || variables.changed.length > 0
    || (html?.changed ?? false)

  return { roles, variables, html, hasChanges }
}
