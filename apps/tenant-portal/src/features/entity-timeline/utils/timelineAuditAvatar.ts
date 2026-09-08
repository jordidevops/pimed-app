import type { LucideIcon } from 'lucide-react'
import {
  Archive,
  ArrowRightLeft,
  BadgeCheck,
  Bell,
  BookOpen,
  BookUser,
  CalendarCheck,
  CalendarDays,
  CalendarX,
  CheckSquare,
  Clock,
  Cog,
  Eye,
  FileSignature,
  FilePenLine,
  FileText,
  HeartPulse,
  Link,
  LogIn,
  ScrollText,
  Smartphone,
  Trash2,
  Unlink,
  UserMinus,
  UserPen,
  UserPlus,
} from 'lucide-react'
import type { TimelineAuditItem } from '../api/timelineService'

const slateIcon =
  'bg-slate-100 text-slate-700 dark:bg-slate-800 dark:text-slate-200'
const emeraldIcon =
  'bg-emerald-100 text-emerald-800 dark:bg-emerald-900/40 dark:text-emerald-200'
const skyIcon =
  'bg-sky-100 text-sky-800 dark:bg-sky-900/40 dark:text-sky-200'
const blueIcon =
  'bg-blue-100 text-blue-800 dark:bg-blue-900/40 dark:text-blue-200'
const amberIcon =
  'bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-200'
const roseIcon =
  'bg-rose-100 text-rose-800 dark:bg-rose-900/40 dark:text-rose-200'
const violetIcon =
  'bg-violet-100 text-violet-800 dark:bg-violet-900/40 dark:text-violet-200'

export interface AuditAvatarIconConfig {
  Icon: LucideIcon
  className: string
  labelKey: string
  labelDefault: string
}

export type ResolvedTimelineAuditAvatar =
  | {
      type: 'initial'
      label: string
      initial: string
      className: string
    }
  | ({
      type: 'icon'
    } & AuditAvatarIconConfig)

const PORTAL_EMPLOYEE: AuditAvatarIconConfig = {
  Icon: Smartphone,
  className: emeraldIcon,
  labelKey: 'timeline.audit_avatar.portal_employee',
  labelDefault: 'Portal empleat',
}

const SYSTEM: AuditAvatarIconConfig = {
  Icon: Cog,
  className: slateIcon,
  labelKey: 'timeline.audit_avatar.system',
  labelDefault: 'Sistema',
}

const AUTOMATION: AuditAvatarIconConfig = {
  Icon: Cog,
  className: skyIcon,
  labelKey: 'timeline.audit_avatar.automation',
  labelDefault: 'Automatització',
}

