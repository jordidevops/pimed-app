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
