import { useLocation } from 'react-router-dom'

export const FIELD_ADMIN_PATHS = {
  templates: {
    field: '/field/checklist-templates',
    settings: '/settings/field/checklist-templates',
  },
  points: {
    field: '/field/checklist-points',
    settings: '/settings/field/checklist-points',
  },
  responseSets: {
    field: '/field/response-sets',
    settings: '/settings/field/response-sets',
  },
} as const

export type FieldAdminKind = keyof typeof FIELD_ADMIN_PATHS

export function isFieldSettingsPath(pathname: string): boolean {
  return pathname === '/settings/field' || pathname.startsWith('/settings/field/')
}

export function fieldAdminPath(kind: FieldAdminKind, pathname: string): string {
  const pair = FIELD_ADMIN_PATHS[kind]
  return isFieldSettingsPath(pathname) ? pair.settings : pair.field
}

export function fieldAdminBackTo(pathname: string): string {
  return isFieldSettingsPath(pathname) ? '/settings/config' : '/field/more'
}

export function fieldAdminPageClassName(
  pathname: string,
  extras = 'space-y-4',
): string {
  if (isFieldSettingsPath(pathname)) {
    return `mx-auto max-w-5xl ${extras}`
  }
  return `mx-auto max-w-5xl ${extras} px-4 py-6 pb-24`
}

export function useFieldAdminPaths(extras = 'space-y-4') {
  const { pathname } = useLocation()
  return {
    inSettings: isFieldSettingsPath(pathname),
    templates: fieldAdminPath('templates', pathname),
    points: fieldAdminPath('points', pathname),
    responseSets: fieldAdminPath('responseSets', pathname),
    pageClassName: fieldAdminPageClassName(pathname, extras),
  }
}
