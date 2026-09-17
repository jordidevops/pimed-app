export function parseAiJsonContent(raw: string): unknown {
  const trimmed = raw.trim()
  const fenced = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/i)
  const body = (fenced?.[1] ?? trimmed).trim()
  return JSON.parse(body)
}

export function matchCatalogItemId(
  name: string,
  items: Array<{ id: string | null; name: string | null }>,
): string | null {
  const needle = name.trim().toLowerCase()
  if (!needle) return null
  const exact = items.find((item) => item.id && (item.name ?? '').trim().toLowerCase() === needle)
  if (exact?.id) return exact.id
  const partial = items.filter(
    (item) => item.id && (item.name ?? '').toLowerCase().includes(needle),
  )
  if (partial.length === 1) return partial[0].id
  return null
}

export function matchNamedId(
  name: string,
  items: Array<{ id: string; name: string }>,
): string | null {
  const needle = name.trim().toLowerCase()
  if (!needle) return null
  const exact = items.find((item) => item.name.trim().toLowerCase() === needle)
  if (exact) return exact.id
  const partial = items.filter((item) => item.name.toLowerCase().includes(needle))
  if (partial.length === 1) return partial[0].id
  return null
}
