import type { Metadata } from 'next'
import { notFound, permanentRedirect, redirect } from 'next/navigation'
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
import { PortalShell } from '@/components/PortalShell'
import { LegalDocumentView } from '@/components/LegalDocumentView'
import { fetchPagesByPublicSiteId } from '@/lib/portal'
import {
  isSafeExternalLegalUrl,
  resolvePrivacyUrlForSite,
  resolvePublicLegalDocument,
} from '@/lib/legal'

export const revalidate = 3600

const LEGAL_CODES = new Set([
  'privacy_customers',
  'legal_notice',
  'portal_terms_customers',
  'cookie_notice',
  'privacy_website',
  'privacy_employees',
  'employee_portal_terms',
  'privacy_candidates',
])

interface Props {
  params: Promise<{ domain: string; path: string[] }>
}

/**
 * Custom domain routing:
 *   path = [locale, page-slug?]
 *   - /ca          -> home page
 *   - /es/serveis  -> pagina interna
 *   - /ca/legal/privacy_website -> Legal Center
 *
 * Si path[0] no es un locale valid, l'interpretem com a page-slug
 * i usem el default_locale del site.
 */
function parsePath(
  path: string[],
  siteDefaultLocale: SupportedLocale,
): { locale: SupportedLocale; pageSlug: string; legalCode?: string } {
  const [first, second, third] = path
  if (isValidLocale(first)) {
    if (second === 'legal' && third && LEGAL_CODES.has(third)) {
      return { locale: first, pageSlug: 'legal', legalCode: third }
    }
    return { locale: first, pageSlug: second ?? 'home' }
  }
  if (first === 'legal' && second && LEGAL_CODES.has(second)) {
    return { locale: siteDefaultLocale, pageSlug: 'legal', legalCode: second }
  }
  return { locale: siteDefaultLocale, pageSlug: first ?? 'home' }
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { domain, path } = await params
  const requestedDomain = decodeURIComponent(domain)
  const site = await fetchSiteByDomain(requestedDomain)
  if (!site || !site.id) return {}

  const baseLocale = getSiteDefaultLocale(site)
  const { locale, pageSlug, legalCode } = parsePath(path, baseLocale)
  if (legalCode) {
    return {
      title: site.seo_title ?? site.name ?? undefined,
      alternates: {
        canonical: `https://${site.canonical_domain ?? requestedDomain}/${locale}/legal/${legalCode}`,
      },
    }
  }
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

  // 308 (permanent) -> domini canonic si visitem un domini alternatiu del mateix site.
  if (site.canonical_domain && site.canonical_domain !== requestedDomain) {
    const baseLocale = getSiteDefaultLocale(site)
    const { locale, pageSlug, legalCode } = parsePath(path, baseLocale)
    if (legalCode) {
      permanentRedirect(`https://${site.canonical_domain}/${locale}/legal/${legalCode}`)
    }
    permanentRedirect(`https://${site.canonical_domain}/${locale}/${pageSlug}`)
  }

  // Canonicalitza rutes sense locale explicit: /about -> /<default-locale>/about
  if (!isValidLocale(path[0])) {
    const baseLocale = getSiteDefaultLocale(site)
    const { locale, pageSlug, legalCode } = parsePath(path, baseLocale)
    if (legalCode) {
      permanentRedirect(`/${locale}/legal/${legalCode}`)
    }
    permanentRedirect(`/${locale}/${pageSlug}`)
  }

  const supportedLocales = getSiteSupportedLocales(site)
  const baseLocale = getSiteDefaultLocale(site)
  const { locale, pageSlug, legalCode } = parsePath(path, baseLocale)

  // Locale no suportat -> redirigeix al default
  if (!supportedLocales.includes(locale)) {
    if (legalCode) {
      permanentRedirect(`/${baseLocale}/legal/${legalCode}`)
    }
    permanentRedirect(`/${baseLocale}/${pageSlug}`)
  }

  const availableLocales = supportedLocales
  const pages = await fetchPagesByPublicSiteId(site.id)
  const slug = site.slug ?? ''

  if (legalCode) {
    const doc = await resolvePublicLegalDocument({
      code: legalCode,
      locale,
      publicSiteSlug: slug || null,
      tenantId: site.tenant_id,
    })
    if (doc.ok && doc.mode === 'external_url' && doc.external_url) {
      if (!isSafeExternalLegalUrl(doc.external_url)) notFound()
      redirect(doc.external_url)
    }
    const localeHrefMap = Object.fromEntries(
      availableLocales.map((l) => [l, `/${l}/legal/${legalCode}`]),
    )
    return (
      <PortalShell
        site={site}
        pages={pages}
        locale={locale}
        availableLocales={availableLocales}
        localeHrefMap={localeHrefMap}
        slugBase=""
      >
        <div className="mx-auto max-w-3xl px-4 py-10">
          <LegalDocumentView doc={doc} />
        </div>
      </PortalShell>
    )
  }

  const page = await fetchPageBySlug(site.id, pageSlug)
  if (!page) notFound()

  const localized = resolveLocalizedPage(page, locale, baseLocale)
  const showLeadForm =
    pageSlug === 'home'
      ? (page.content as Record<string, unknown> | null)?.show_lead_form !== false
      : true
  const localeHrefMap = Object.fromEntries(
    availableLocales.map((l) => [l, pageSlug === 'home' ? `/${l}` : `/${l}/${pageSlug}`]),
  )
  const privacyPolicyUrl = showLeadForm
    ? await resolvePrivacyUrlForSite({
        slug,
        tenantId: site.tenant_id,
        locale,
        code: 'privacy_website',
        linkBase: 'locale',
      })
    : null

  return (
    <PortalShell
      site={site}
      pages={pages}
      locale={locale}
      currentPageSlug={pageSlug}
      availableLocales={availableLocales}
      localeHrefMap={localeHrefMap}
      slugBase=""
    >
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
          privacyPolicyUrl={privacyPolicyUrl}
        />
      )}
    </PortalShell>
  )
}
