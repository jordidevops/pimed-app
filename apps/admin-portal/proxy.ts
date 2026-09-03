import { createServerClient } from '@supabase/ssr'
import { NextResponse, type NextRequest } from 'next/server'

const PUBLIC_PATHS = ['/login', '/auth']

/**
 * Middleware runs on every request (except static assets).
 * 1. Refreshes the Supabase session token and propagates updated cookies.
 * 2. Redirects unauthenticated users to /login for protected routes.
 * 3. Redirects authenticated (but non-backoffice) users to /login with an error query param.
 * 4. Redirects backoffice users away from /login to /dashboard.
 *
 * SECURITY:
 *   - Uses getUser() — validates the JWT against Supabase Auth server (not just the cookie).
 *   - Access is granted ONLY to users whose app_metadata.role is a recognized backoffice role.
 *     app_metadata is set server-side only and cannot be modified by the user.
 *
 * BACKOFFICE ROLES (app_metadata.role):
 *   'admin'   → superadmin. Full access. All Server Actions allowed.
 *   'support' → read-only backoffice. Can query data but Server Actions enforce restrictions.
 */
export async function proxy(request: NextRequest) {
  const { pathname } = request.nextUrl
  const isPublicPath = PUBLIC_PATHS.some((p) => pathname.startsWith(p))

  // Guard: si les variables d'entorn no estan disponibles, deixa passar rutes públiques
  // i redirigeix les protegides a /login (evita bucle infinit si el guard s'aplica a /login)
  if (!process.env.NEXT_PUBLIC_SUPABASE_URL || !process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY) {
    if (isPublicPath) return NextResponse.next()
    const url = request.nextUrl.clone()
    url.pathname = '/login'
    return NextResponse.redirect(url)
  }

  let supabaseResponse = NextResponse.next({ request })

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll()
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value))
          supabaseResponse = NextResponse.next({ request })
          cookiesToSet.forEach(({ name, value, options }) =>
            supabaseResponse.cookies.set(name, value, options),
          )
        },
      },
    },
  )

  // Validate the JWT against the Supabase Auth server (secure — not just cookie-based)
  const {
    data: { user },
  } = await supabase.auth.getUser()

  // Rols de backoffice reconeguts (app_metadata.role, establert server-side per Supabase)
  const BACKOFFICE_ROLES = ['admin', 'support'] as const
  type BackofficeRole = (typeof BACKOFFICE_ROLES)[number]

  const userRole = user?.app_metadata?.role as BackofficeRole | undefined
  const isBackofficeUser = userRole !== undefined && (BACKOFFICE_ROLES as readonly string[]).includes(userRole)

  // Redirect unauthenticated users to /login
  if (!user && !isPublicPath) {
    const url = request.nextUrl.clone()
    url.pathname = '/login'
    return NextResponse.redirect(url)
  }

  // Redirect authenticated but non-backoffice users to /login with an error indicator
  if (user && !isBackofficeUser && !isPublicPath) {
    const url = request.nextUrl.clone()
    url.pathname = '/login'
    url.searchParams.set('error', 'unauthorized')
    return NextResponse.redirect(url)
  }

  // Redirect backoffice users away from /login to /dashboard
  if (user && isBackofficeUser && pathname === '/login') {
    const url = request.nextUrl.clone()
    url.pathname = '/dashboard'
    return NextResponse.redirect(url)
  }

  return supabaseResponse
}

export const config = {
  matcher: [
    // Run on all paths except Next.js internals and static files
    '/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)',
  ],
}
