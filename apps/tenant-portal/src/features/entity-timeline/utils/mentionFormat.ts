export interface MentionRef {
  id: string
  full_name: string
  /** Nom visible dins [@label] a l'editor */
  label: string
}

export interface InlineMentionState {
  start: number
  end: number
  query: string
}

/** Converteix [[@uuid|Nom]] en @Nom (text pla, sense React). */
export function humanizeMentionTokens(content: string | null | undefined): string {
  if (!content) return ''
  return content.replace(/\[\[@([0-9a-f-]{36})\|([^\]]+)\]\]/gi, '@$2')
}

export function allocateMentionLabel(fullName: string, existing: MentionRef[]): string {
  const base = fullName.trim()
  const used = new Set(existing.map((m) => m.label))
  if (!used.has(base)) return base
  let n = 2
  while (used.has(`${base}${n}`)) n += 1
  return `${base}${n}`
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

/** Format visible a l'editor quan es selecciona un membre. */
export function formatEditorMention(label: string): string {
  return `[@${label}] `
}

/**
 * Detecta si el cursor està construint una menció (@query o [@query sense tancar).
 * Ignora @ dins mencions completes [@Nom].
 */
export function detectInlineMention(value: string, cursor: number): InlineMentionState | null {
  const before = value.slice(0, cursor)
  const masked = before.replace(/\[@([^\]]+)\]/g, (match) => ' '.repeat(match.length))

  const atIndex = masked.lastIndexOf('@')
  if (atIndex === -1) return null

  if (atIndex > 0) {
    const charBefore = before[atIndex - 1]
    if (charBefore !== '[' && /[\wÀ-ÿ]/.test(charBefore)) {
      return null
    }
  }

  const query = before.slice(atIndex + 1, cursor)
  if (/[\s\[]/.test(query)) return null

  let start = atIndex
  if (atIndex > 0 && before[atIndex - 1] === '[') {
    start = atIndex - 1
  }

  return { start, end: cursor, query }
}

/** Converteix tokens [[@uuid|Nom]] de storage a [@label] per l'editor. */
export function decodeStorageToDisplay(storageText: string): {
  display: string
  mentions: MentionRef[]
} {
  const mentions: MentionRef[] = []
  const usedLabels = new Set<string>()

  const display = storageText.replace(
    /\[\[@([0-9a-f-]{36})\|([^\]]+)\]\]/gi,
    (_match, id: string, fullName: string) => {
      let label = fullName.trim()
      if (usedLabels.has(label)) {
        let n = 2
        while (usedLabels.has(`${label}${n}`)) n += 1
        label = `${label}${n}`
      }
      usedLabels.add(label)
      mentions.push({ id, full_name: fullName, label })
      return `[@${label}]`
    },
  )

  return { display, mentions }
}

/** Converteix [@Nom] de l'editor en tokens [[@uuid|Nom complet]] per persistir. */
export function encodeMentionsForStorage(displayText: string, mentions: MentionRef[]): string {
  let result = displayText
  const sorted = [...mentions].sort((a, b) => b.label.length - a.label.length)

  for (const mention of sorted) {
    const token = `[[@${mention.id}|${mention.full_name}]]`
    const re = new RegExp(`\\[@${escapeRegExp(mention.label)}\\]`, 'g')
    result = result.replace(re, token)
  }

  return result
}

/** Elimina mencions que ja no apareixen al text de l'editor. */
export function pruneMentionRefs(displayText: string, mentions: MentionRef[]): MentionRef[] {
  return mentions.filter((mention) => {
    const re = new RegExp(`\\[@${escapeRegExp(mention.label)}\\]`)
    return re.test(displayText)
  })
}
