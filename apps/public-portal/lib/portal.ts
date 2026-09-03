import { createPortalClient } from './supabase'
import type { Database } from '@/types/database.types'
import {
  isValidLocale,
  PLATFORM_FALLBACK_LOCALE,
  type SupportedLocale,
} from './locales'

export {
  isValidLocale,
  PLATFORM_FALLBACK_LOCALE,
  VALID_LOCALES,
} from './locales'
export type { SupportedLocale } from './locales'

export type PublicSite = Database['api']['CompositeTypes']['portal_site_row']
export type PublicPage = Database['api']['Views']['public_pages_full']['Row']

export function getSiteSupportedLocales(
  site: Pick<PublicSite, 'supported_locales' | 'default_locale'>,
): SupportedLocale[] {
  const fromSupported = (site.supported_locales ?? []).filter((l): l is SupportedLocale => isValidLocale(l))
  if (fromSupported.length > 0) return fromSupported

  if (isValidLocale(site.default_locale ?? '')) {
    return [site.default_locale as SupportedLocale]
  }

  return [PLATFORM_FALLBACK_LOCALE]
}

export function getSiteDefaultLocale(
  site: Pick<PublicSite, 'supported_locales' | 'default_locale'>,
): SupportedLocale {
  const supported = getSiteSupportedLocales(site)
  if (isValidLocale(site.default_locale ?? '') && supported.includes(site.default_locale as SupportedLocale)) {
    return site.default_locale as SupportedLocale
  }
  return supported[0] ?? PLATFORM_FALLBACK_LOCALE
}

/**
 * Retorna els valors localitzats de la pàgina per al locale demanat.
 * Base: camps principals del model en l'idioma base del portal; overlay: translations[locale].
 */
export function resolveLocalizedPage(
  page: PublicPage,
  locale: SupportedLocale,
  baseLocale: SupportedLocale,
): { title: string; seoTitle: string | null; seoDescription: string | null } {
  if (locale === baseLocale) {
    return {
      title: page.title ?? '',
      seoTitle: page.seo_title ?? null,
      seoDescription: page.seo_description ?? null,
    }
  }
  const translations = (page.translations as Record<string, { title?: string; seoTitle?: string; seoDescription?: string }> | null) ?? {}
  const overlay = translations[locale] ?? {}
  return {
    title: overlay.title || page.title || '',
    seoTitle: overlay.seoTitle || page.seo_title || null,
    seoDescription: overlay.seoDescription || page.seo_description || null,
  }
}
/**
 * Obté un site publicat pel seu slug via RPC SECURITY DEFINER.
 * Inclou content, theme_config i canonical_domain si el domini propi és ssl_active.
 * Retorna null si no existeix, no és published o el portal no està habilitat.
 */
export async function fetchSiteBySlug(slug: string): Promise<PublicSite | null> {
  const db = createPortalClient()
  const { data, error } = await db.rpc('resolve_site_for_portal', { p_slug: slug })

  if (error || !data) return null
  // La RPC retorna null si el site no existeix → comprova el camp id
  if (!data.id) return null
  return data as PublicSite
}

/**
 * Obté un site publicat per un custom domain verificat via RPC SECURITY DEFINER.
 * Accessible per anon: consulta data.public_domains (no accessible directament per anon).
 * Retorna null si el domini no existeix o no és verificat.
 */
export async function fetchSiteByDomain(domain: string): Promise<PublicSite | null> {
  const db = createPortalClient()
  const { data, error } = await db.rpc('resolve_domain_for_portal', {
    p_domain: domain.toLowerCase(),
  })

  if (error || !data) return null
  if (!data.id) return null
  return data as PublicSite
}

/**
 * Llista totes les pàgines publicades d'un site, ordenades per sort_order.
 */
export async function fetchPagesByPublicSiteId(publicSiteId: string): Promise<PublicPage[]> {
  const db = createPortalClient()
  const { data, error } = await db
    .from('public_pages_full')
    .select('*')
    .eq('public_site_id', publicSiteId)
    .eq('status', 'published')
    .order('sort_order', { ascending: true })

  if (error || !data) return []
  return data
}

/**
 * Obté una pàgina publicada pel seu slug dins d'un site.
 */
export async function fetchPageBySlug(
  publicSiteId: string,
  pageSlug: string,
): Promise<PublicPage | null> {
  const db = createPortalClient()
  const { data, error } = await db
    .from('public_pages_full')
    .select('*')
    .eq('public_site_id', publicSiteId)
    .eq('slug', pageSlug)
    .eq('status', 'published')
    .single()

  if (error || !data) return null
  return data
}
