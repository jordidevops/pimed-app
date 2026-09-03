import { notFound, permanentRedirect, redirect } from 'next/navigation'
import { unstable_noStore as noStore } from 'next/cache'
import { fetchSiteByDomain, isValidLocale } from '@/lib/portal'

export const revalidate = 3600

interface Props {
  params: Promise<{ domain: string }>
}

/**
 * Custom domain root -> redirigeix a /sites/{domain}/{default_locale}
 * que sera reescrit pel proxy a /sites/{domain}/{locale}/home.
 */
export default async function CustomDomainRootPage({ params }: Props) {
  if (process.env.NODE_ENV === 'development') {
    noStore()
  }

  const { domain } = await params
  const requestedDomain = decodeURIComponent(domain)
  const site = await fetchSiteByDomain(requestedDomain)

  if (!site || !site.id) notFound()

  if (site.canonical_domain && site.canonical_domain !== requestedDomain) {
    permanentRedirect(`https://${site.canonical_domain}`)
  }

  const locale = isValidLocale(site.default_locale ?? '') ? site.default_locale : 'ca'
  // El middleware ja va reescriure /sites/{domain}, ara naveguem al locale
  redirect(`/${locale}`)
}
