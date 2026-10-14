import { describe, expect, it } from 'vitest'
import {
  buildAgreementSignersPayload,
  parseAgreementSigningRoles,
} from './agreementSigningRoles'

describe('agreementSigningRoles', () => {
  it('parses roles array schema', () => {
    expect(parseAgreementSigningRoles({ roles: ['issuer', 'client'] })).toEqual([
      'issuer',
      'client',
    ])
  })

  it('parses object-key schema and defaults to client', () => {
    expect(parseAgreementSigningRoles({ client: { label: 'Client', order: 1 } })).toEqual([
      'client',
    ])
    expect(parseAgreementSigningRoles(null)).toEqual(['client'])
    expect(parseAgreementSigningRoles({})).toEqual(['client'])
  })

  it('builds signers in role order', () => {
    expect(
      buildAgreementSignersPayload({
        roles: ['issuer', 'client'],
        issuerName: 'Volt',
        clientName: 'Client',
        clientEmail: 'c@x.test',
      }),
    ).toEqual([
      { email: '', name: 'Volt', role: 'issuer', order: 0 },
      { email: 'c@x.test', name: 'Client', role: 'client', order: 1 },
    ])
    expect(
      buildAgreementSignersPayload({
        roles: ['client'],
        issuerName: 'Volt',
        clientName: 'Client',
      }),
    ).toEqual([{ email: '', name: 'Client', role: 'client', order: 0 }])
  })
})
