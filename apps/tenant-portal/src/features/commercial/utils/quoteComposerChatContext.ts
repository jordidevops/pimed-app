const STORAGE_KEY = 'pimed.quoteComposerChatContext'

export type QuoteComposerChatContext = {
  projectId?: string
  clientId?: string
  tab?: string
}

export function rememberQuoteComposerChatContext(ctx: QuoteComposerChatContext) {
  if (typeof sessionStorage === 'undefined' || !ctx.projectId) return
  sessionStorage.setItem(STORAGE_KEY, JSON.stringify(ctx))
}

export function readQuoteComposerChatContext(): QuoteComposerChatContext | null {
  if (typeof sessionStorage === 'undefined') return null
  try {
    const raw = sessionStorage.getItem(STORAGE_KEY)
    if (!raw) return null
    const parsed = JSON.parse(raw) as QuoteComposerChatContext
    if (!parsed || typeof parsed !== 'object') return null
    return parsed
  } catch {
    return null
  }
}

export function resolveQuoteComposerChatContext(input: {
  state?: unknown
  search?: string
}): QuoteComposerChatContext | null {
  const state = (input.state ?? null) as
    | {
        entityContext?: QuoteComposerChatContext
        projectId?: string
        clientId?: string
        tab?: string
      }
    | null
  const params = new URLSearchParams(input.search ?? '')
  const remembered = readQuoteComposerChatContext()
  const projectId =
    state?.entityContext?.projectId ||
    state?.projectId ||
    params.get('projectId') ||
    remembered?.projectId ||
    undefined
  const clientId =
    state?.entityContext?.clientId ||
    state?.clientId ||
    params.get('clientId') ||
    remembered?.clientId ||
    undefined
  const tab =
    state?.entityContext?.tab ||
    state?.tab ||
    params.get('tab') ||
    remembered?.tab ||
    undefined
  if (!projectId && !clientId && !tab) return null
  return { projectId, clientId, tab }
}
