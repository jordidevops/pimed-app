// =============================================================================
// CalendarRegistry.ts — Patró Registry per al Calendari Modular
// =============================================================================
// Cada mòdul de l'app (tasques, facturació, manteniment...) s'autoregistra
// en aquest singleton. El CalendarWidget el consulta per renderitzar cada
// tipus d'event de forma desacoblada.
//
// ÚS:
//   // En el mòdul de tasques (tasks/calendar.module.ts):
//   CalendarRegistry.register({
//     moduleId:       'addon_calendar',
//     entityType:     'task',
//     label:          'Tasca',
//     defaultColor:   '#3b82f6',
//     viewPermission: 'calendar.view',
//     editPermission: 'calendar.edit',
//   })
//
//   // Al CalendarWidget:
//   const def = CalendarRegistry.get(event.entity_type)
// =============================================================================

import type { CalendarModuleDefinition } from './calendar.types'

class CalendarRegistrySingleton {
  private readonly registry = new Map<string, CalendarModuleDefinition>()

  /**
   * Registra un mòdul al calendari. Crida des de cada feature/mòdul.
   * Si ja existeix un registre per al mateix entityType, el sobreescriu
   * (permet hot-reload en dev sense duplicats).
   */
  register(definition: CalendarModuleDefinition): void {
    this.registry.set(definition.entityType, definition)
  }

  /**
   * Retorna la definició per a un tipus d'entitat concret.
   * Retorna `undefined` si el tipus no està registrat (event d'un mòdul
   * desconegut o no carregat).
   */
  get(entityType: string): CalendarModuleDefinition | undefined {
    return this.registry.get(entityType)
  }

  /** Retorna totes les definicions registrades (útil per llegenda i filtres). */
  getAll(): CalendarModuleDefinition[] {
    return Array.from(this.registry.values())
  }

  /** Llista de tots els entityTypes registrats. */
  getEntityTypes(): string[] {
    return Array.from(this.registry.keys())
  }
}

/** Singleton global del Registry. Importar directament on calgui. */
export const CalendarRegistry = new CalendarRegistrySingleton()
