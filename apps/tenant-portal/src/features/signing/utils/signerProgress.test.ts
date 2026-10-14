import { describe, expect, it } from 'vitest'
import { parseSignerProgress, signerRoleKey } from './signerProgress'

describe('signerProgress', () => {
  it('orders signers and maps issuer/client statuses', () => {
    const rows = parseSignerProgress([
      { name: 'Client', role: 'client', status: 'pending', order: 1 },
      { name: 'Prestador', role: 'issuer', status: 'completed', order: 0 },
    ])
    expect(rows.map((row) => row.role)).toEqual(['issuer', 'client'])
    expect(rows.map((row) => row.status)).toEqual(['completed', 'pending'])
  })

  it('treats cancelled as its own status', () => {
    expect(parseSignerProgress([{ role: 'issuer', status: 'cancelled' }])[0]?.status).toBe(
      'cancelled',
    )
  })

  it('maps quote accept roles to client', () => {
    expect(signerRoleKey('client_accept')).toBe('client')
    expect(signerRoleKey('client_delivery')).toBe('client')
    expect(signerRoleKey('issuer')).toBe('issuer')
    expect(signerRoleKey('witness')).toBe('other')
  })
})
