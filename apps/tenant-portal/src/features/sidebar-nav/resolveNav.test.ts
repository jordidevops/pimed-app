import { describe, expect, it } from 'vitest'
import { NAV_CATALOG_BY_ID } from './navCatalog'
import { buildDefaultNavLayout } from './defaultNavLayout'
import {
  mergeMissingDefaultNavItems,
  passesGate,
  pickSidebarLayout,
  resolveItemLabel,
  resolveSidebarNav,
  type NavGateContext,
} from './resolveNav'
import type { SidebarNavV1 } from './sidebarNavSchema'

const officeDesktop: NavGateContext = {
  isManager: true,
  hasMyEmployee: true,
  canUseAttendance: true,
  showRecruitment: false,
  isFieldService: true,
  canViewSales: true,
  canViewCalendar: true,
  homePath: '/dashboard',
}

const fieldMember: NavGateContext = {
  isManager: false,
  hasMyEmployee: true,
  canUseAttendance: true,
  showRecruitment: false,
  isFieldService: true,
  canViewSales: false,
  canViewCalendar: true,
  homePath: '/field/today',
}

describe('mergeMissingDefaultNavItems', () => {
  it('inserts sales after contacts in a saved operations layout', () => {
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
      'sales',
      'field_orders',
      'field_agenda',
      'company_calendar',
      'ai_chat',
      'field_device',
      'maintenance_plans',
      'projects',
      'documents',
      'files',
      'public_portal',
    ])
    const personal = merged.groups.find((g) => g.id === 'personal')
    expect(personal?.items.map((i) => i.id)).toEqual([
      'attendance',
      'attendance_calendar',
    ])
  })

  it('relocates Horari to Jo and Assistent IA to Operativa from legacy layouts', () => {
    const saved: SidebarNavV1 = {
      version: 2,
      pinned: { visible: true, items: [{ id: 'home' }] },
      groups: [
        {
          id: 'operations',
          label: 'Operativa',
          items: [{ id: 'contacts' }, { id: 'attendance' }, { id: 'field_orders' }],
        },
        {
          id: 'personal',
          label: 'Jo',
          items: [{ id: 'attendance_calendar' }, { id: 'ai_chat' }],
        },
      ],
    }
    const merged = mergeMissingDefaultNavItems(saved)
    const ops = merged.groups.find((g) => g.id === 'operations')?.items.map((i) => i.id) ?? []
    const personal = merged.groups.find((g) => g.id === 'personal')?.items.map((i) => i.id) ?? []
    expect(ops).toContain('ai_chat')
    expect(ops).not.toContain('attendance')
    expect(personal).toContain('attendance')
    expect(personal).not.toContain('ai_chat')
    expect(personal.indexOf('attendance')).toBeLessThan(personal.indexOf('attendance_calendar'))
  })

  it('inserts company_calendar after field_agenda in a saved operations layout', () => {
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
            { id: 'field_agenda' },
            { id: 'field_device' },
            { id: 'documents' },
          ],
        },
      ],
    }
    const merged = mergeMissingDefaultNavItems(saved)
    const ops = merged.groups.find((g) => g.id === 'operations')
    const ids = ops?.items.map((i) => i.id) ?? []
    const agendaIdx = ids.indexOf('field_agenda')
    const calendarIdx = ids.indexOf('company_calendar')
    expect(agendaIdx).toBeGreaterThanOrEqual(0)
    expect(calendarIdx).toBe(agendaIdx + 1)
  })

  it('aliases quotes, delivery_notes and cobraments to a single sales item', () => {
    const saved: SidebarNavV1 = {
      version: 2,
      pinned: { visible: true, items: [{ id: 'home' }] },
      groups: [
        {
          id: 'operations',
          label: 'Operativa',
          items: [
            { id: 'contacts' },
            { id: 'quotes' },
            { id: 'cobraments' },
            { id: 'delivery_notes' },
            { id: 'field_orders' },
          ],
        },
      ],
    }
    const merged = mergeMissingDefaultNavItems(saved)
    const ops = merged.groups.find((g) => g.id === 'operations')
    const ids = ops?.items.map((i) => i.id) ?? []
    expect(ids.filter((id) => id === 'sales')).toHaveLength(1)
    expect(ids).not.toContain('cobraments')
    expect(ids).not.toContain('quotes')
    expect(ids).not.toContain('delivery_notes')
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
        ?.items.some((i) => i.id === 'sales'),
    ).toBe(true)
  })
})

