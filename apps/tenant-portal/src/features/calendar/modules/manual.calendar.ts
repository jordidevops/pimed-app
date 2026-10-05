import { CalendarRegistry } from '../CalendarRegistry'

CalendarRegistry.register({
  moduleId: null,
  entityType: 'manual',
  label: 'Event',
  defaultColor: '#0f766e',
  icon: '●',
  viewPermission: 'calendar.view',
  editPermission: 'calendar.edit',
})
