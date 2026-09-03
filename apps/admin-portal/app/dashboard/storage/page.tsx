import { createSupabaseAdminClient } from '@/lib/supabase/admin'
import { prisma } from '@/lib/prisma'
import { getT } from '@/lib/i18n/server'

function formatBytes(bytes: bigint | number | null | undefined): string {
  if (bytes == null) return '—'
  const n = Number(bytes)
  if (n < 1024) return `${n} B`
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`
  return `${(n / 1024 ** 3).toFixed(2)} GB`
}

interface StorageBucket {
  id: string
  name: string
  public: boolean
  file_size_limit: number | null
  allowed_mime_types: string[] | null
  created_at: string
}

export default async function StoragePage() {
  const t = getT('storage')
  const supabaseAdmin = createSupabaseAdminClient()

  const monthStart = new Date(new Date().getFullYear(), new Date().getMonth(), 1)

  const [bucketsResult, tenants, egressByTenant] = await Promise.all([
    supabaseAdmin.storage.listBuckets(),
    prisma.tenants.findMany({
      where: { is_active: true },
      orderBy: { name: 'asc' },
      select: {
        id: true,
        name: true,
        slug: true,
        storage_usage: {
          select: {
            file_count: true,
            committed_bytes: true,
            reserved_bytes: true,
            documents_committed_bytes: true,
            documents_file_count: true,
          },
        },
      },
    }),
    prisma.storage_egress_logs.groupBy({
      by: ['tenant_id'],
      where: { created_at: { gte: monthStart } },
      _sum: { size_bytes: true },
    }),
  ])

  const buckets = (bucketsResult.data ?? []) as StorageBucket[]
  const egressMap = new Map(
    egressByTenant.map((e) => [e.tenant_id, e._sum.size_bytes ?? BigInt(0)])
  )

  const tenantFileBucket = buckets.find((b) => b.name === 'tenant-files') ?? null

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">{t('storage.title', 'Storage')}</h1>
        <p className="text-sm text-gray-500 mt-1">
          {t('storage.description', 'Visió global dels buckets i estadístiques per tenant.')}
        </p>
      </div>

      {/* ── Buckets ─────────────────────────────────── */}
      <section className="bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
        <div className="px-6 py-4 border-b border-gray-100">
          <h2 className="text-sm font-semibold text-gray-700">
            {t('storage.buckets_section.title', 'Buckets')}{' '}
            <span className="ml-1.5 text-xs font-normal text-gray-400">
              {t('storage.buckets_section.source', 'origen: esquema storage')}
            </span>
          </h2>
        </div>
        <div className="divide-y divide-gray-50">
          {buckets.length === 0 && (
            <p className="px-6 py-4 text-sm text-gray-400">{t('storage.buckets_section.empty', "No s'han trobat buckets.")}</p>
          )}
          {buckets.map((bucket) => (
            <div key={bucket.id} className="px-6 py-4">
              <div className="flex items-start justify-between gap-4">
                <div className="min-w-0">
                  <div className="flex items-center gap-2">
                    <span className="text-sm font-semibold text-gray-800">{bucket.name}</span>
                    <span
                      className={`text-xs px-1.5 py-0.5 rounded font-medium ${
                        bucket.public
                          ? 'bg-green-50 text-green-700'
                          : 'bg-gray-100 text-gray-500'
                      }`}
                    >
                      {bucket.public ? t('storage.buckets_section.public', 'públic') : t('storage.buckets_section.private', 'privat')}
                    </span>
                  </div>
                  <p className="text-xs text-gray-400 mt-0.5">ID: {bucket.id}</p>
                </div>
                <div className="text-right shrink-0 space-y-0.5">
                  <p className="text-xs text-gray-500">
                    <span className="font-medium text-gray-700">{t('storage.buckets_section.max_size', 'Mida màx.:')}</span>{' '}
                    {bucket.file_size_limit != null
                      ? formatBytes(bucket.file_size_limit)
                      : t('storage.buckets_section.no_limit', 'Sense límit')}
                  </p>
                </div>
              </div>
              {bucket.allowed_mime_types && bucket.allowed_mime_types.length > 0 && (
                <div className="mt-2 flex flex-wrap gap-1.5">
                  {bucket.allowed_mime_types.map((mime) => (
                    <span
                      key={mime}
                      className="text-xs px-2 py-0.5 bg-indigo-50 text-indigo-600 rounded-full font-mono"
                    >
                      {mime}
                    </span>
                  ))}
                </div>
              )}
              {(!bucket.allowed_mime_types || bucket.allowed_mime_types.length === 0) && (
                <p className="mt-1 text-xs text-gray-400 italic">Tots els tipus MIME permesos</p>
              )}
            </div>
          ))}
        </div>
      </section>

      {/* ── Bucket tenant-files info box ─────────────── */}
      {tenantFileBucket && (
        <div className="bg-amber-50 border border-amber-200 rounded-xl px-5 py-3 text-xs text-amber-800 space-y-1">
          <p className="font-semibold">Bucket «tenant-files» — restriccions absolutes</p>
          <p>
            Els límits per tenant configurats a la pàgina de detall
            <strong> no poden superar</strong> els límits d'aquest bucket:
          </p>
          <ul className="list-disc list-inside space-y-0.5 pl-1">
            <li>
              Mida màxima de fitxer:{' '}
              <strong>
                {tenantFileBucket.file_size_limit != null
                  ? formatBytes(tenantFileBucket.file_size_limit)
                  : 'Sense límit'}
              </strong>
            </li>
            <li>
              MIME types permesos:{' '}
              <strong>
                {tenantFileBucket.allowed_mime_types &&
                tenantFileBucket.allowed_mime_types.length > 0
                  ? tenantFileBucket.allowed_mime_types.join(', ')
                  : 'Tots'}
              </strong>
            </li>
          </ul>
        </div>
      )}

      {/* ── Per-tenant stats ─────────────────────────── */}
      <section className="bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
        <div className="px-6 py-4 border-b border-gray-100">
          <h2 className="text-sm font-semibold text-gray-700">
            Estadístiques per tenant
            <span className="ml-1.5 text-xs font-normal text-gray-400">
              origen: esquema data
            </span>
          </h2>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="bg-gray-50 text-xs text-gray-400 font-medium uppercase tracking-wide">
                <th className="px-6 py-3 text-left">Tenant</th>
                <th className="px-4 py-3 text-right">Fitxers (Drive)</th>
                <th className="px-4 py-3 text-right">Drive</th>
                <th className="px-4 py-3 text-right">Docs fitxers</th>
                <th className="px-4 py-3 text-right">Documents</th>
                <th className="px-4 py-3 text-right">Total</th>
                <th className="px-4 py-3 text-right">Egress (mes)</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-50">
              {tenants.map((t) => {
                const committed = t.storage_usage?.committed_bytes ?? BigInt(0)
                const reserved = t.storage_usage?.reserved_bytes ?? BigInt(0)
                const docsBytes = t.storage_usage?.documents_committed_bytes ?? BigInt(0)
                const total = committed + reserved + docsBytes
                const egress = egressMap.get(t.id) ?? BigInt(0)

                return (
                  <tr key={t.id} className="hover:bg-gray-50 transition-colors">
                    <td className="px-6 py-3 font-medium text-gray-800">
                      {t.name}
                      <span className="ml-2 text-xs text-gray-400">{t.slug}</span>
                    </td>
                    <td className="px-4 py-3 text-right text-gray-600">
                      {t.storage_usage?.file_count ?? 0}
                    </td>
                    <td className="px-4 py-3 text-right text-gray-600">
                      {formatBytes(committed + reserved)}
                    </td>
                    <td className="px-4 py-3 text-right text-gray-600">
                      {t.storage_usage?.documents_file_count ?? 0}
                    </td>
                    <td className="px-4 py-3 text-right text-gray-600">
                      {formatBytes(docsBytes)}
                    </td>
                    <td className="px-4 py-3 text-right font-medium text-gray-800">
                      {formatBytes(total)}
                    </td>
                    <td className="px-4 py-3 text-right text-indigo-600">
                      {formatBytes(egress)}
                    </td>
                  </tr>
                )
              })}
              {tenants.length === 0 && (
                <tr>
                  <td colSpan={7} className="px-6 py-6 text-center text-sm text-gray-400">
                    Sense tenants actius.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  )
}
