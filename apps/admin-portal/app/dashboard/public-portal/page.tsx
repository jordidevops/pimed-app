import { prisma } from '@/lib/prisma'
import { PublicPortalList } from '@/components/dashboard/PublicPortalList'

// URL base del portal públic (slug routing). En producció serà el domini real.
const PORTAL_BASE_URL =
  process.env.NEXT_PUBLIC_PUBLIC_PORTAL_URL ?? 'http://localhost:3002'

export default async function PublicPortalAdminPage() {
  const tenants = await prisma.tenants.findMany({
    select: {
      id: true,
      name: true,
      slug: true,
      is_active: true,
      public_portal_enabled: true,
      public_sites: {
        take: 1,
        where: { site_id: null }, // portal global del tenant
        select: {
          id: true,
          status: true,
          seo_title: true,
          _count: {
            select: {
              public_pages: true,
              public_domains: true,
              public_leads: true,
            },
          },
          public_domains: {
            select: { id: true, domain: true, status: true },
            orderBy: { created_at: 'asc' },
          },
        },
      },
    },
    orderBy: { name: 'asc' },
  })

  const rows = tenants.map((t) => ({
    id: t.id,
    name: t.name,
    slug: t.slug,
    is_active: t.is_active,
    public_portal_enabled: t.public_portal_enabled,
    site: t.public_sites[0]
      ? {
          ...t.public_sites[0],
          domains: t.public_sites[0].public_domains,
        }
      : null,
  }))

  return (
    <div>
      <div className="mb-6">
        <h1 className="text-2xl font-bold text-gray-900">Portal Públic per Tenant</h1>
        <p className="text-sm text-gray-500 mt-1">
          Activa o desactiva el mòdul de portal públic per a cada organització. Fes clic a una fila per veure els detalls.
        </p>
      </div>
      <PublicPortalList tenants={rows} portalBaseUrl={PORTAL_BASE_URL} />
    </div>
  )
}
