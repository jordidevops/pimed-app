import type { TFunction } from 'i18next'

const FIELD_LABELS: Record<string, string> = {
  full_name: 'nom',
  status: 'estat',
  job_position_id: 'Lloc de treball',
  job_title: 'Lloc de treball',
  department_id: 'departament',
  site_id: 'local',
  weekly_hours: 'hores setmanals',
  email: 'email',
  phone: 'telèfon',
  document_id: 'document',
  starts_on: 'data d\'alta',
  ends_on: 'data de baixa',
}

function formatYearMonth(payload: Record<string, unknown>): string {
  const year = payload.year
  const month = payload.month
  if (typeof year === 'number' && typeof month === 'number') {
    return `${year}-${String(month).padStart(2, '0')}`
  }
  return String(payload.period ?? '—')
}

function formatDateRange(payload: Record<string, unknown>): string {
  const start = payload.period_from ?? payload.start_date
  const end = payload.period_to ?? payload.end_date
  if (start && end) return `${start} — ${end}`
  if (start) return String(start)
  return '—'
}

function formatPeriodRangeDisplay(payload: Record<string, unknown>): string {
  const start = payload.period_from ?? payload.start_date
  const end = payload.period_to ?? payload.end_date
  if (!start || !end) return formatYearMonth(payload)

  const startDate = new Date(`${String(start)}T12:00:00`)
  const endDate = new Date(`${String(end)}T12:00:00`)
  const sameMonth =
    startDate.getMonth() === endDate.getMonth() &&
    startDate.getFullYear() === endDate.getFullYear()

  if (sameMonth) {
    return `${startDate.toLocaleDateString('ca-ES', { day: 'numeric' })} – ${endDate.toLocaleDateString('ca-ES', {
      day: 'numeric',
      month: 'long',
      year: 'numeric',
    })}`
  }

  return `${startDate.toLocaleDateString('ca-ES', {
    day: 'numeric',
    month: 'short',
  })} – ${endDate.toLocaleDateString('ca-ES', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  })}`
}

interface ChangeRow {
  field: string
  old?: unknown
  new?: unknown
}

/** PROJECT_UPDATED → UPDATED; CONTACT_CREATED → CREATED */
export function stripEntityActionPrefix(action: string): string {
  const idx = action.indexOf('_')
  if (idx <= 0 || idx === action.length - 1) return action
  return action.slice(idx + 1)
}

