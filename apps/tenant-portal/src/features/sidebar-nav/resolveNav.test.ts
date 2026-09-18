import { describe, expect, it } from 'vitest'
import { NAV_CATALOG_BY_ID } from './navCatalog'
import { mergeMissingDefaultNavItems, passesGate, pickSidebarLayout, resolveItemLabel, type NavGateContext } from './resolveNav'
import type { SidebarNavV1 } from './sidebarNavSchema'

const officeDesktop: NavGateContext = {
  isManager: true,
  hasMyEmployee: true,
  canUseAttendance: true,
  showRecruitment: false,
  isFieldService: true,
  homePath: '/dashboard',
}

const fieldMember: NavGateContext = {
  isManager: false,
  hasMyEmployee: true,
  canUseAttendance: true,
  showRecruitment: false,
  isFieldService: true,
  homePath: '/field/today',
}

describe('mergeMissingDefaultNavItems', () => {
  it('inserts quotes after contacts in a saved operations layout', () => {
    const saved: SidebarNavV1 = {
      version: 2,
      pinned: { visible: true, items: [{ id: 'home' }] },
      groups: [
        {
          id: 'operations',
          label: 'Operativa',
          items: [{ id: 'contacts' }, { id: 'field_orders' }, { id: 'documents' }],
        },
      ],
    }

    const merged = mergeMissingDefaultNavItems(saved)
    const ops = merged.groups.find((g) => g.id === 'operations')
    expect(ops?.items.map((i) => i.id)).toEqual([
      'field_today',
      'office_dashboard',
      'contacts',
      'quotes',
      'field_orders',
      'projects',
      'documents',
      'files',
      'public_portal',
    ])
  })

  it('moves field_today to the front of Operativa when a saved layout has it later', () => {
    const saved: SidebarNavV1 = {
      version: 2,
      pinned: { visible: true, items: [{ id: 'home' }] },
      groups: [
        {
          id: 'operations',
          label: 'Operativa',
          items: [
            { id: 'contacts' },
            { id: 'field_orders' },
            { id: 'public_portal' },
            { id: 'field_today' },
          ],
        },
      ],
    }

    const merged = mergeMissingDefaultNavItems(saved)
    const ops = merged.groups.find((g) => g.id === 'operations')
    expect(ops?.items[0]?.id).toBe('field_today')
  })

  it('pickSidebarLayout merges custom user layouts', () => {
    const userLayout: SidebarNavV1 = {
      version: 2,
      pinned: { visible: true, items: [{ id: 'home' }] },
      groups: [
        {
          id: 'operations',
          label: 'Operativa',
          items: [{ id: 'contacts' }, { id: 'documents' }],
        },
      ],
    }

    const { layout, source } = pickSidebarLayout(userLayout, null)
    expect(source).toBe('user')
    expect(
      layout.groups
        .find((g) => g.id === 'operations')
        ?.items.some((i) => i.id === 'quotes'),
    ).toBe(true)
  })
})

describe('passesGate field-service office vs member', () => {
  it('hides office modules for field technicians', () => {
    expect(passesGate('isOffice', fieldMember)).toBe(false)
    expect(passesGate('isOffice', officeDesktop)).toBe(true)
    expect(passesGate('showFieldTodayNav', officeDesktop)).toBe(true)
    expect(passesGate('showFieldTodayNav', fieldMember)).toBe(false)
    expect(passesGate('showOfficeDashboardNav', fieldMember)).toBe(false)
  })

  it('requires the complete attendance capability for personal attendance links', () => {
    expect(passesGate('canUseAttendance', fieldMember)).toBe(true)
    expect(
      passesGate('canUseAttendance', { ...fieldMember, canUseAttendance: false }),
    ).toBe(false)
  })

  it('offers Inici as extra when office home is Avui', () => {
    const officeMobile: NavGateContext = { ...officeDesktop, homePath: '/field/today' }
    expect(passesGate('showOfficeDashboardNav', officeMobile)).toBe(true)
    expect(passesGate('showFieldTodayNav', officeMobile)).toBe(false)
  })
})

describe('resolveItemLabel', () => {
  const labels = {
    t: (_key: string, fallback: string) => fallback,
    contactLabel: 'Clients',
    projectLabel: 'Ordre de servei',
    projectLabelPlural: 'Obres',
  }

  it('uses project_plural for list nav and keeps a manual sidebar label', () => {
    expect(resolveItemLabel(NAV_CATALOG_BY_ID.field_orders, undefined, labels, officeDesktop)).toBe(
      'Obres',
    )
    expect(resolveItemLabel(NAV_CATALOG_BY_ID.projects, undefined, labels, officeDesktop)).toBe(
      'Obres',
    )
    expect(resolveItemLabel(NAV_CATALOG_BY_ID.field_orders, '  Manual  ', labels, officeDesktop)).toBe(
      'Manual',
    )
  })
})
