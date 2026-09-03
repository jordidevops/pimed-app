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
import { getPublicJobPosting } from '@/lib/recruitment'
import { postingDescriptionHtml, stripHtml } from '@/lib/postingDescription'
import { PortalShell } from '@/components/PortalShell'
import { JobApplyForm } from '@/components/JobApplyForm'
import { resolvePrivacyUrlForSite } from '@/lib/legal'

export const revalidate = 300

interface Props {
  params: Promise<{ slug: string; locale: string; postingSlug: string }>
  searchParams: Promise<{ src?: string }>
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { slug, postingSlug } = await params
  const site = await fetchSiteBySlug(slug)
  if (!site?.id) return {}
  const posting = await getPublicJobPosting(site.id, postingSlug)
  if (!posting) return { title: site.name ?? undefined }
  return {
    title: `${posting.title} | ${site.name}`,
    description: posting.description
      ? stripHtml(posting.description).slice(0, 160) || undefined
      : undefined,
  }
}

function normalizeSource(src: string | undefined): 'web' | 'qr' | 'whatsapp' | 'email' {
  if (src === 'qr' || src === 'whatsapp' || src === 'email') return src
  return 'web'
}

export default async function CareersDetailPage({ params, searchParams }: Props) {
  if (process.env.NODE_ENV === 'development') noStore()

  const { slug, locale, postingSlug } = await params
  const { src } = await searchParams
  const site = await fetchSiteBySlug(slug)
  if (!site?.id) notFound()

  if (site.canonical_domain) {
    const q = src ? `?src=${encodeURIComponent(src)}` : ''
    permanentRedirect(`https://${site.canonical_domain}/${locale}/careers/${postingSlug}${q}`)
  }

  const availableLocales = getSiteSupportedLocales(site)
  const baseLocale = getSiteDefaultLocale(site)
  if (!isValidLocale(locale) || !availableLocales.includes(locale as SupportedLocale)) {
    permanentRedirect(`/${slug}/${baseLocale}/careers/${postingSlug}`)
  }

  const validLocale = locale as SupportedLocale
  const posting = await getPublicJobPosting(site.id, postingSlug)
  if (!posting) notFound()

  const pages = await fetchPagesByPublicSiteId(site.id)
  const localeHrefMap = Object.fromEntries(
    availableLocales.map((l) => [l, `/${slug}/${l}/careers/${postingSlug}`]),
  )

  const descriptionHtml = postingDescriptionHtml(posting.description)
  const privacyPolicyUrl = await resolvePrivacyUrlForSite({
    slug,
    locale: validLocale,
    code: 'privacy_candidates',
    legacyUrl: posting.privacy_policy_url,
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
      <div className="mx-auto max-w-3xl space-y-8 px-4 py-10">
        <div>
          <Link
            href={`/${slug}/${validLocale}/careers`}
            className="text-sm text-neutral-600 underline"
          >
            ← Ofertes
          </Link>
          <h1 className="mt-3 text-3xl font-semibold tracking-tight">{posting.title}</h1>
          {descriptionHtml && (
            <div
              className="prose prose-neutral mt-4 max-w-none text-neutral-700"
              dangerouslySetInnerHTML={{ __html: descriptionHtml }}
            />
          )}
        </div>

        <section className="rounded-lg border p-5">
          <h2 className="mb-4 text-xl font-semibold">Envia la teva candidatura</h2>
          <JobApplyForm
            siteId={site.id}
            jobPostingId={posting.id}
            locale={validLocale}
            privacyPolicyUrl={privacyPolicyUrl}
            retentionOptionsMonths={posting.retention_options_months ?? []}
            defaultMaxRetentionMonths={posting.default_max_retention_months ?? 12}
            source={normalizeSource(src)}
          />
        </section>
      </div>
    </PortalShell>
  )
}
