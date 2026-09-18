import { describe, expect, it } from 'vitest'
import { resolveQuoteComposerChatContext } from './quoteComposerChatContext'

describe('resolveQuoteComposerChatContext', () => {
  it('prefers location state over search params', () => {
    const ctx = resolveQuoteComposerChatContext({
      state: { projectId: 'proj-state', tab: 'prepare' },
      search: '?projectId=proj-query&tab=do',
    })
    expect(ctx).toEqual({
      projectId: 'proj-state',
      clientId: undefined,
      tab: 'prepare',
    })
  })

  it('reads projectId from the query string', () => {
    const ctx = resolveQuoteComposerChatContext({
      state: null,
      search: '?projectId=abc&clientId=cli&tab=prepare',
    })
    expect(ctx?.projectId).toBe('abc')
    expect(ctx?.clientId).toBe('cli')
    expect(ctx?.tab).toBe('prepare')
  })

  it('returns null when there is no context', () => {
    expect(resolveQuoteComposerChatContext({ state: null, search: '' })).toBeNull()
  })
})
