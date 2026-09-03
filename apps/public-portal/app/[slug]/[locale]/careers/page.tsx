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
import { listPublicJobPostings } from '@/lib/recruitment'
import { stripHtml } from '@/lib/postingDescription'
import { PortalShell } from '@/components/PortalShell'

export const revalidate = 600

interface Props {
  params: Promise<{ slug: string; locale: string }>
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { slug } = await params
  const site = await fetchSiteBySlug(slug)
  if (!site) return {}
  return {
    title: `Ofertes de feina | ${site.name}`,
    description: site.seo_description ?? undefined,
  }
}

export default async function CareersListPage({ params }: Props) {
  if (process.env.NODE_ENV === 'development') noStore()

  const { slug, locale } = await params
  const site = await fetchSiteBySlug(slug)
  if (!site?.id) notFound()

  if (site.canonical_domain) {
    permanentRedirect(`https://${site.canonical_domain}/${locale}/careers`)
  }

  const availableLocales = getSiteSupportedLocales(site)
  const baseLocale = getSiteDefaultLocale(site)
  if (!isValidLocale(locale) || !availableLocales.includes(locale as SupportedLocale)) {
    permanentRedirect(`/${slug}/${baseLocale}/careers`)
  }

  const validLocale = locale as SupportedLocale
  const pages = await fetchPagesByPublicSiteId(site.id)
  const postings = await listPublicJobPostings(site.id)
  const localeHrefMap = Object.fromEntries(
    availableLocales.map((l) => [l, `/${slug}/${l}/careers`]),
  )

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
      <div className="mx-auto max-w-3xl px-4 py-10">
        <h1 className="text-3xl font-semibold tracking-tight">Treballa amb nosaltres</h1>
        <p className="mt-2 text-muted-foreground text-neutral-600">
          Ofertes obertes. La candidatura no mostra l&apos;estat intern del procés de selecció.
        </p>
        <p className="mt-3 text-sm">
          <Link
            href={`/${slug}/${validLocale}/careers/rights`}
            className="text-neutral-700 underline underline-offset-2"
          >
            Exercici de drets sobre dades (RGPD)
          </Link>
        </p>

        {postings.length === 0 ? (
          <p className="mt-8 text-neutral-600">Ara mateix no hi ha ofertes publicades.</p>
        ) : (
          <ul className="mt-8 divide-y rounded-lg border">
            {postings.map((p) => (
              <li key={p.id}>
                <Link
                  href={`/${slug}/${validLocale}/careers/${p.public_slug}`}
                  className="block px-4 py-4 hover:bg-neutral-50"
                >
                  <span className="font-medium">{p.title}</span>
                  {p.description && (
                    <p className="mt-1 line-clamp-2 text-sm text-neutral-600">
                      {stripHtml(p.description)}
                    </p>
                  )}
                </Link>
              </li>
            ))}
          </ul>
        )}
      </div>
    </PortalShell>
  )
}