export function formatAuditMessage(
  t: TFunction,
  action: string,
  messageVars: Record<string, unknown>,
  actorName?: string | null,
): string {
  const name = String(messageVars.name ?? messageVars.full_name ?? actorName ?? '')
  const prefix = actorName ? `${actorName} ` : ''

  switch (action) {
    case 'EMPLOYEE_CREATED':
      return t('activity:audit.EMPLOYEE_CREATED', { name, defaultValue: `Empleat ${name} creat` })
    case 'EMPLOYEE_TERMINATED':
      return prefix + t('activity:audit.EMPLOYEE_TERMINATED', {
        name,
        ends_on: messageVars.ends_on ?? '—',
        defaultValue: `ha passat a baixa`,
      })
    case 'EMPLOYEE_DELETED':
      return t('activity:audit.EMPLOYEE_DELETED', { name, defaultValue: `${name} eliminat` })
    case 'EMPLOYEE_UPDATED':
    case 'CONTACT_UPDATED': {
      const changes = (messageVars.changes as ChangeRow[] | undefined) ?? []
      if (changes.length === 1) {
        const field = FIELD_LABELS[changes[0].field] ?? changes[0].field
        return prefix + t('activity:audit.EMPLOYEE_UPDATED_one', {
          field,
          defaultValue: `ha actualitzat ${field}`,
        })
      }
      if (changes.length > 1) {
        const fields = changes.map((c) => FIELD_LABELS[c.field] ?? c.field).join(', ')
        return prefix + t('activity:audit.EMPLOYEE_UPDATED_many', {
          count: changes.length,
          defaultValue: `ha actualitzat ${changes.length} camps: ${fields}`,
        })
      }
      return prefix + t('activity:audit.GENERIC', { action: stripEntityActionPrefix(action), defaultValue: stripEntityActionPrefix(action) })
    }
    case 'employees.reveal_iban':
      return prefix + t('activity:audit.employees_reveal_iban', {
        defaultValue: "ha consultat l'IBAN",
      })
    case 'employees.reveal_social_security_number':
      return prefix + t('activity:audit.employees_reveal_ssn', {
        defaultValue: 'ha consultat el núm. de la Seguretat Social',
      })
    case 'CONTACT_CREATED':
      return t('activity:audit.CONTACT_CREATED', { name, defaultValue: `Contacte ${name} creat` })
    case 'CONTACT_ARCHIVED':
      return t('activity:audit.CONTACT_ARCHIVED', { name, defaultValue: `Contacte ${name} arxivat` })
    case 'CONTACT_UNARCHIVED':
      return t('activity:audit.CONTACT_UNARCHIVED', { name, defaultValue: `Contacte ${name} desarxivat` })
    case 'COMMENT_TASK_RESOLVED':
      return t('activity:audit.TASK_RESOLVED', {
        task_preview: messageVars.task_preview ?? '',
        defaultValue: 'Tasca resolta',
      })
    case 'PROJECT_STATUS_CHANGED':
      return t('activity:audit.PROJECT_STATUS', {
        old: messageVars.old ?? '—',
        new: messageVars.new ?? '—',
        defaultValue: 'Canvi d\'estat del projecte',
      })
    case 'PROJECT_NOTIFICATIONS_SENT':
      return prefix + t('activity:audit.PROJECT_NOTIFICATIONS_SENT', {
        defaultValue: 'notificacions automàtiques enviades',
      })
    case 'ATTENDANCE_MONTH_EMPLOYEE_CONFIRMED':
      if (messageVars.source === 'employee_portal') {
        return t('activity:audit.ATTENDANCE_MONTH_EMPLOYEE_CONFIRMED_portal', {
          period: formatYearMonth(messageVars),
          defaultValue: 'Confirmació del registre mensual al portal personal ({{period}})',
        })
      }
      return prefix + t('activity:audit.ATTENDANCE_MONTH_EMPLOYEE_CONFIRMED', {
        period: formatYearMonth(messageVars),
        defaultValue: 'ha confirmat el registre mensual ({{period}})',
      })
    case 'ATTENDANCE_MONTH_MANAGER_CLOSED':
      return prefix + t('activity:audit.ATTENDANCE_MONTH_MANAGER_CLOSED', {
        period: formatYearMonth(messageVars),
        defaultValue: 'ha tancat el mes per nòmina ({{period}})',
      })
    case 'ATTENDANCE_MONTH_SIGNING_STARTED':
      return prefix + t('activity:audit.ATTENDANCE_MONTH_SIGNING_STARTED', {
        period: formatYearMonth(messageVars),
        defaultValue: 'ha iniciat la signatura del registre mensual ({{period}})',
      })
    case 'ATTENDANCE_MONTH_SIGNED':
      return prefix + t('activity:audit.ATTENDANCE_MONTH_SIGNED', {
        period: formatYearMonth(messageVars),
        defaultValue: 'registre mensual signat ({{period}})',
      })
    case 'ATTENDANCE_PERIOD_EMPLOYEE_CONFIRMED': {
      const range = formatPeriodRangeDisplay(messageVars)
      return prefix + t('activity:audit.ATTENDANCE_PERIOD_EMPLOYEE_CONFIRMED', {
        period_range: range,
        defaultValue: 'ha confirmat el registre ({{period_range}})',
      })
    }
    case 'ATTENDANCE_MONTH_AMENDMENT_REGISTERED': {
      const workDate = messageVars.work_date
      const workDateSuffix =
        workDate && typeof workDate === 'string' ? ` — ${workDate}` : ''
      return prefix + t('activity:audit.ATTENDANCE_MONTH_AMENDMENT_REGISTERED', {
        period: formatYearMonth(messageVars),
        work_date_suffix: workDateSuffix,
        defaultValue: 'ha registrat una esmena post-tancament ({{period}}){{work_date_suffix}}',
      })
    }
    case 'ATTENDANCE_IT_REGISTERED':
      return prefix + t('activity:audit.ATTENDANCE_IT_REGISTERED', {
        absence_type: messageVars.absence_type ?? 'IT',
        period: formatDateRange(messageVars),
        defaultValue: 'ha registrat una IT ({{absence_type}}) — {{period}}',
      })
    case 'ATTENDANCE_IT_CLOSED':
      return prefix + t('activity:audit.ATTENDANCE_IT_CLOSED', {
        period: formatDateRange(messageVars),
        defaultValue: 'ha tancat la IT — {{period}}',
      })
    case 'ATTENDANCE_ABSENCE_APPROVED':
      return prefix + t('activity:audit.ATTENDANCE_ABSENCE_APPROVED', {
        absence_type: messageVars.absence_type ?? 'absència',
        period: formatDateRange(messageVars),
        defaultValue: 'ha aprovat absència ({{absence_type}}) — {{period}}',
      })
    case 'ATTENDANCE_ABSENCE_REJECTED':
      return prefix + t('activity:audit.ATTENDANCE_ABSENCE_REJECTED', {
        absence_type: messageVars.absence_type ?? 'absència',
        period: formatDateRange(messageVars),
        defaultValue: 'ha rebutjat absència ({{absence_type}}) — {{period}}',
      })
    case 'ATTENDANCE_PROTOCOL_PUBLISHED':
      return prefix + t('activity:audit.ATTENDANCE_PROTOCOL_PUBLISHED', {
        defaultValue: 'ha publicat el protocol de registre horari al portal personal',
      })
    case 'ATTENDANCE_PROTOCOL_ACKNOWLEDGED':
      return t('activity:audit.ATTENDANCE_PROTOCOL_ACKNOWLEDGED', {
        defaultValue: 'Confirmació de lectura del protocol de registre horari al portal personal',
      })
    case 'ATTENDANCE_COMPENSATION_RECORDED': {
      const mins = messageVars.minutes
      const movementType = String(messageVars.movement_type ?? '')
      const signed =
        typeof mins === 'number'
          ? `${messageVars.is_credit ? '+' : '−'}${mins} min`
          : ''
      return prefix + t('activity:audit.ATTENDANCE_COMPENSATION_RECORDED', {
        movement: movementType,
        minutes: signed,
        defaultValue: 'ha registrat un moviment de compensació ({{movement}} {{minutes}})',
      })
    }
    case 'EMPLOYEE_PORTAL_TOKEN_CREATED':
      return prefix + t('activity:audit.EMPLOYEE_PORTAL_TOKEN_CREATED', {
        label: messageVars.label ?? '—',
        defaultValue: 'ha generat un enllaç del portal personal ({{label}})',
      })
    case 'EMPLOYEE_PORTAL_TOKEN_REVOKED':
      return prefix + t('activity:audit.EMPLOYEE_PORTAL_TOKEN_REVOKED', {
        label: messageVars.label ?? '—',
        defaultValue: 'ha revocat l\'enllaç del portal ({{label}})',
      })
    case 'EMPLOYEE_PORTAL_FIRST_ACCESS':
      return t('activity:audit.EMPLOYEE_PORTAL_FIRST_ACCESS', {
        label: messageVars.label ?? '—',
        defaultValue: 'primer accés al portal personal ({{label}})',
      })
    default:
      return prefix + t('activity:audit.GENERIC', {
        action: stripEntityActionPrefix(action),
        defaultValue: stripEntityActionPrefix(action),
      })
  }
}
