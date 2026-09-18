import { describe, expect, it } from 'vitest'
import {
  fieldAdminBackTo,
  fieldAdminPageClassName,
  fieldAdminPath,
  isFieldSettingsPath,
} from './fieldAdminPaths'

describe('fieldAdminPaths', () => {
  it('detects settings-scoped field admin URLs', () => {
    expect(isFieldSettingsPath('/settings/field/checklist-templates')).toBe(true)
    expect(isFieldSettingsPath('/field/checklist-templates')).toBe(false)
  })

  it('keeps cross-links inside the same chrome', () => {
    expect(fieldAdminPath('points', '/settings/field/checklist-templates')).toBe(
      '/settings/field/checklist-points',
    )
    expect(fieldAdminPath('points', '/field/checklist-templates')).toBe(
      '/field/checklist-points',
    )
  })

  it('sends the back link to Settings or Més', () => {
    expect(fieldAdminBackTo('/settings/field/response-sets')).toBe('/settings/config')
    expect(fieldAdminBackTo('/field/response-sets')).toBe('/field/more')
  })

  it('drops field padding when the page is inside Settings', () => {
    expect(fieldAdminPageClassName('/settings/field/checklist-templates')).not.toContain(
      'pb-24',
    )
    expect(fieldAdminPageClassName('/field/checklist-templates')).toContain('pb-24')
  })
})
