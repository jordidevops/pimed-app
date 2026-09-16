import { BulletinReader } from '@/components/BulletinReader'
import { I18nProvider } from '@/components/I18nProvider'
import { BackToListLink, ReportGate } from '@/components/ReportGate'
import { PLATFORM_FALLBACK_LOCALE, resolveUiLocale } from '@/lib/locale'
import { resolveGrantSession } from '@/lib/resolver'
import { uiLocaleFromResolve } from '@/lib/resolve-ui-locale'
import { readActorCookie, readSessionCookie, readUiLocaleCookie } from '@/lib/session'

type Params = { params: Promise<{ versionId: string }> }

export default async function DashboardReportPage({ params }: Params) {
  const { versionId: raw } = await params
  const versionId = (raw ?? '').trim()
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
        <ReportGate variant="need_session" />
      </I18nProvider>
    )
  }

  const uuidRe =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
  if (!uuidRe.test(versionId)) {
    const uiLocale = resolveUiLocale({
      preferred: null,
      supported: ['ca', 'es', 'en'],
      defaultLocale: PLATFORM_FALLBACK_LOCALE,
      cookieLocale,
    })
    return (
      <I18nProvider uiLocale={uiLocale}>
        <ReportGate variant="unavailable" />
      </I18nProvider>
    )
  }

  const result = await resolveGrantSession(session, 'report_view', versionId)
  if (!result.ok || !result.projection) {
    const uiLocale = resolveUiLocale({
      preferred: null,
      supported: ['ca', 'es', 'en'],
      defaultLocale: PLATFORM_FALLBACK_LOCALE,
      cookieLocale,
    })
    return (
      <I18nProvider uiLocale={uiLocale}>
        <ReportGate variant="unavailable_or_expired" />
      </I18nProvider>
    )
  }

  const { uiLocale, supported, allowClientLocaleChange } = uiLocaleFromResolve(
    result,
    cookieLocale,
  )

  return (
    <I18nProvider uiLocale={uiLocale}>
      <BackToListLink href="/dashboard" />
      <BulletinReader
        projection={result.projection}
        locale={result.locale ?? uiLocale}
        contentDigest={result.content_digest}
        actorType="grant"
        mediaManifest={result.media_manifest}
        reportVersionId={versionId}
        title={typeof result.title === 'string' ? result.title : undefined}
        uiLocale={uiLocale}
        allowClientLocaleChange={allowClientLocaleChange}
        supportedLocales={supported}
        accountContactId={result.client_account_contact_id}
        tenantId={result.tenant_id}
        tenantProfile={result.tenant_profile}
      />
    </I18nProvider>
  )
}
