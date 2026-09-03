import { redirect } from 'next/navigation'
import { I18nProvider } from '@/components/I18nProvider'
import { AccessActivitySection } from '@/components/AccessActivitySection'
import { AccessBackLink } from '@/components/AccessBackLink'
import { CookieNotice } from '@/components/CookieNotice'
import { PortalFooter } from '@/components/PortalFooter'
import { exchangeStaffToken, resolveGrantSession } from '@/lib/resolver'
import { uiLocaleFromResolve } from '@/lib/resolve-ui-locale'
import { readActorCookie, readSessionCookie, readUiLocaleCookie } from '@/lib/session'

export default async function AccessPage() {
  const session = await readSessionCookie()
  const actor = await readActorCookie()
  const cookieLocale = await readUiLocaleCookie()

  if (!session || (actor !== 'grant' && actor !== 'staff')) {
    redirect('/login?e=invalid')
  }

  const result =
    actor === 'staff'
      ? await exchangeStaffToken(session)
      : await resolveGrantSession(session, 'list_bulletins')

  if (!result.ok) {
    redirect(actor === 'staff' ? '/?e=invalid' : '/login?e=invalid')
  }

  const { uiLocale } = uiLocaleFromResolve(
    result,
    actor === 'staff' ? undefined : cookieLocale,
  )
  const profile = result.tenant_profile ?? result.access_activity?.tenant_profile
  const tenantId = result.tenant_id

  return (
    <I18nProvider uiLocale={uiLocale}>
      <main className="mx-auto max-w-2xl px-4 py-8 sm:py-12">
        <AccessBackLink actor={actor === 'staff' ? 'staff' : 'grant'} />
        <AccessActivitySection
          activity={result.access_activity}
          uiLocale={uiLocale}
          asPage
        />
      </main>
      <PortalFooter profile={profile} tenantId={tenantId} locale={uiLocale} />
      <CookieNotice tenantId={tenantId} locale={uiLocale} />
    </I18nProvider>
  )
}
