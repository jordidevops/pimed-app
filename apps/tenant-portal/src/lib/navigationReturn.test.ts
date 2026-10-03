import { describe, expect, it } from 'vitest'
import {
  documentPathWithReturn,
  encodeReturnTo,
  isAllowedReturnTo,
  readReturnTo,
  withReturnTo,
} from './navigationReturn'

describe('navigationReturn', () => {
  it('allows whitelisted relative paths', () => {
    expect(isAllowedReturnTo('/sales')).toBe(true)
    expect(isAllowedReturnTo('/sales/delivery-notes/abc')).toBe(true)
    expect(isAllowedReturnTo('/sales/invoices/abc')).toBe(true)
    expect(isAllowedReturnTo('/quotes?view=abc')).toBe(true)
    expect(isAllowedReturnTo('/cobraments?view=abc&status=open')).toBe(true)
    expect(isAllowedReturnTo('/delivery-notes?view=abc&status=open')).toBe(true)
    expect(isAllowedReturnTo('/contacts/x?tab=projects')).toBe(true)
    expect(isAllowedReturnTo('/field/orders')).toBe(true)
    expect(isAllowedReturnTo('/field/today')).toBe(true)
    expect(isAllowedReturnTo('/documents?folder=1')).toBe(true)
  })

  it('rejects open redirects and unknown paths', () => {
    expect(isAllowedReturnTo('https://evil.test')).toBe(false)
    expect(isAllowedReturnTo('//evil.test')).toBe(false)
    expect(isAllowedReturnTo('/settings')).toBe(false)
    expect(isAllowedReturnTo(null)).toBe(false)
  })

  it('reads and validates returnTo from search params', () => {
    const ok = new URLSearchParams({
      returnTo: encodeReturnTo('/contacts/1?tab=projects'),
    })
    expect(readReturnTo(ok)).toBe('/contacts/1?tab=projects')

    const bad = new URLSearchParams({ returnTo: '/admin' })
    expect(readReturnTo(bad)).toBe(null)
  })

  it('appends returnTo to paths', () => {
    expect(withReturnTo('/field/orders/abc', '/contacts/1?tab=projects')).toContain(
      'returnTo=',
    )
    expect(documentPathWithReturn('doc-1', '/quotes?view=q1')).toMatch(
      /^\/documents\/doc-1\?returnTo=/,
    )
  })
})
