import { describe, expect, it } from 'vitest'
import type { Session } from '@supabase/supabase-js'
import { getSessionAppMetadata, readAppMetadataFromAccessToken } from './sessionAppMetadata'

function fakeJwt(payload: Record<string, unknown>): string {
  const encode = (obj: unknown) =>
    Buffer.from(JSON.stringify(obj), 'utf8')
      .toString('base64')
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/=+$/g, '')
  return `${encode({ alg: 'none', typ: 'JWT' })}.${encode(payload)}.sig`
}

describe('sessionAppMetadata', () => {
  it('reads app_metadata from access token claims', () => {
    const token = fakeJwt({
      app_metadata: {
        user_permissions: {
          'tenant-1': { global_permissions: ['invoices.view', 'invoices.review'] },
        },
      },
    })
    const meta = readAppMetadataFromAccessToken(token)
    expect(meta?.user_permissions).toEqual({
      'tenant-1': { global_permissions: ['invoices.view', 'invoices.review'] },
    })
  })

  it('prefers JWT claims over sparse user.app_metadata', () => {
    const token = fakeJwt({
      app_metadata: {
        user_tenants: { 'tenant-1': { global_role: 'viewer', sites: {} } },
        user_permissions: {
          'tenant-1': { global_permissions: ['invoices.export'], sites: {} },
        },
      },
    })
    const session = {
      access_token: token,
      user: { app_metadata: { provider: 'email', providers: ['email'] } },
    } as unknown as Session

    const meta = getSessionAppMetadata(session)
    expect(meta.provider).toBe('email')
    expect(meta.user_permissions).toEqual({
      'tenant-1': { global_permissions: ['invoices.export'], sites: {} },
    })
  })
})
