const PUBLIC_PORTAL_BASE =
  (import.meta.env.VITE_PUBLIC_PORTAL_BASE_URL as string | undefined) ?? 'http://localhost:3002'
const REVALIDATE_SECRET = import.meta.env.VITE_PORTAL_REVALIDATE_SECRET as string | undefined

export async function revalidatePublicPortalPaths(params: {
  siteSlug: string
  pageSlug: string
  locales: string[]
}) {
  if (!REVALIDATE_SECRET) {
    console.warn('[tenant-content] VITE_PORTAL_REVALIDATE_SECRET not set — skip ISR revalidate')
    return
  }

  const paths = params.locales.flatMap((locale) => [
    `/${params.siteSlug}/${locale}/${params.pageSlug}`,
    `/${params.siteSlug}/${locale}`,
  ])

  const res = await fetch(`${PUBLIC_PORTAL_BASE}/api/revalidate-portal`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-revalidate-secret': REVALIDATE_SECRET,
    },
    body: JSON.stringify({ paths }),
  })

  if (!res.ok) {
    const text = await res.text().catch(() => '')
    throw new Error(`revalidate failed: ${res.status} ${text}`)
  }
}
