import type { Metadata } from 'next'
import { notFound, permanentRedirect } from 'next/navigation'
import { unstable_noStore as noStore } from 'next/cache'
import {
  fetchSiteBySlug,
  fetchPagesByPublicSiteId,
  resolveLocalizedPage,
  isValidLocale,
  getSiteDefaultLocale,
  getSiteSupportedLocales,
  type SupportedLocale,
} from '@/lib/portal'
import { PortalPageContent } from '@/components/PortalPageContent'
import { LeadForm } from '@/components/LeadForm'
import { PortalShell } from '@/components/PortalShell'
import { resolvePrivacyUrlForSite } from '@/lib/legal'

// ISR: revalida cada hora
export const revalidate = 3600

interface Props {
  params: Promise<{ slug: string; locale: string }>
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { slug, locale } = await params
  const site = await fetchSiteBySlug(slug)
  if (!site) return {}

  const baseLocale = getSiteDefaultLocale(site)
  const validLocale: SupportedLocale = isValidLocale(locale) ? locale : baseLocale
  const pages = await fetchPagesByPublicSiteId(site.id!)
  const homePage = pages.find((p) => p.slug === 'home') ?? pages[0] ?? null
  const localized = homePage ? resolveLocalizedPage(homePage, validLocale, baseLocale) : null

  const alternateLocales = getSiteSupportedLocales(site)

  return {
    title: localized?.seoTitle ?? localized?.title ?? site.seo_title ?? site.name,
    description: localized?.seoDescription ?? site.seo_description ?? undefined,
    keywords: site.seo_keywords ?? undefined,
    ...(site.canonical_domain && {
      alternates: {
        canonical: `https://${site.canonical_domain}/${validLocale}`,
        languages: Object.fromEntries(
          alternateLocales.map((l) => [l, `https://${site.canonical_domain}/${l}`])
        ),
      },
    }),
  }
}

export default async function SiteHomeLocalePage({ params }: Props) {
  if (process.env.NODE_ENV === 'development') {
    noStore()
  }

  const { slug, locale } = await params
  const site = await fetchSiteBySlug(slug)

  if (!site || !site.id) notFound()

  // 308 → domini canònic si el site té un domini propi amb SSL actiu.
  if (site.canonical_domain) {
    permanentRedirect(`https://${site.canonical_domain}/${locale}`)
  }

  const availableLocales = getSiteSupportedLocales(site)
  const baseLocale = getSiteDefaultLocale(site)

  // Locale no suportat → redirigeix al default
  if (!isValidLocale(locale) || !availableLocales.includes(locale as SupportedLocale)) {
    permanentRedirect(`/${slug}/${baseLocale}`)
  }

  const validLocale = locale as SupportedLocale
  const pages = await fetchPagesByPublicSiteId(site.id)
  const homePage = pages.find((p) => p.slug === 'home') ?? pages[0] ?? null
  const localized = homePage ? resolveLocalizedPage(homePage, validLocale, baseLocale) : null
  const showLeadForm = (homePage?.content as Record<string, unknown> | null)?.show_lead_form !== false

  const localeHrefMap = Object.fromEntries(availableLocales.map((l) => [l, `/${slug}/${l}`]))
  const privacyPolicyUrl = showLeadForm
    ? await resolvePrivacyUrlForSite({
        slug,
        locale: validLocale,
        code: 'privacy_website',
      })
    : null

  return (
    <PortalShell
      site={site}
      pages={pages}
      locale={validLocale}
      currentPageSlug="home"
      availableLocales={availableLocales}
      localeHrefMap={localeHrefMap}
      slugBase={`/${slug}`}
    >
      <PortalPageContent
        site={site}
        page={homePage}
        localizedTitle={localized?.title ?? null}
        locale={validLocale}
      />
      {showLeadForm && (
        <LeadForm
          siteId={site.id}
          locale={validLocale}
          contactEmailPublic={site.contact_email_public}
          availableLocales={availableLocales}
          localeHrefMap={localeHrefMap}
          privacyPolicyUrl={privacyPolicyUrl}
        />
      )}
    </PortalShell>
  )
}
