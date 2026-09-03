import type { Metadata } from 'next'
import { notFound, permanentRedirect } from 'next/navigation'
import {
  fetchSiteByDomain,
  fetchPageBySlug,
  resolveLocalizedPage,
  isValidLocale,
  getSiteDefaultLocale,
  getSiteSupportedLocales,
  type SupportedLocale,
} from '@/lib/portal'
import { PortalPageContent } from '@/components/PortalPageContent'
import { LeadForm } from '@/components/LeadForm'
import { LanguageSwitcher } from '@/components/LanguageSwitcher'

export const revalidate = 3600

interface Props {
  params: Promise<{ domain: string; path: string[] }>
}

/**
 * Custom domain routing:
 *   path = [locale, page-slug?]
 *   - /ca          → home page en català
 *   - /es/serveis  → pàgina "serveis" en castellà
 *
 * Si path[0] no és un locale vàlid, l'interpretem com a page-slug
 * i usem el default_locale del site.
 */
function parsePath(path: string[], siteDefaultLocale: SupportedLocale): { locale: SupportedLocale; pageSlug: string } {
  const [first, second] = path
  if (isValidLocale(first)) {
    return { locale: first, pageSlug: second ?? 'home' }
  }
  // Path sense locale prefix
  return { locale: siteDefaultLocale, pageSlug: first ?? 'home' }
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { domain, path } = await params
  const requestedDomain = decodeURIComponent(domain)
  const site = await fetchSiteByDomain(requestedDomain)
  if (!site || !site.id) return {}

  const baseLocale = getSiteDefaultLocale(site)
  const { locale, pageSlug } = parsePath(path, baseLocale)
  const page = await fetchPageBySlug(site.id, pageSlug)
  const localized = page ? resolveLocalizedPage(page, locale, baseLocale) : null

  return {
    title: localized?.seoTitle ?? localized?.title ?? site.seo_title ?? site.name,
    description: localized?.seoDescription ?? site.seo_description ?? undefined,
    alternates: {
      canonical: `https://${site.canonical_domain ?? requestedDomain}/${locale}/${pageSlug}`,
    },
  }
}

export default async function CustomDomainInnerPage({ params }: Props) {
  const { domain, path } = await params
  const requestedDomain = decodeURIComponent(domain)

  const site = await fetchSiteByDomain(requestedDomain)
  if (!site || !site.id) notFound()

  // 308 (permanent) → domini canònic si visitem un domini alternatiu del mateix site.
  if (site.canonical_domain && site.canonical_domain !== requestedDomain) {
    const baseLocale = getSiteDefaultLocale(site)
    const { locale, pageSlug } = parsePath(path, baseLocale)
    permanentRedirect(`https://${site.canonical_domain}/${locale}/${pageSlug}`)
  }

  // Canonicalitza rutes sense locale explícit: /about -> /<default-locale>/about
  // Això evita desalineacions entre el locale del layout i el contingut renderitzat.
  if (!isValidLocale(path[0])) {
    const baseLocale = getSiteDefaultLocale(site)
    const { locale, pageSlug } = parsePath(path, baseLocale)
    permanentRedirect(`/${locale}/${pageSlug}`)
  }

  const supportedLocales = getSiteSupportedLocales(site)
  const baseLocale = getSiteDefaultLocale(site)
  const { locale, pageSlug } = parsePath(path, baseLocale)

  // Locale no suportat → redirigeix al default
  if (!supportedLocales.includes(locale)) {
    permanentRedirect(`/${baseLocale}/${pageSlug}`)
  }

  const page = await fetchPageBySlug(site.id, pageSlug)
  if (!page) notFound()

  const localized = resolveLocalizedPage(page, locale, baseLocale)
  const showLeadForm = pageSlug === 'home'
    ? (page.content as Record<string, unknown> | null)?.show_lead_form !== false
    : true
  const availableLocales = supportedLocales
  const localeHrefMap = Object.fromEntries(
    availableLocales.map((l) => [l, pageSlug === 'home' ? `/${l}` : `/${l}/${pageSlug}`]),
  )

  return (
    <main>
      <div className="mx-auto max-w-4xl px-4 pt-6">
        <LanguageSwitcher
          availableLocales={availableLocales}
          currentLocale={locale}
          localeHrefMap={localeHrefMap}
        />
      </div>
      <PortalPageContent
        site={site}
        page={page}
        localizedTitle={localized.title}
        locale={locale}
      />
      {showLeadForm && (
        <LeadForm
          siteId={site.id}
          locale={locale}
          contactEmailPublic={site.contact_email_public ?? undefined}
          availableLocales={availableLocales}
          localeHrefMap={localeHrefMap}
        />
      )}
    </main>
  )
}

