export function effectiveEnabledModels(available: string[], enabled: string[]): string[] {
  if (enabled.length === 0) return [...available]
  return enabled.filter((id) => available.includes(id))
}

export function isModelAllowed(
  modelId: string,
  available: string[],
  enabled: string[],
): boolean {
  if (enabled.length === 0) return available.length === 0 || available.includes(modelId)
  return enabled.includes(modelId)
}

export function pickDefaultAmongAllowed(
  current: string,
  available: string[],
  enabled: string[],
  fallback: string,
): string {
  const allowed = effectiveEnabledModels(available, enabled)
  if (allowed.includes(current)) return current
  if (allowed.length > 0) return allowed[0]
  return fallback
}

export function mergeAiModelIds(params: {
  suggested?: string[]
  available?: string[]
  current?: string | null
}): string[] {
  const seen = new Set<string>()
  const result: string[] = []

  function add(id: string | null | undefined) {
    const trimmed = id?.trim()
    if (!trimmed || seen.has(trimmed)) return
    seen.add(trimmed)
    result.push(trimmed)
  }

  for (const id of params.suggested ?? []) add(id)
  for (const id of [...(params.available ?? [])].sort()) add(id)
  add(params.current)

  return result
}

export function partitionAiModels(
  all: string[],
  suggested: string[],
): { suggested: string[]; other: string[] } {
  const suggestedSet = new Set(suggested)
  const suggestedList: string[] = []
  const other: string[] = []

  for (const id of all) {
    if (suggestedSet.has(id)) suggestedList.push(id)
    else other.push(id)
  }

  return { suggested: suggestedList, other }
}

export function filterAiModels(query: string, models: string[]): string[] {
  const q = query.trim().toLowerCase()
  if (!q) return models
  return models.filter((id) => id.toLowerCase().includes(q))
}

export const AI_MODEL_SEARCH_THRESHOLD = 12