describe('passesGate field-service office vs member', () => {
  it('hides office modules for field technicians', () => {
    expect(passesGate('isOffice', fieldMember)).toBe(false)
    expect(passesGate('isOffice', officeDesktop)).toBe(true)
    expect(passesGate('canViewSales', fieldMember)).toBe(false)
    expect(passesGate('canViewSales', officeDesktop)).toBe(true)
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

  it('allows sales for gestoria via canViewSales without office', () => {
    const gestoria: NavGateContext = {
      ...fieldMember,
      canViewSales: true,
    }
    expect(passesGate('isOffice', gestoria)).toBe(false)
    expect(passesGate('canViewSales', gestoria)).toBe(true)
  })

  it('gates company calendar on canViewCalendar', () => {
    expect(passesGate('canViewCalendar', fieldMember)).toBe(true)
    expect(
      passesGate('canViewCalendar', { ...fieldMember, canViewCalendar: false }),
    ).toBe(false)
  })
})

describe('resolveItemLabel', () => {
  const labels = {
    t: (_key: string, fallback: string) => fallback,
    contactLabel: 'Clients',
    projectLabel: 'Ordre de servei',
    projectLabelPlural: 'Obres',
    agreementLabelPlural: 'Acords comercials',
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

describe('resolveSidebarNav field agenda + device', () => {
  const labels = {
    t: (_key: string, fallback: string) => fallback,
    contactLabel: 'Clients',
    projectLabel: 'Ordre de servei',
    projectLabelPlural: 'Ordres',
    agreementLabelPlural: 'Acords comercials',
  }

  function operativaIds(ctx: NavGateContext) {
    const resolved = resolveSidebarNav(buildDefaultNavLayout(), ctx, labels)
    return resolved.groups.find((g) => g.id === 'operations')?.items.map((i) => i.id) ?? []
  }

  it('shows Agenda and Dispositiu for field members (not maintenance plans)', () => {
    const ids = operativaIds(fieldMember)
    expect(ids).toContain('field_orders')
    expect(ids).toContain('field_agenda')
    expect(ids).toContain('company_calendar')
    expect(ids).toContain('ai_chat')
    expect(ids).toContain('field_device')
    expect(ids).toContain('contacts')
    expect(ids).not.toContain('attendance')
    expect(ids).not.toContain('maintenance_plans')
    expect(ids.indexOf('company_calendar')).toBe(ids.indexOf('field_agenda') + 1)
    expect(ids.indexOf('ai_chat')).toBe(ids.indexOf('company_calendar') + 1)
  })

  it('hides company_calendar when canViewCalendar is false', () => {
    const ids = operativaIds({ ...fieldMember, canViewCalendar: false })
    expect(ids).not.toContain('company_calendar')
    expect(ids).toContain('field_agenda')
  })

  it('shows Agenda, Dispositiu and maintenance plans for field managers', () => {
    const ids = operativaIds(officeDesktop)
    expect(ids).toContain('field_agenda')
    expect(ids).toContain('field_device')
    expect(ids).toContain('ai_chat')
    expect(ids).not.toContain('attendance')
    expect(ids).toContain('maintenance_plans')
  })

  it('puts Horari under Jo for attendance-capable members', () => {
    const resolved = resolveSidebarNav(buildDefaultNavLayout(), fieldMember, labels)
    const personal =
      resolved.groups.find((g) => g.id === 'personal')?.items.map((i) => i.id) ?? []
    expect(personal).toEqual(['attendance', 'attendance_calendar'])
  })
})
