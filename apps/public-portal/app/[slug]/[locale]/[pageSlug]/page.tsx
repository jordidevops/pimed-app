import type { Metadata } from 'next'
import { notFound, permanentRedirect } from 'next/navigation'
import {
  fetchSiteBySlug,
  fetchPageBySlug,
  resolveLocalizedPage,
  isValidLocale,
  getSiteDefaultLocale,
  getSiteSupportedLocales,
  type SupportedLocale,
} from '@/lib/portal'
import { PortalPageContent } from '@/components/PortalPageContent'
import { LeadForm } from '@/components/LeadForm'
import { PortalShell } from '@/components/PortalShell'
import { fetchPagesByPublicSiteId } from '@/lib/portal'
import { resolvePrivacyUrlForSite } from '@/lib/legal'

export const revalidate = 3600

interface Props {
  params: Promise<{ slug: string; locale: string; pageSlug: string }>
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { slug, locale, pageSlug } = await params
  const site = await fetchSiteBySlug(slug)
  if (!site || !site.id) return {}

  const baseLocale = getSiteDefaultLocale(site)
  const validLocale: SupportedLocale = isValidLocale(locale) ? locale : baseLocale
  const page = await fetchPageBySlug(site.id, pageSlug)
  const localized = page ? resolveLocalizedPage(page, validLocale, baseLocale) : null

  return {
    title: localized?.seoTitle ?? localized?.title ?? site.seo_title ?? site.name,
    description: localized?.seoDescription ?? site.seo_description ?? undefined,
    ...(site.canonical_domain && {
      alternates: {
        canonical: `https://${site.canonical_domain}/${validLocale}/${pageSlug}`,
      },
    }),
  }
}

export default async function SiteInnerLocalePage({ params }: Props) {
  const { slug, locale, pageSlug } = await params
  const site = await fetchSiteBySlug(slug)
  if (!site || !site.id) notFound()

  // 308 → domini canònic
  if (site.canonical_domain) {
    permanentRedirect(`https://${site.canonical_domain}/${locale}/${pageSlug}`)
  }

  const availableLocales = getSiteSupportedLocales(site)
  const baseLocale = getSiteDefaultLocale(site)

  // Locale no suportat → redirigeix al default
  if (!isValidLocale(locale) || !availableLocales.includes(locale as SupportedLocale)) {
    permanentRedirect(`/${slug}/${baseLocale}/${pageSlug}`)
  }

  const validLocale = locale as SupportedLocale
  const page = await fetchPageBySlug(site.id, pageSlug)
  if (!page) notFound()

  const localized = resolveLocalizedPage(page, validLocale, baseLocale)
  const pages = await fetchPagesByPublicSiteId(site.id)
  const localeHrefMap = Object.fromEntries(availableLocales.map((l) => [l, `/${slug}/${l}/${pageSlug}`]))
  const showLeadForm = (page.content as Record<string, unknown> | null)?.show_lead_form !== false
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
      currentPageSlug={pageSlug}
      availableLocales={availableLocales}
      localeHrefMap={localeHrefMap}
      slugBase={`/${slug}`}
    >
      <PortalPageContent
        site={site}
        page={page}
        localizedTitle={localized.title}
        locale={validLocale}
      />
      {showLeadForm ? (
        <LeadForm
          siteId={site.id}
          locale={validLocale}
          contactEmailPublic={site.contact_email_public}
          availableLocales={availableLocales}
          localeHrefMap={localeHrefMap}
          privacyPolicyUrl={privacyPolicyUrl}
        />
      ) : null}
    </PortalShell>
  )
}