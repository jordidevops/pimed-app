import { notFound, permanentRedirect, redirect } from 'next/navigation'
import { unstable_noStore as noStore } from 'next/cache'
import { fetchSiteBySlug, getSiteDefaultLocale } from '@/lib/portal'

// ISR: revalida cada hora
export const revalidate = 3600

interface Props {
  params: Promise<{ slug: string }>
}

/**
 * Detecta l'idioma per defecte del site i redirigeix a /{slug}/{locale}.
 * Usa redirect (307) perquè és negociació de contingut, no canvi permanent.
 */
export default async function SiteRootPage({ params }: Props) {
  if (process.env.NODE_ENV === 'development') {
    noStore()
  }

  const { slug } = await params
  const site = await fetchSiteBySlug(slug)

  if (!site || !site.id) notFound()

  // 308 → domini canònic si el site té un domini propi amb SSL actiu.
  if (site.canonical_domain) {
    permanentRedirect(`https://${site.canonical_domain}`)
  }

  const locale = getSiteDefaultLocale(site)
  redirect(`/${slug}/${locale}`)
}
