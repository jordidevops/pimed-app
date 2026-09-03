import type { Metadata } from 'next'
import Link from 'next/link'
import { notFound, permanentRedirect } from 'next/navigation'
import { unstable_noStore as noStore } from 'next/cache'
import {
  fetchSiteBySlug,
  fetchPagesByPublicSiteId,
  isValidLocale,
  getSiteDefaultLocale,
  getSiteSupportedLocales,
  type SupportedLocale,
} from '@/lib/portal'
import { PortalShell } from '@/components/PortalShell'
import { RightsRequestForm } from '@/components/RightsRequestForm'
import { resolvePrivacyUrlForSite } from '@/lib/legal'

export const revalidate = 600

interface Props {
  params: Promise<{ slug: string; locale: string }>
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { slug } = await params
  const site = await fetchSiteBySlug(slug)
  if (!site) return {}
  return {
    title: `Drets sobre dades | ${site.name}`,
    robots: { index: false, follow: false },
  }
}

export default async function CareersRightsPage({ params }: Props) {
  if (process.env.NODE_ENV === 'development') noStore()

  const { slug, locale } = await params
  const site = await fetchSiteBySlug(slug)
  if (!site?.id) notFound()

  if (site.canonical_domain) {
    permanentRedirect(`https://${site.canonical_domain}/${locale}/careers/rights`)
  }

  const availableLocales = getSiteSupportedLocales(site)
  const baseLocale = getSiteDefaultLocale(site)
  if (!isValidLocale(locale) || !availableLocales.includes(locale as SupportedLocale)) {
    permanentRedirect(`/${slug}/${baseLocale}/careers/rights`)
  }

  const validLocale = locale as SupportedLocale
  const pages = await fetchPagesByPublicSiteId(site.id)
  const localeHrefMap = Object.fromEntries(
    availableLocales.map((l) => [l, `/${slug}/${l}/careers/rights`]),
  )
  const privacyPolicyUrl = await resolvePrivacyUrlForSite({
    slug,
    locale: validLocale,
    code: 'privacy_candidates',
  })

  return (
    <PortalShell
      site={site}
      pages={pages}
      locale={validLocale}
      currentPageSlug="careers"
      availableLocales={availableLocales}
      localeHrefMap={localeHrefMap}
      slugBase={`/${slug}`}
    >
      <div className="relative mx-auto max-w-md px-4 py-10">
        <p className="text-sm text-neutral-500">
          <Link href={`/${slug}/${validLocale}/careers`} className="underline">
            ← Ofertes
          </Link>
        </p>
        <h1 className="mt-4 text-2xl font-semibold tracking-tight">
          Exercici de drets (RGPD)
        </h1>
        <p className="mt-2 text-sm text-neutral-600">
          Pots demanar accés a les teves dades de candidatura (Art. 15) o el seu
          esborrat (Art. 17). La resposta s&apos;envia per correu.
        </p>
        {privacyPolicyUrl ? (
          <p className="mt-2 text-sm text-neutral-600">
            <a
              href={privacyPolicyUrl}
              className="underline underline-offset-2"
              {...(privacyPolicyUrl.startsWith('http')
                ? { target: '_blank', rel: 'noopener noreferrer' }
                : {})}
            >
              Política de privacitat de candidats
            </a>
          </p>
        ) : null}
        <RightsRequestForm siteId={site.id} />
      </div>
    </PortalShell>
  )
}
