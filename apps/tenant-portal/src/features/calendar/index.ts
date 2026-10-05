// =============================================================================
// index.ts — Punt d'entrada del mòdul de Calendari
// =============================================================================
// Exporta els components, hooks, tipus i el Registry.
// Executa tots els registres de mòduls en importar aquest fitxer.
//
// ÚS a App.tsx o main.tsx:
//   import '@/features/calendar'  // efecte de registre
//   import { CalendarWidget } from '@/features/calendar'
// =============================================================================

// Execució dels registres (side-effects de registre, ordre garantit)
import './modules/tasks.calendar'
import './modules/projects.calendar'
import './modules/shifts.calendar'
import './modules/manual.calendar'

// Exports públics del mòdul
export { CalendarWidget }      from './CalendarWidget'
export { CompanyCalendarPage } from './CompanyCalendarPage'
export { EventDetailSheet, DefaultEventDetail } from './EventDetailSheet'
export { CreateEventForm } from './CreateEventForm'
export { CalendarGrid }        from './CalendarGrid'
export type { CalendarGridEvent, CalendarGridView } from './CalendarGrid'
export { CalendarTimeGrid } from './CalendarTimeGrid'
export type { CalendarTimeGridView } from './CalendarTimeGrid'
export * from './calendarTimeGridLayout'
export { CalendarRegistry }    from './CalendarRegistry'
export { useCalendarEvents }   from './useCalendarEvents'
export * from './calendarDateUtils'
export * from './projectEventsOntoDays'
export * from './companyCalendarUrlState'
export * from './matchCalendarEvents'
export * from './mineCalendarEvents'
export type {
  CalendarEventRow,
  CalendarResolvedEvent,
  CalendarModuleDefinition,
  AddonStatus,
} from './calendar.types'
