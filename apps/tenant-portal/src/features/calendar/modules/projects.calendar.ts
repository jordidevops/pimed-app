// =============================================================================
// modules/projects.calendar.ts — Registre del mòdul de Projectes al CalendarRegistry
// =============================================================================

import { CalendarRegistry } from '../CalendarRegistry'

CalendarRegistry.register({
  moduleId:       'addon_calendar',
  entityType:     'project',
  // Overridden at render time via sector_labels when archetype is field_service
  label:          'Projecte',
  defaultColor:   '#8b5cf6', // violet-500
  icon:           '📋',
  viewPermission: 'calendar.view',
  editPermission: 'calendar.manage',
})
