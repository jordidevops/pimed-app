import { notFound, redirect } from 'next/navigation'
import { unstable_noStore as noStore } from 'next/cache'
import {
  fetchSiteBySlug,
  fetchPagesByPublicSiteId,
  isValidLocale,
  getSiteSupportedLocales,
  type SupportedLocale,
} from '@/lib/portal'
import { isSafeExternalLegalUrl, resolvePublicLegalDocument } from '@/lib/legal'
import { LegalDocumentView } from '@/components/LegalDocumentView'
import { PortalShell } from '@/components/PortalShell'

export const revalidate = 60

const ALLOWED = new Set([
  'privacy_customers',
  'legal_notice',
  'portal_terms_customers',
  'cookie_notice',
  'privacy_website',
  'privacy_employees',
  'employee_portal_terms',
  'privacy_candidates',
])

type Props = {
  params: Promise<{ slug: string; locale: string; code: string }>
}

export default async function PublicLegalPage({ params }: Props) {
  if (process.env.NODE_ENV === 'development') noStore()

  const { slug, locale, code } = await params
  if (!ALLOWED.has(code) || !isValidLocale(locale)) notFound()

  const site = await fetchSiteBySlug(slug)
  if (!site?.id) notFound()

  const supported = getSiteSupportedLocales(site)
  if (!supported.includes(locale as SupportedLocale)) notFound()

  const pages = await fetchPagesByPublicSiteId(site.id)
  const doc = await resolvePublicLegalDocument({
    code,
    locale,
    publicSiteSlug: slug,
  })

  if (doc.ok && doc.mode === 'external_url' && doc.external_url) {
    if (!isSafeExternalLegalUrl(doc.external_url)) notFound()
    redirect(doc.external_url)
  }

  const localeHrefMap = Object.fromEntries(
    supported.map((l) => [l, `/${slug}/${l}/legal/${code}`]),
  )

  return (
    <PortalShell
      site={site}
      pages={pages}
      locale={locale as SupportedLocale}
      availableLocales={supported}
      localeHrefMap={localeHrefMap}
      slugBase={`/${slug}`}
    >
      <div className="mx-auto max-w-3xl px-4 py-10">
        <LegalDocumentView doc={doc} />
      </div>
    </PortalShell>
  )
}
