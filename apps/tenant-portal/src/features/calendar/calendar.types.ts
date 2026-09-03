// =============================================================================
// calendar.types.ts — Tipus del mòdul de Calendari
// =============================================================================
// Derivats dels tipus generats de la BD (database.types.ts) + extensions de UI.
// =============================================================================

import type { Database } from '../../types/database.types'
import type { PermissionKey } from '../../lib/permissions'

// ---------------------------------------------------------------------------
// Tipus base de la BD
// ---------------------------------------------------------------------------

/** Fila completa de api.calendar_events tal com la retorna PostgREST */
export type CalendarEventRow =
  Database['api']['Views']['calendar_events']['Row']

// ---------------------------------------------------------------------------
// Addon status
// ---------------------------------------------------------------------------

/** Estats possibles d'un addon per al tenant */
export type AddonStatus = 'active' | 'trial' | 'canceled' | 'expired' | null

// ---------------------------------------------------------------------------
// Registry de mòduls del calendari
// ---------------------------------------------------------------------------

/**
 * Definició que cada mòdul registra al CalendarRegistry.
 * Descriu com es renderitza visualment un tipus d'event concret.
 */
export interface CalendarModuleDefinition {
  /** Identificador de l'addon. Ha de coincidir amb data.billing_addons.id. */
  moduleId: string | null // null = core (sempre visible)

  /** Discriminador polimòrfic. Ha de coincidir amb calendar_events.entity_type */
  entityType: string

  /** Etiqueta llegible per als usuaris */
  label: string

  /** Color per defecte de la targeta (hex o nom CSS) */
  defaultColor: string

  /**
   * Permís mínim per VEURE events d'aquest tipus.
   * Usat pel component per mostrar/amagar la targeta (UI layer, no BD).
   */
  viewPermission: PermissionKey

  /**
   * Permís mínim per EDITAR events d'aquest tipus.
   * Usat pel hook usePermission(editPermission, event.site_id) al clicar la targeta.
   */
  editPermission: PermissionKey

  /**
   * Icona del mòdul (component React o string d'emoji).
   * Opcional: si no s'especifica, el CalendarWidget omiteix la icona.
   */
  icon?: React.ReactNode | string

  /**
   * Renderitzador personalitzat de la targeta de l'event.
   * Si no s'especifica, el CalendarWidget usa el renderitzador per defecte.
   *
   * @param event - La fila completa de l'event
   * @param canEdit - Si l'usuari té permís d'edició en el site concret
   */
  renderCard?: (event: CalendarEventRow, canEdit: boolean) => React.ReactNode

  /**
   * Component de modal per als detalls de l'event.
   * Si no s'especifica, el CalendarWidget no obre cap modal en fer clic.
   *
   * @param event - La fila completa de l'event
   * @param canEdit - Si l'usuari té permís d'edició
   * @param onClose - Callback per tancar el modal
   */
  DetailModal?: React.ComponentType<{
    event: CalendarEventRow
    canEdit: boolean
    onClose: () => void
  }>
}

/**
 * Event resolt per a UI (join conceptual entre fila de BD i Registry).
 */
export interface CalendarResolvedEvent extends CalendarEventRow {
  moduleDefinition?: CalendarModuleDefinition
  resolvedLabel: string
  resolvedColor: string
  resolvedIcon?: React.ReactNode | string
  addonUnavailable: boolean
  viewPermission: PermissionKey
  editPermission: PermissionKey
}
