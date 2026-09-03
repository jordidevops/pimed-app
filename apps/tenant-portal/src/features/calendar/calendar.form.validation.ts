// =============================================================================
// calendar.form.validation.ts — Constants i validadors per al formulari
// =============================================================================
// Validacions del costat del client (UI layer). La RPC farà validacions
// addicionals del costat del servidor (autenticació, permisos, BD).
// =============================================================================

import type { CreateEventFormInput, FormValidationError, ReminderInput } from './calendar.form.types'
import type { Database } from '@/types/database.types'

type CreateCalendarEventWithRemindersArgs =
  Database['api']['Functions']['create_calendar_event_with_reminders']['Args']

// ============================================================================
// Constants
// ============================================================================

/** Offsets recomanats (minuts) per a recordatoris pre-configurats */
export const REMINDER_PRESETS = [
  { label: '5 min', value: 5 },
  { label: '30 min', value: 30 },
  { label: '1 hora', value: 60 },
  { label: '1 dia', value: 1440 },
] as const

/** Màxim nombre de recordatoris per event */
export const MAX_REMINDERS = 5

/** Llargada màxima del títol (ha de coincidir amb BD) */
export const MAX_TITLE_LENGTH = 255

/** Llargada màxima de la descripció */
export const MAX_DESCRIPTION_LENGTH = 2000

/** Minuts mínims per offset (0 = exactament a l'hora) */
export const MIN_OFFSET_MINUTES = 0

/** Minuts màxims per offset (10080 = 7 dies) */
export const MAX_OFFSET_MINUTES = 10080

/** Canals d'entrega suportats en UI */
export const REMINDER_CHANNELS = ['email', 'push', 'sms'] as const

/** Canals operatius ara (push i sms mostren "properament") */
export const OPERATIONAL_CHANNELS = ['email'] as const

// ============================================================================
// Validadors
// ============================================================================

/**
 * Validar títol.
 * @returns Error message key or null if valid
 */
export function validateTitle(title: string | null | undefined): string | null {
  if (!title || title.trim().length === 0) {
    return 'calendar.validation.titleRequired'
  }
  if (title.length > MAX_TITLE_LENGTH) {
    return 'calendar.validation.titleTooLong'
  }
  return null
}

/**
 * Validar descripció (opcional).
 * @returns Error message key or null if valid
 */
export function validateDescription(desc: string | null | undefined): string | null {
  if (!desc) return null // Optional
  if (desc.length > MAX_DESCRIPTION_LENGTH) {
    return 'calendar.validation.descriptionTooLong'
  }
  return null
}

/**
 * Validar data d'inici.
 * @returns Error message key or null if valid
 */
export function validateStartDate(date: Date | null | undefined): string | null {
  if (!date) {
    return 'calendar.validation.invalidStartDate'
  }
  if (!(date instanceof Date) || isNaN(date.getTime())) {
    return 'calendar.validation.invalidStartDate'
  }
  return null
}

/**
 * Validar data de fi (opcional).
 * @returns Error message key or null if valid
 */
export function validateEndDate(
  endDate: Date | null | undefined,
  startDate: Date,
): string | null {
  if (!endDate) return null // Optional

  if (!(endDate instanceof Date) || isNaN(endDate.getTime())) {
    return 'calendar.validation.invalidEndDate'
  }

  if (endDate.getTime() < startDate.getTime()) {
    return 'calendar.validation.endBeforeStart'
  }

  return null
}

/**
 * Validar un recordatori individual.
 * @returns Error message key or null if valid
 */
export function validateReminder(reminder: ReminderInput | null | undefined): string | null {
  if (!reminder) return null

  const { offset_minutes } = reminder

  if (typeof offset_minutes !== 'number' || isNaN(offset_minutes)) {
    return 'calendar.validation.offsetInvalid'
  }

  if (offset_minutes < MIN_OFFSET_MINUTES || offset_minutes > MAX_OFFSET_MINUTES) {
    return 'calendar.validation.offsetInvalid'
  }

  return null
}

/**
 * Validar array de recordatoris.
 * @returns Error message key or null if valid
 */
export function validateReminders(reminders: ReminderInput[] | null | undefined): string | null {
  if (!reminders || reminders.length === 0) {
    return null // Optional
  }

  if (reminders.length > MAX_REMINDERS) {
    return 'calendar.validation.maxRemindersExceeded'
  }

  // Validar cada recordatori
  for (const reminder of reminders) {
    const err = validateReminder(reminder)
    if (err) return err
  }

  return null
}

/**
 * Validar tot el formulari.
 * @returns Array of validation errors (empty if valid)
 */
export function validateCreateEventForm(input: CreateEventFormInput): FormValidationError[] {
  const errors: FormValidationError[] = []

  // Validar títol
  const titleErr = validateTitle(input.title)
  if (titleErr) {
    errors.push({ field: 'title', message: titleErr })
  }

  // Validar descripció
  const descErr = validateDescription(input.description)
  if (descErr) {
    errors.push({ field: 'general', message: descErr })
  }

  // Validar start_at
  const startErr = validateStartDate(input.start_at)
  if (startErr) {
    errors.push({ field: 'start_at', message: startErr })
  }

  // Validar end_at (només si start_at és vàlid)
  if (!startErr && input.end_at) {
    const endErr = validateEndDate(input.end_at, input.start_at)
    if (endErr) {
      errors.push({ field: 'end_at', message: endErr })
    }
  }

  // Validar recordatoris
  const remindersErr = validateReminders(input.reminders)
  if (remindersErr) {
    errors.push({ field: 'reminders', message: remindersErr })
  }

  return errors
}

// ============================================================================
// Mappers (UI → RPC payload)
// ============================================================================

/**
 * Convertir entrada del formulari a payload de la RPC.
 * Assumeix que el formulari ja ha estat validat.
 */
export function mapFormToRpcPayload(
  input: CreateEventFormInput,
  tenantId: string,
  siteId?: string | null,
): CreateCalendarEventWithRemindersArgs {
  const payload: CreateCalendarEventWithRemindersArgs = {
    p_tenant_id: tenantId,
    p_entity_type: 'manual' as const,
    p_entity_id: crypto.randomUUID(), // Temporal; la RPC usarà el calendar_events.id real
    p_title: input.title,
    p_description: input.description || undefined,
    p_start_at: input.start_at.toISOString(),
    p_end_at: input.end_at ? input.end_at.toISOString() : undefined,
    p_all_day: input.all_day ?? false,
    p_color: input.color || undefined,
    p_site_id: siteId || undefined,
    p_reminders: input.reminders.map((r) => ({
      offset_minutes: r.offset_minutes,
      channel: r.channel,
    })),
  }

  return payload
}