const ACTION_AVATARS: Record<string, AuditAvatarIconConfig> = {
  ATTENDANCE_PROTOCOL_ACKNOWLEDGED: {
    Icon: ScrollText,
    className: emeraldIcon,
    labelKey: 'timeline.audit_avatar.protocol_read',
    labelDefault: 'Protocol llegit',
  },
  ATTENDANCE_PROTOCOL_PUBLISHED: {
    Icon: FileText,
    className: blueIcon,
    labelKey: 'timeline.audit_avatar.protocol_published',
    labelDefault: 'Protocol publicat',
  },
  ATTENDANCE_MONTH_EMPLOYEE_CONFIRMED: {
    Icon: CalendarDays,
    className: emeraldIcon,
    labelKey: 'timeline.audit_avatar.monthly_confirm',
    labelDefault: 'Confirmació mensual',
  },
  ATTENDANCE_MONTH_MANAGER_CLOSED: {
    Icon: Clock,
    className: blueIcon,
    labelKey: 'timeline.audit_avatar.monthly_close',
    labelDefault: 'Tancament mensual',
  },
  ATTENDANCE_PERIOD_EMPLOYEE_CONFIRMED: {
    Icon: CalendarDays,
    className: emeraldIcon,
    labelKey: 'timeline.audit_avatar.period_confirm',
    labelDefault: 'Confirmació període',
  },
  ATTENDANCE_MONTH_SIGNING_STARTED: {
    Icon: FileSignature,
    className: violetIcon,
    labelKey: 'timeline.audit_avatar.signing_started',
    labelDefault: 'Signatura iniciada',
  },
  ATTENDANCE_MONTH_SIGNED: {
    Icon: BadgeCheck,
    className: violetIcon,
    labelKey: 'timeline.audit_avatar.monthly_signed',
    labelDefault: 'Registre signat',
  },
  ATTENDANCE_MONTH_AMENDMENT_REGISTERED: {
    Icon: FilePenLine,
    className: amberIcon,
    labelKey: 'timeline.audit_avatar.monthly_amendment',
    labelDefault: 'Esmena mensual',
  },
  ATTENDANCE_IT_REGISTERED: {
    Icon: HeartPulse,
    className: roseIcon,
    labelKey: 'timeline.audit_avatar.it_registered',
    labelDefault: 'Baixa IT',
  },
  ATTENDANCE_IT_CLOSED: {
    Icon: HeartPulse,
    className: roseIcon,
    labelKey: 'timeline.audit_avatar.it_closed',
    labelDefault: 'IT tancada',
  },
  ATTENDANCE_ABSENCE_APPROVED: {
    Icon: CalendarCheck,
    className: amberIcon,
    labelKey: 'timeline.audit_avatar.absence_approved',
    labelDefault: 'Absència aprovada',
  },
  ATTENDANCE_ABSENCE_REJECTED: {
    Icon: CalendarX,
    className: amberIcon,
    labelKey: 'timeline.audit_avatar.absence_rejected',
    labelDefault: 'Absència rebutjada',
  },
  EMPLOYEE_PORTAL_FIRST_ACCESS: {
    Icon: LogIn,
    className: emeraldIcon,
    labelKey: 'timeline.audit_avatar.portal_first_access',
    labelDefault: 'Primer accés al portal',
  },
  EMPLOYEE_PORTAL_TOKEN_CREATED: {
    Icon: Link,
    className: blueIcon,
    labelKey: 'timeline.audit_avatar.portal_link_created',
    labelDefault: 'Enllaç de portal',
  },
  EMPLOYEE_PORTAL_TOKEN_REVOKED: {
    Icon: Unlink,
    className: slateIcon,
    labelKey: 'timeline.audit_avatar.portal_link_revoked',
    labelDefault: 'Enllaç de portal revocat',
  },
  EMPLOYEE_CREATED: {
    Icon: UserPlus,
    className: blueIcon,
    labelKey: 'timeline.audit_avatar.employee_created',
    labelDefault: 'Alta d\'empleat',
  },
  EMPLOYEE_TERMINATED: {
    Icon: UserMinus,
    className: slateIcon,
    labelKey: 'timeline.audit_avatar.employee_terminated',
    labelDefault: 'Baixa d\'empleat',
  },
  EMPLOYEE_DELETED: {
    Icon: Trash2,
    className: slateIcon,
    labelKey: 'timeline.audit_avatar.employee_deleted',
    labelDefault: 'Empleat eliminat',
  },
  EMPLOYEE_UPDATED: {
    Icon: UserPen,
    className: slateIcon,
    labelKey: 'timeline.audit_avatar.employee_updated',
    labelDefault: 'Dades d\'empleat',
  },
  'employees.reveal_iban': {
    Icon: Eye,
    className: slateIcon,
    labelKey: 'timeline.audit_avatar.reveal_iban',
    labelDefault: 'Consulta IBAN',
  },
  'employees.reveal_social_security_number': {
    Icon: Eye,
    className: slateIcon,
    labelKey: 'timeline.audit_avatar.reveal_ssn',
    labelDefault: 'Consulta NSS',
  },
  CONTACT_CREATED: {
    Icon: BookUser,
    className: blueIcon,
    labelKey: 'timeline.audit_avatar.contact_created',
    labelDefault: 'Contacte nou',
  },
  CONTACT_UPDATED: {
    Icon: UserPen,
    className: slateIcon,
    labelKey: 'timeline.audit_avatar.contact_updated',
    labelDefault: 'Contacte actualitzat',
  },
  CONTACT_ARCHIVED: {
    Icon: Archive,
    className: slateIcon,
    labelKey: 'timeline.audit_avatar.contact_archived',
    labelDefault: 'Contacte arxivat',
  },
  CONTACT_UNARCHIVED: {
    Icon: Archive,
    className: blueIcon,
    labelKey: 'timeline.audit_avatar.contact_unarchived',
    labelDefault: 'Contacte recuperat',
  },
  COMMENT_TASK_RESOLVED: {
    Icon: CheckSquare,
    className: amberIcon,
    labelKey: 'timeline.audit_avatar.task_resolved',
    labelDefault: 'Tasca resolta',
  },
  PROJECT_STATUS_CHANGED: {
    Icon: ArrowRightLeft,
    className: blueIcon,
    labelKey: 'timeline.audit_avatar.project_status',
    labelDefault: 'Estat del projecte',
  },
  PROJECT_NOTIFICATIONS_SENT: {
    Icon: Bell,
    className: skyIcon,
    labelKey: 'timeline.audit_avatar.notifications_sent',
    labelDefault: 'Notificacions enviades',
  },
  CLIENT_REPORT_PUBLISHED: {
    Icon: FileSignature,
    className: emeraldIcon,
    labelKey: 'timeline.audit_avatar.client_report_published',
    labelDefault: 'Butlletí publicat',
  },
  CLIENT_REPORT_VERSION_CREATED: {
    Icon: FileSignature,
    className: emeraldIcon,
    labelKey: 'timeline.audit_avatar.client_report_version',
    labelDefault: 'Nova versió del butlletí',
  },
  CLIENT_REPORT_SHARE_CREATED: {
    Icon: Link,
    className: skyIcon,
    labelKey: 'timeline.audit_avatar.client_report_share',
    labelDefault: 'Compartició del butlletí',
  },
  CLIENT_REPORT_SHARE_EMAIL_ENQUEUED: {
    Icon: FileText,
    className: skyIcon,
    labelKey: 'timeline.audit_avatar.client_report_email',
    labelDefault: 'Email del butlletí',
  },
  CLIENT_REPORT_SHARE_REVOKED: {
    Icon: Unlink,
    className: amberIcon,
    labelKey: 'timeline.audit_avatar.client_report_revoke',
    labelDefault: 'Compartició revocada',
  },
  CLIENT_REPORT_STAFF_SESSION_CREATED: {
    Icon: Eye,
    className: blueIcon,
    labelKey: 'timeline.audit_avatar.client_report_staff',
    labelDefault: 'Portal del client',
  },
  ATTENDANCE_COMPENSATION_RECORDED: {
    Icon: BookOpen,
    className: violetIcon,
    labelKey: 'timeline.audit_avatar.compensation',
    labelDefault: 'Compensació',
  },
}

