export type ClonePickRow = {
  id: string
  status: string
  cloned_from_catalog_id?: string | null
  updated_at?: string
}

/** Prefereix active, després updated_at més recent. */
export function pickBestClone<T extends ClonePickRow>(
  rows: T[],
  catalogId: string,
): T | null {
  const matches = rows.filter(
    (r) => r.cloned_from_catalog_id === catalogId && r.status !== 'archived',
  )
  if (matches.length === 0) return null
  const active = matches.find((r) => r.status === 'active')
  if (active) return active
  return [...matches].sort((a, b) =>
    String(b.updated_at ?? '').localeCompare(String(a.updated_at ?? '')),
  )[0]!
}
