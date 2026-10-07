import { I18nProvider } from '@/components/I18nProvider'
import { DashboardGate } from '@/components/DashboardBulletinList'
import {
  PendingDecisionDetailView,
  PendingDecisionUnavailable,
} from '@/components/PendingDecisionDetailView'
import { PLATFORM_FALLBACK_LOCALE, resolveUiLocale } from '@/lib/locale'
import {
  exchangeStaffToken,
  resolveGrantSession,
  resolvePendingDecisionDetail,
} from '@/lib/resolver'
import { uiLocaleFromResolve } from '@/lib/resolve-ui-locale'
import { readActorCookie, readSessionCookie, readUiLocaleCookie } from '@/lib/session'

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

export default async function PendingDecisionDetailPage({
  params,
}: {
  params: Promise<{ id: string }>
}) {
  const { id } = await params
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

  if (!UUID_RE.test(id)) {
    const uiLocale = resolveUiLocale({
      preferred: null,
      supported: ['ca', 'es', 'en'],
      defaultLocale: PLATFORM_FALLBACK_LOCALE,
      cookieLocale,
    })
    return (
      <I18nProvider uiLocale={uiLocale}>
        <PendingDecisionUnavailable variant="not_found" />
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

  const detailResult = await resolvePendingDecisionDetail({
    sessionToken: session,
    requestId: id,
  })

  const { uiLocale, supported, allowClientLocaleChange } = uiLocaleFromResolve(
    sessionResult,
    actor === 'staff' ? undefined : cookieLocale,
  )

  if (!detailResult.ok) {
    return (
      <I18nProvider uiLocale={uiLocale}>
        <PendingDecisionUnavailable variant="not_found" />
      </I18nProvider>
    )
  }

  return (
    <I18nProvider uiLocale={uiLocale}>
      <PendingDecisionDetailView
        detail={detailResult.pending_detail}
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
        principalKind={detailResult.principal_kind}
      />
    </I18nProvider>
  )
}