/** Accions típiques del portal empleat sense actor humà al audit log. */
const PORTAL_SELF_SERVICE_ACTIONS = new Set([
  'ATTENDANCE_PROTOCOL_ACKNOWLEDGED',
  'EMPLOYEE_PORTAL_FIRST_ACCESS',
])

export function resolveTimelineAuditAvatar(
  item: TimelineAuditItem,
): ResolvedTimelineAuditAvatar {
  const actorName = item.actor?.full_name?.trim()
  if (actorName) {
    return {
      type: 'initial',
      label: actorName,
      initial: actorName.slice(0, 1).toUpperCase(),
      className: 'bg-muted text-foreground font-medium',
    }
  }

  const payloadSource = item.message_vars?.source ?? item.payload?.source
  if (
    payloadSource === 'employee_portal' ||
    PORTAL_SELF_SERVICE_ACTIONS.has(item.action)
  ) {
    const portalConfig = ACTION_AVATARS[item.action] ?? PORTAL_EMPLOYEE
    return { type: 'icon', ...portalConfig }
  }

  const byAction = ACTION_AVATARS[item.action]
  if (byAction) {
    return { type: 'icon', ...byAction }
  }

  if (item.is_background) {
    return { type: 'icon', ...AUTOMATION }
  }

  return { type: 'icon', ...SYSTEM }
}
