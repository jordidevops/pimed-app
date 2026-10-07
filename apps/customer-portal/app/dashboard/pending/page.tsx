import { I18nProvider } from '@/components/I18nProvider'
import { DashboardGate } from '@/components/DashboardBulletinList'
import { PendingDecisionsPageView } from '@/components/PendingDecisionsPageView'
import { PLATFORM_FALLBACK_LOCALE, resolveUiLocale } from '@/lib/locale'
import {
  exchangeStaffToken,
  resolveCommercialSession,
  resolveGrantSession,
} from '@/lib/resolver'
import { uiLocaleFromResolve } from '@/lib/resolve-ui-locale'
import { readActorCookie, readSessionCookie, readUiLocaleCookie } from '@/lib/session'

export default async function PendingDecisionsPage() {
  const session = await readSessionCookie()
  const actor = await readActorCookie()
  const cookieLocale = await readUiLocaleCookie()

  if (!session || (actor !== 'grant' && actor !== 'staff')) {
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

  const sessionResult =
    actor === 'staff'
      ? await exchangeStaffToken(session)
      : await resolveGrantSession(session, 'list_bulletins')

  if (!sessionResult.ok) {
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

  if (
    actor === 'staff' &&
    sessionResult.scope_mode &&
    sessionResult.scope_mode !== 'client_account'
  ) {
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

  const list = await resolveCommercialSession({
    sessionToken: session,
    action: 'list_pending_decisions',
    limit: 50,
  })

  const { uiLocale, supported, allowClientLocaleChange } = uiLocaleFromResolve(
    sessionResult,
    actor === 'staff' ? undefined : cookieLocale,
  )

  const items = list.ok ? (list.pending_items ?? []) : []
  const count = list.ok
    ? (list.pending_decisions_count ?? items.length)
    : 0

  return (
    <I18nProvider uiLocale={uiLocale}>
      <PendingDecisionsPageView
        items={items}
        count={count}
        modules={list.ok ? list.modules : undefined}
        uiLocale={uiLocale}
        allowClientLocaleChange={actor === 'grant' && allowClientLocaleChange}
        supportedLocales={supported}
        accountContactId={sessionResult.client_account_contact_id}
        tenantId={sessionResult.tenant_id}
        tenantProfile={
          sessionResult.tenant_profile ??
          sessionResult.access_activity?.tenant_profile
        }
        staffPreview={actor === 'staff'}
      />
    </I18nProvider>
  )
}
