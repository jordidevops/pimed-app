// =============================================================================
// calendar.form.types.ts — Tipus del formulari de creació d'events
// =============================================================================
// Contracte entre UI (formulari) i RPC (api.create_calendar_event_with_reminders).
// =============================================================================

/**
 * Entrada única d'un recordatori del formulari.
 * Mapeja directament a l'element de p_reminders[] de la RPC.
 */
export interface ReminderInput {
  /** Minuts abans de start_at per enviar el recordatori */
  offset_minutes: number

  /** Canal d'entrega: 'email' operatiu; 'push' i 'sms' com a preparació */
  channel: 'email' | 'push' | 'sms'

  /** ID únic temporal per identificar la fila en el formulari (no es passa a RPC) */
  _tempId?: string
}

/**
 * Payload del formulari de creació d'event.
 * Mapeja als paràmetres de api.create_calendar_event_with_reminders.
 */
export interface CreateEventFormInput {
  /** Títol del event (obligatori) */
  title: string

  /** Descripció opcional */
  description?: string | null

  /** Data i hora inici (obligatori) */
  start_at: Date

  /** Data i hora fi (opcional) */
  end_at?: Date | null

  /** Si és event de tot el dia */
  all_day?: boolean

  /** Color de la targeta (opcional; per defecte, usa el color del registry) */
  color?: string | null

  /** Recordatoris a encuar */
  reminders: ReminderInput[]
}

/**
 * Payload preparat per la RPC (convertit des del formulari).
 * Els valors són já serialitzables (dates com a ISO strings, etc.).
 */
export interface CreateEventRpcPayload {
  p_tenant_id: string
  p_entity_type: 'manual' // Always 'manual' for widget-created events
  p_entity_id: string // UUID temporal que la RPC genararà a la BD
  p_title: string
  p_description?: string | null
  p_start_at: string // ISO timestamp
  p_end_at?: string | null
  p_all_day?: boolean
  p_color?: string | null
  p_site_id?: string | null
  p_reminders: Array<{
    offset_minutes: number
    channel: 'email' | 'push' | 'sms'
  }>
}

/**
 * Resposta de la RPC api.create_calendar_event_with_reminders.
 */
export interface CreateEventRpcResponse {
  event_id: string // UUID del nou event
  reminders: number // Count de recordatoris encuats
}

/**
 * Error de validació del formulari.
 */
export interface FormValidationError {
  field: 'title' | 'start_at' | 'end_at' | 'reminders' | 'general'
  message: string // Clau i18n com 'calendar.validation.titleRequired'
}
