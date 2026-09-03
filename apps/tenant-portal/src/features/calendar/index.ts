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

// Exports públics del mòdul
export { CalendarWidget }      from './CalendarWidget'
export { CalendarRegistry }    from './CalendarRegistry'
export { useCalendarEvents }   from './useCalendarEvents'
export type {
  CalendarEventRow,
  CalendarResolvedEvent,
  CalendarModuleDefinition,
  AddonStatus,
} from './calendar.types'
