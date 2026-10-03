import { describe, expect, it } from 'vitest'
import { computeRolePermissions, hasPermission } from './permissions'

describe('attendance role permissions', () => {
  it('lets members punch and request their own absences', () => {
    const permissions = computeRolePermissions('member')
    expect(hasPermission(permissions, 'attendance.punch_own')).toBe(true)
    expect(hasPermission(permissions, 'absences.request')).toBe(true)
    expect(hasPermission(permissions, 'attendance.approve')).toBe(false)
  })

  it('lets managers approve attendance requests', () => {
    expect(
      hasPermission(computeRolePermissions('manager'), 'attendance.approve'),
    ).toBe(true)
  })
})

describe('CF-27 invoices RBAC', () => {
  it('does not give members inherited invoices.* from viewer', () => {
    const permissions = computeRolePermissions('member')
    expect(hasPermission(permissions, 'invoices.view')).toBe(false)
    expect(hasPermission(permissions, 'invoices.edit')).toBe(false)
  })

  it('keeps invoices.view on viewer for gestoria', () => {
    expect(hasPermission(computeRolePermissions('viewer'), 'invoices.view')).toBe(true)
  })

  it('honours explicit member invoice overrides', () => {
    const permissions = computeRolePermissions('member', {
      member: ['invoices.view'],
    })
    expect(hasPermission(permissions, 'invoices.view')).toBe(true)
    expect(hasPermission(permissions, 'invoices.edit')).toBe(false)
  })
})
