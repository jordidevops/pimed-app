import { I18nProvider } from '@/components/I18nProvider'
import { DashboardGate } from '@/components/DashboardBulletinList'
import {
  CommercialCatalogueList,
  type CommercialNavKey,
} from '@/components/CommercialCatalogueList'
import { PLATFORM_FALLBACK_LOCALE, resolveUiLocale } from '@/lib/locale'
import {
  type CommercialListItem,
  exchangeStaffToken,
  resolveCommercialSession,
  resolveGrantSession,
} from '@/lib/resolver'
import { uiLocaleFromResolve } from '@/lib/resolve-ui-locale'
import { readActorCookie, readSessionCookie, readUiLocaleCookie } from '@/lib/session'

type ModuleKey = 'quotes_agreements' | 'delivery_notes' | 'invoices'

export async function renderCommercialCataloguePage(opts: {
  kind: ModuleKey
  current: CommercialNavKey
  titleKey: string
  titleFallback: string
  emptyKey: string
  emptyFallback: string
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

  // Single commercial RPC: list rows + modules (no separate list_summary).
  const list = await resolveCommercialSession({
    sessionToken: session,
    action: 'list_documents',
    kind: opts.kind,
    limit: 20,
  })
  const modules = list.ok ? list.modules : undefined
  const moduleEnabled = modules?.[opts.kind] === true
  const items: CommercialListItem[] =
    list.ok && moduleEnabled ? list.items : []

  const { uiLocale, supported, allowClientLocaleChange } = uiLocaleFromResolve(
    sessionResult,
    actor === 'staff' ? undefined : cookieLocale,
  )

  return (
    <I18nProvider uiLocale={uiLocale}>
      <CommercialCatalogueList
        items={items}
        moduleEnabled={moduleEnabled}
        modules={modules}
        current={opts.current}
        titleKey={opts.titleKey}
        titleFallback={opts.titleFallback}
        emptyKey={opts.emptyKey}
        emptyFallback={opts.emptyFallback}
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
