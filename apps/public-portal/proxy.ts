import { type NextRequest, NextResponse } from 'next/server'

/**
 * Middleware de routing per custom domains.
 *
 * Flux:
 *  - Si el host és un domini del sistema (localhost, *.<suffixos configurats>, *.vercel.app)
 *    → deixa passar la petició sense modificar (routing per slug normal)
 *  - Si el host és un custom domain del tenant
 *    → reescriu la URL a /sites/{host}{pathname}
 *    → `app/sites/[domain]/page.tsx` resol el domini → site
 *
 * Exemple:
 *   GET myclinic.com/serveis
 *   → reescrit a /sites/myclinic.com/serveis
 */

const HARDCODED_SYSTEM_PATTERNS = [
  'localhost',
  '127.0.0.1',
  '.vercel.app',
]

function isSystemDomain(host: string): boolean {
  const hostname = host.split(':')[0] // ignora el port
  const extraSuffixes = (process.env.NEXT_PUBLIC_PORTAL_SYSTEM_SUFFIXES ?? '')
    .split(',')
    .map((value) => value.trim())
    .filter(Boolean)

  const patterns = [...HARDCODED_SYSTEM_PATTERNS, ...extraSuffixes]

  // Patrons hardcoded (subdominis inclosos via endsWith)
  if (patterns.some((p) =>
    p.startsWith('.') ? hostname.endsWith(p) : hostname === p
  )) {
    return true
  }

  // Domini del sistema configurat per variable d'entorn
  const envDomain = process.env.NEXT_PUBLIC_PORTAL_SYSTEM_DOMAIN
  if (envDomain && (hostname === envDomain || hostname.endsWith('.' + envDomain))) {
    return true
  }

  return false
}

const VALID_LOCALES = ['ca', 'es', 'en']

export function proxy(request: NextRequest) {
  const rawHost = request.headers.get('x-forwarded-host') ?? request.headers.get('host') ?? ''
  const host = rawHost.split(':')[0] ?? ''
  const pathname = request.nextUrl.pathname
  const segments = pathname.split('/').filter(Boolean)

  // Employee portal API must be served under /portal/api (cookie Path=/portal), but that
  // path collides with [slug]/[locale]/[pageSlug] (slug=portal, locale=api). Rewrite internally.
  if (pathname === '/portal/api' || pathname.startsWith('/portal/api/')) {
    const url = request.nextUrl.clone()
    url.pathname = pathname.replace(/^\/portal\/api/, '/api/employee-portal')
    return NextResponse.rewrite(url)
  }

  // Inspection access API served under /inspect/api (cookie Path=/inspect) so the
  // HttpOnly session cookie reaches both the /inspect/[id] page and the API calls.
  if (pathname === '/inspect/api' || pathname.startsWith('/inspect/api/')) {
    const url = request.nextUrl.clone()
    url.pathname = pathname.replace(/^\/inspect\/api/, '/api/inspect')
    return NextResponse.rewrite(url)
  }

  // Domini del sistema: routing normal via /[slug]/[locale]/...
  // El locale és el segon segment (el primer és el slug del site).
  if (!host || isSystemDomain(host)) {
    const localeSegment = segments[1] ?? ''
    if (VALID_LOCALES.includes(localeSegment)) {
      const requestHeaders = new Headers(request.headers)
      requestHeaders.set('x-locale', localeSegment)
      return NextResponse.next({ request: { headers: requestHeaders } })
    }
    return NextResponse.next()
  }

  // Custom domain: reescriu a /sites/{domain}{path}
  const url = request.nextUrl.clone()

  // Evita reescriure peticions internes de Next.js
  if (
    pathname.startsWith('/_next') ||
    pathname.startsWith('/api') ||
    pathname.startsWith('/sites') ||
    pathname.includes('.')
  ) {
    return NextResponse.next()
  }

  // Per custom domains, el locale és el primer segment (e.g., /ca/home, /es/serveis)
  const firstSegment = segments[0] ?? ''
  const detectedLocale = VALID_LOCALES.includes(firstSegment) ? firstSegment : null

  url.pathname = `/sites/${host}${pathname}`

  if (detectedLocale) {
    const requestHeaders = new Headers(request.headers)
    requestHeaders.set('x-locale', detectedLocale)
    return NextResponse.rewrite(url, { request: { headers: requestHeaders } })
  }

  return NextResponse.rewrite(url)
}

export const config = {
  matcher: [
    /*
     * Aplica a totes les rutes excepte:
     * - _next/static (fitxers estàtics)
     * - _next/image (optimització d'imatges)
     * - favicon.ico, sitemap.xml, robots.txt
     */
    '/((?!_next/static|_next/image|favicon.ico|sitemap.xml|robots.txt).*)',
  ],
}

