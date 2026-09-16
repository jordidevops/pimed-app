import { redirect } from 'next/navigation'
import { BulletinReader } from '@/components/BulletinReader'
import { I18nProvider } from '@/components/I18nProvider'
import { BackToListLink } from '@/components/ReportGate'
import { StaffBulletinList } from '@/components/StaffBulletinList'
import type { BulletinListItem } from '@/lib/constants'
import { exchangeStaffToken, resolveShareSession } from '@/lib/resolver'
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

export default async function ReaderPage({
  searchParams,
}: {
  searchParams: Promise<{ e?: string; v?: string }>
}) {
  const sp = await searchParams
  const errorParam = sp.e
  const versionId = (sp.v ?? '').trim() || undefined
  const session = await readSessionCookie()
  const actor = await readActorCookie()
  const cookieLocale = await readUiLocaleCookie()

  if (!session) {
    redirect(errorParam === 'invalid' ? '/?e=invalid' : '/')
  }

  if (actor === 'staff') {
    const result = await exchangeStaffToken(session, versionId)
    if (!result.ok) {
      redirect('/?e=invalid')
    }

    const { uiLocale, supported } = uiLocaleFromResolve(result)
    // Staff: ignore cookie; never offer client locale change from handoff.

    if (result.projection) {
      return (
        <I18nProvider uiLocale={uiLocale}>
          {result.scope_mode === 'client_account' && <BackToListLink href="/r" />}
          <BulletinReader
            projection={result.projection}
            locale={result.locale ?? uiLocale}
            contentDigest={result.content_digest}
            actorType="staff"
            mediaManifest={result.media_manifest}
            reportVersionId={result.report_version_id ?? versionId}
            title={typeof result.title === 'string' ? result.title : undefined}
            uiLocale={uiLocale}
            allowClientLocaleChange={false}
            supportedLocales={supported}
            accountContactId={result.client_account_contact_id}
            tenantId={result.tenant_id}
            tenantProfile={result.tenant_profile}
          />
        </I18nProvider>
      )
    }

    if (
      result.scope_mode === 'client_account' ||
      result.requires_report_version_id ||
      result.bulletins
    ) {
      return (
        <I18nProvider uiLocale={uiLocale}>
          <StaffBulletinList
            bulletins={parseBulletins(result.bulletins)}
            uiLocale={uiLocale}
            tenantProfile={result.tenant_profile}
            tenantId={result.tenant_id}
          />
        </I18nProvider>
      )
    }

    redirect('/?e=invalid')
  }

  const result = await resolveShareSession(session, 'report_view')

  if (!result.ok || !result.projection) {
    redirect('/?e=invalid')
  }

  const { uiLocale, supported, allowClientLocaleChange } = uiLocaleFromResolve(
    result,
    cookieLocale,
  )

  return (
    <I18nProvider uiLocale={uiLocale}>
      <BulletinReader
        projection={result.projection}
        locale={result.locale ?? uiLocale}
        contentDigest={result.content_digest}
        actorType="share"
        mediaManifest={result.media_manifest}
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
