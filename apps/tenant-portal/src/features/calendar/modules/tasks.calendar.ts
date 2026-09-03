// =============================================================================
// modules/tasks.calendar.ts — Registre del mòdul de Tasques al CalendarRegistry
// =============================================================================
// Importa i crida `CalendarRegistry.register()` per declarar com es mostra
// un event de tipus 'task' al CalendarWidget.
//
// CRIDA DES DE: el punt d'entrada del mòdul (features/calendar/index.ts)
// o des d'App.tsx/main.tsx per garantir que el registre s'executa abans de
// qualsevol renderitzat del CalendarWidget.
// =============================================================================

import { CalendarRegistry } from '../CalendarRegistry'

CalendarRegistry.register({
  moduleId:       'addon_calendar',
  entityType:     'task',
  label:          'Tasca',
  defaultColor:   '#3b82f6', // blue-500
  icon:           '✓',
  viewPermission: 'calendar.view',
  editPermission: 'calendar.edit',
  // renderCard i DetailModal: no especificats → usa el renderitzador per defecte
  // del CalendarWidget. Afegir-los aquí quan el mòdul tingui el seu UI propi.
})
