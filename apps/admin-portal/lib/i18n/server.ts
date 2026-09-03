/**
 * Server-side translation helper for React Server Components.
 * Since hooks cannot be used in RSC, this utility provides the same
 * t(key, fallback) pattern by resolving keys from the locale JSON files.
 *
 * For a single-language (Catalan) app, the fallback IS the displayed text.
 * The key serves as a stable identifier for future multi-language support.
 */

import type commonCaType from '@/locales/ca/common.json'
import type authCaType from '@/locales/ca/auth.json'
import type dashboardCaType from '@/locales/ca/dashboard.json'
import type tenantsCaType from '@/locales/ca/tenants.json'
import type settingsCaType from '@/locales/ca/settings.json'
import type storageCaType from '@/locales/ca/storage.json'
import type monetitzacioCaType from '@/locales/ca/monetitzacio.json'
import type emailLogsCaType from '@/locales/ca/email_logs.json'
import type activityCaType from '@/locales/ca/activity.json'

/* eslint-disable @typescript-eslint/no-require-imports */
const namespaces: Record<string, Record<string, unknown>> = {
  common: require('@/locales/ca/common.json') as typeof commonCaType,
  auth: require('@/locales/ca/auth.json') as typeof authCaType,
  dashboard: require('@/locales/ca/dashboard.json') as typeof dashboardCaType,
  tenants: require('@/locales/ca/tenants.json') as typeof tenantsCaType,
  settings: require('@/locales/ca/settings.json') as typeof settingsCaType,
  storage: require('@/locales/ca/storage.json') as typeof storageCaType,
  monetitzacio: require('@/locales/ca/monetitzacio.json') as typeof monetitzacioCaType,
  email_logs: require('@/locales/ca/email_logs.json') as typeof emailLogsCaType,
  activity: require('@/locales/ca/activity.json') as typeof activityCaType,
}
/* eslint-enable @typescript-eslint/no-require-imports */

function lookupNested(obj: Record<string, unknown>, key: string): string | undefined {
  const parts = key.split('.')
  let current: unknown = obj
  for (const part of parts) {
    if (typeof current !== 'object' || current === null) return undefined
    current = (current as Record<string, unknown>)[part]
  }
  return typeof current === 'string' ? current : undefined
}

/**
 * Returns a t() function scoped to the given namespace.
 *
 * Usage in Server Components:
 *   const t = getT('dashboard')
 *   <h1>{t('dashboard.title', 'Visió general')}</h1>
 */
export function getT(namespace: string): (key: string, fallback: string) => string {
  const dict = namespaces[namespace] ?? {}
  return function t(key: string, fallback: string): string {
    // Strip the namespace prefix if the caller includes it (e.g. 'dashboard.title')
    const lookupKey = key.startsWith(`${namespace}.`) ? key.slice(namespace.length + 1) : key
    return lookupNested(dict, lookupKey) ?? fallback
  }
}
