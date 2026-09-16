import { describe, expect, it } from 'vitest'
import { translateAuthError } from './translateAuthError'

const t = (key: string, fallback: string) => `${key}|${fallback}`

describe('translateAuthError', () => {
  it('maps Invalid login credentials by message', () => {
    expect(translateAuthError({ message: 'Invalid login credentials' }, t)).toBe(
      'errors.invalid_credentials|Correu o contrasenya incorrectes.',
    )
  })

  it('maps invalid_credentials by code', () => {
    expect(translateAuthError({ code: 'invalid_credentials', message: 'Invalid login credentials' }, t)).toBe(
      'errors.invalid_credentials|Correu o contrasenya incorrectes.',
    )
  })

  it('maps expired email links from hash descriptions', () => {
    expect(translateAuthError('Email+link+is+invalid+or+has+expired', t)).toContain('errors.email_link_invalid|')
  })

  it('maps rate-limit copy that includes a wait time', () => {
    expect(
      translateAuthError(
        { message: 'For security purposes, you can only request this after 54 seconds.' },
        t,
      ),
    ).toContain('errors.rate_limit|')
  })

  it('falls back to a generic Catalan message', () => {
    expect(translateAuthError({ message: 'Something obscure from GoTrue' }, t)).toContain('errors.generic|')
  })
})
