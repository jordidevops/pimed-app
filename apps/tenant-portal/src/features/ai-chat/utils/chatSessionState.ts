export type ChatSessionState = {
  conversationId: string | null
  draft: string
}

function storageKey(tenantId: string): string {
  return `ai_chat_session_${tenantId}`
}

export function loadChatSession(tenantId: string): ChatSessionState | null {
  try {
    const raw = sessionStorage.getItem(storageKey(tenantId))
    if (!raw) return null
    const parsed = JSON.parse(raw) as Partial<ChatSessionState>
    return {
      conversationId: typeof parsed.conversationId === 'string' ? parsed.conversationId : null,
      draft: typeof parsed.draft === 'string' ? parsed.draft : '',
    }
  } catch {
    return null
  }
}

export function saveChatSession(tenantId: string, patch: Partial<ChatSessionState>): void {
  const current = loadChatSession(tenantId) ?? { conversationId: null, draft: '' }
  sessionStorage.setItem(storageKey(tenantId), JSON.stringify({ ...current, ...patch }))
}

function consumedGeneratorsKey(conversationId: string): string {
  return `ai_chat_consumed_generators_${conversationId}`
}

export function loadConsumedGenerators(conversationId: string): Set<string> {
  try {
    const raw = sessionStorage.getItem(consumedGeneratorsKey(conversationId))
    if (!raw) return new Set()
    const parsed = JSON.parse(raw) as unknown
    if (!Array.isArray(parsed)) return new Set()
    return new Set(parsed.filter((item): item is string => typeof item === 'string'))
  } catch {
    return new Set()
  }
}

export function markConsumedGenerator(conversationId: string, blockKey: string): void {
  const next = loadConsumedGenerators(conversationId)
  next.add(blockKey)
  sessionStorage.setItem(consumedGeneratorsKey(conversationId), JSON.stringify([...next]))
}
