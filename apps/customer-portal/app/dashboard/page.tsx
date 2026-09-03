import { I18nProvider } from '@/components/I18nProvider'
import {
  DashboardBulletinList,
  DashboardGate,
} from '@/components/DashboardBulletinList'
import type { BulletinListItem } from '@/lib/constants'
import { PLATFORM_FALLBACK_LOCALE, resolveUiLocale } from '@/lib/locale'
import { resolveGrantSession } from '@/lib/resolver'
import { uiLocaleFromResolve } from '@/lib/resolve-ui-locale'
import { readActorCookie, readSessionCookie, readUiLocaleCookie } from '@/lib/session'

function parseBulletins(raw: unknown): BulletinListItem[] {
  if (!Array.isArray(raw)) return []
  const out: BulletinListItem[] = []
  for (const item of raw) {
    if (!item || typeof item !== 'object') continue
    const o = item as Record<string, unknown>
    const id = String(o.report_version_id ?? '')
    if (!id) continue
    out.push({
      report_version_id: id,
      report_id: o.report_id ? String(o.report_id) : undefined,
      project_id: o.project_id ? String(o.project_id) : undefined,
      version_number:
        typeof o.version_number === 'number' ? o.version_number : undefined,
      content_digest: o.content_digest ? String(o.content_digest) : undefined,
      locale: o.locale ? String(o.locale) : undefined,
      published_at: o.published_at ? String(o.published_at) : undefined,
      title: o.title ? String(o.title) : undefined,
      media_count: typeof o.media_count === 'number' ? o.media_count : undefined,
    })
  }
  return out
}

export default async function DashboardPage() {
  const session = await readSessionCookie()
  const actor = await readActorCookie()
  const cookieLocale = await readUiLocaleCookie()

  if (!session || actor !== 'grant') {
    const uiLocale = resolveUiLocale({
      preferred: null,
      supported: ['ca', 'es', 'en'],
      defaultLocale: PLATFORM_FALLBACK_LOCALE,
      cookieLocale,
    })
    return (
      <I18nProvider uiLocale={uiLocale}>
        <DashboardGate variant="need_session" />
      </I18nProvider>
    )
  }

  const result = await resolveGrantSession(session, 'list_bulletins')
  if (!result.ok) {
    const uiLocale = resolveUiLocale({
      preferred: null,
      supported: ['ca', 'es', 'en'],
      defaultLocale: PLATFORM_FALLBACK_LOCALE,
      cookieLocale,
    })
    return (
      <I18nProvider uiLocale={uiLocale}>
        <DashboardGate variant="expired" />
      </I18nProvider>
    )
  }

  const { uiLocale, supported, allowClientLocaleChange } = uiLocaleFromResolve(
    result,
    cookieLocale,
  )
  const bulletins = parseBulletins(result.bulletins)

  return (
    <I18nProvider uiLocale={uiLocale}>
      <DashboardBulletinList
        bulletins={bulletins}
        uiLocale={uiLocale}
        allowClientLocaleChange={allowClientLocaleChange}
        supportedLocales={supported}
        accountContactId={result.client_account_contact_id}
        tenantId={result.tenant_id}
        tenantProfile={result.tenant_profile ?? result.access_activity?.tenant_profile}
      />
    </I18nProvider>
  )
}
