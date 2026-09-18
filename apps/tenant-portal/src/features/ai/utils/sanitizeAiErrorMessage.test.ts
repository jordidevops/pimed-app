import { describe, expect, it } from 'vitest'
import { sanitizeAiErrorMessage, stripTenantIdsFromMessage } from './sanitizeAiErrorMessage'

const TENANT = '10000000-0000-0000-0000-000000000004'

describe('sanitizeAiErrorMessage', () => {
  it('maps missing config without keeping the tenant id', () => {
    const message = sanitizeAiErrorMessage(`No AI config enabled for tenant ${TENANT}`)
    expect(message).not.toContain(TENANT)
    expect(message.toLowerCase()).toContain('configura')
  })

  it('does not map an unverified key as a missing config', () => {
    const message = sanitizeAiErrorMessage(
      `AI API key for provider openai is not verified (tenant ${TENANT})`,
    )
    expect(message).not.toContain(TENANT)
    expect(message.toLowerCase()).toContain('verifica')
    expect(message.toLowerCase()).not.toContain('configura una clau')
  })

  it('strips leftover uuids from unknown errors', () => {
    expect(stripTenantIdsFromMessage(`boom ${TENANT} after`)).toBe('boom after')
  })
})
