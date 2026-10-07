import { I18nProvider } from '@/components/I18nProvider'
import { DashboardGate } from '@/components/DashboardBulletinList'
import {
  CommercialDetailUnavailable,
  CommercialDetailView,
} from '@/components/CommercialDetailView'
import type { CommercialNavKey } from '@/components/CommercialCatalogueList'
import { PLATFORM_FALLBACK_LOCALE, resolveUiLocale } from '@/lib/locale'
import {
  exchangeStaffToken,
  resolveCommercialDetail,
  resolveGrantSession,
} from '@/lib/resolver'
import { uiLocaleFromResolve } from '@/lib/resolve-ui-locale'
import { readActorCookie, readSessionCookie, readUiLocaleCookie } from '@/lib/session'

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

export async function renderCommercialDetailPage(opts: {
  id: string
  action: 'get_quote_or_agreement' | 'get_delivery_note' | 'get_invoice'
  itemKind?: 'document' | 'agreement'
  current: CommercialNavKey
  backHref: string
  backLabelFallback: string
  backLabelKey: string
}) {
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

  if (!UUID_RE.test(opts.id)) {
    const uiLocale = resolveUiLocale({
      preferred: null,
      supported: ['ca', 'es', 'en'],
      defaultLocale: PLATFORM_FALLBACK_LOCALE,
      cookieLocale,
    })
    return (
      <I18nProvider uiLocale={uiLocale}>
        <CommercialDetailUnavailable
          backHref={opts.backHref}
          backLabel={opts.backLabelFallback}
          variant="not_found"
        />
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

  const detailResult = await resolveCommercialDetail({
    sessionToken: session,
    action: opts.action,
    targetId: opts.id,
    itemKind: opts.itemKind,
  })

  const { uiLocale, supported, allowClientLocaleChange } = uiLocaleFromResolve(
    sessionResult,
    actor === 'staff' ? undefined : cookieLocale,
  )

  if (!detailResult.ok) {
    return (
      <I18nProvider uiLocale={uiLocale}>
        <CommercialDetailUnavailable
          backHref={opts.backHref}
          backLabel={opts.backLabelFallback}
          variant={
            detailResult.error === 'module_disabled'
              ? 'module_disabled'
              : 'not_found'
          }
        />
      </I18nProvider>
    )
  }

  return (
    <I18nProvider uiLocale={uiLocale}>
      <CommercialDetailView
        detail={detailResult.detail}
        modules={detailResult.modules}
        backHref={opts.backHref}
        backLabel={opts.backLabelFallback}
        current={opts.current}
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
