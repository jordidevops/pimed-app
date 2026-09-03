import type { TFunction } from 'i18next'

export const PROJECT_STATUS_VALUES = ['draft', 'in_progress', 'active', 'on_hold', 'completed', 'cancelled'] as const

export type ProjectStatus = (typeof PROJECT_STATUS_VALUES)[number]

export const PROJECT_STATUS_VARIANTS: Record<ProjectStatus, 'default' | 'secondary' | 'destructive' | 'outline'> = {
  draft: 'outline',
  in_progress: 'outline',
  active: 'outline',
  on_hold: 'outline',
  completed: 'outline',
  cancelled: 'outline',
}

// Tailwind colour overrides so each status gets a distinct look
export const PROJECT_STATUS_CLASS: Record<ProjectStatus, string> = {
  draft:       'border-slate-400 text-slate-600 dark:border-slate-500 dark:text-slate-400',
  in_progress: 'border-blue-400 bg-blue-50 text-blue-700 dark:border-blue-500 dark:bg-blue-950/40 dark:text-blue-300',
  active:      'border-green-400 bg-green-50 text-green-700 dark:border-green-500 dark:bg-green-950/40 dark:text-green-300',
  on_hold:     'border-amber-400 bg-amber-50 text-amber-700 dark:border-amber-500 dark:bg-amber-950/40 dark:text-amber-300',
  completed:   'border-violet-400 bg-violet-50 text-violet-700 dark:border-violet-500 dark:bg-violet-950/40 dark:text-violet-300',
  cancelled:   'border-red-400 bg-red-50 text-red-700 dark:border-red-500 dark:bg-red-950/40 dark:text-red-300',
}

export const PROJECT_STATUS_FALLBACK_LABELS: Record<ProjectStatus, string> = {
  draft: 'Esborrany',
  in_progress: 'En curs',
  active: 'Actiu',
  on_hold: 'En espera',
  completed: 'Completat',
  cancelled: 'Cancel·lat',
}

/** UI labels for field_service (same CHECK values; no SQL change). */
export const FIELD_SERVICE_STATUS_LABELS: Record<ProjectStatus, string> = {
  draft: 'Pressupost',
  in_progress: 'En curs',
  active: 'En curs',
  on_hold: 'En espera',
  completed: 'Completat',
  cancelled: 'Cancel·lat',
}

export function getProjectStatusLabel(
  t: TFunction,
  status: string | null | undefined,
  opts?: { fieldService?: boolean },
): string {
  if (!status) return '—'
  const normalized = PROJECT_STATUS_VALUES.includes(status as ProjectStatus)
    ? (status as ProjectStatus)
    : null
  if (!normalized) return status
  if (opts?.fieldService) {
    return t(`field-service:status.${normalized}`, FIELD_SERVICE_STATUS_LABELS[normalized])
  }
  return t(`projects.status.${normalized}`, PROJECT_STATUS_FALLBACK_LABELS[normalized])
}

/** Open statuses that count as "scheduled" when planned_start is set. */
export const PROJECT_OPEN_STATUSES: ProjectStatus[] = [
  'draft',
  'in_progress',
  'active',
  'on_hold',
]

export function getProjectStatusVariant(status: string | null | undefined): 'default' | 'secondary' | 'destructive' | 'outline' {
  if (!status) return 'outline'
  return PROJECT_STATUS_VARIANTS[status as ProjectStatus] ?? 'outline'
}

export function getProjectStatusClass(status: string | null | undefined): string {
  if (!status) return ''
  return PROJECT_STATUS_CLASS[status as ProjectStatus] ?? ''
}
