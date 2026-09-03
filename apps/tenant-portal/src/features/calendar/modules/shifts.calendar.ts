// =============================================================================
// modules/shifts.calendar.ts — Torns publicats al CalendarRegistry
// =============================================================================

import { CalendarRegistry } from '../CalendarRegistry'

CalendarRegistry.register({
  moduleId: null, // core attendance — no addon billing gate
  entityType: 'shift_slot',
  label: 'Torn',
  defaultColor: '#6366f1',
  icon: '⏱',
  viewPermission: 'calendar.view',
  editPermission: 'calendar.manage',
})
