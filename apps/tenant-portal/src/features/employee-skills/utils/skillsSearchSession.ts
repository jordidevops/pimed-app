import type { SkillSearchMatchMode } from '../api/skillsService'

export type SkillsSearchDraft = {
  key: string
  skillId: string
  minLevelRank: string
}

export type SkillsSearchSessionState = {
  drafts: SkillsSearchDraft[]
  matchMode: SkillSearchMatchMode
  siteFilter: string
  searchArmed: boolean
}

function storageKey(tenantId: string): string {
  return `employee_skills_search_${tenantId}`
}

function isDraft(value: unknown): value is SkillsSearchDraft {
  if (!value || typeof value !== 'object') return false
  const d = value as Record<string, unknown>
  return (
    typeof d.key === 'string' &&
    typeof d.skillId === 'string' &&
    typeof d.minLevelRank === 'string'
  )
}

export function loadSkillsSearchSession(tenantId: string): SkillsSearchSessionState | null {
  try {
    const raw = sessionStorage.getItem(storageKey(tenantId))
    if (!raw) return null
    const parsed = JSON.parse(raw) as Partial<SkillsSearchSessionState>
    const drafts = Array.isArray(parsed.drafts) ? parsed.drafts.filter(isDraft) : []
    if (drafts.length === 0) return null
    return {
      drafts,
      matchMode: parsed.matchMode === 'or' ? 'or' : 'and',
      siteFilter: typeof parsed.siteFilter === 'string' ? parsed.siteFilter : '',
      searchArmed: parsed.searchArmed === true,
    }
  } catch {
    return null
  }
}

export function saveSkillsSearchSession(tenantId: string, state: SkillsSearchSessionState): void {
  sessionStorage.setItem(storageKey(tenantId), JSON.stringify(state))
}

export function clearSkillsSearchSession(tenantId: string): void {
  sessionStorage.removeItem(storageKey(tenantId))
}
