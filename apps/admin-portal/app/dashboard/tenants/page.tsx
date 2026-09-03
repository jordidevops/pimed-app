import Link from 'next/link'
import { prisma } from '@/lib/prisma'
import { archiveTenant } from '@/app/admin/actions/tenants'
import { getT } from '@/lib/i18n/server'

function formatBytes(bytes: bigint | number): string {
  const n = Number(bytes)
  if (n < 1024) return `${n} B`
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`
  return `${(n / 1024 ** 3).toFixed(2)} GB`
}

export default async function TenantsPage() {
  const t = getT('tenants')
  const tc = getT('common')
  const tenants = await prisma.tenants.findMany({
    include: {
      plans: true,
      storage_usage: true,
      _count: { select: { tenant_members: true } },
      tenant_members: {
        where: { is_active: true },
        select: { role: true },
      },
    },
    orderBy: { created_at: 'desc' },
  })

  return (
    <>
      <div className="flex items-center justify-between mb-6">
        <h1 className="text-2xl font-bold text-gray-900">{t('tenants.list.title', 'Tenants')}</h1>
        <Link
          href="/dashboard/tenants/new"
          className="text-xs font-medium px-3 py-1.5 rounded-lg bg-indigo-600 text-white hover:bg-indigo-700 transition"
        >
          {tc('common.new_tenant', '+ Nou tenant')}
        </Link>
      </div>

      <div className="bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-gray-100 bg-gray-50">
                <th className="text-left px-6 py-3 font-medium text-gray-500">{t('tenants.list.table.name', 'Nom')}</th>
                <th className="text-left px-6 py-3 font-medium text-gray-500">{t('tenants.list.table.plan', 'Pla')}</th>
                <th className="text-right px-6 py-3 font-medium text-gray-500">{t('tenants.list.table.users', 'Usuaris')}</th>
                <th className="text-right px-6 py-3 font-medium text-gray-500">{t('tenants.list.table.storage_usage', 'Ús storage')}</th>
                <th className="text-left px-6 py-3 font-medium text-gray-500">{t('tenants.list.table.status', 'Estat')}</th>
                <th className="text-left px-6 py-3 font-medium text-gray-500">{t('tenants.list.table.created', 'Creat')}</th>
                <th className="px-6 py-3" />
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-50">
              {tenants.map((tenant) => {
                const toggleArchive = archiveTenant.bind(null, tenant.id, tenant.is_active)
                const used =
                  (tenant.storage_usage?.committed_bytes ?? BigInt(0)) +
                  (tenant.storage_usage?.reserved_bytes ?? BigInt(0)) +
                  (tenant.storage_usage?.documents_committed_bytes ?? BigInt(0)) +
                  (tenant.storage_usage?.documents_reserved_bytes ?? BigInt(0))

                const activeMembers = tenant.tenant_members.length
                const hasActiveOwner = tenant.tenant_members.some((m) => m.role === 'owner')
                const maxUsers = tenant.plans?.max_members ?? 0
                const isOverQuota = maxUsers > 0 && activeMembers > maxUsers

                return (
                  <tr key={tenant.id} className="hover:bg-gray-50 transition">
                    <td className="px-6 py-4">
                      <Link href={`/dashboard/tenants/${tenant.id}`}>
                        <p className="font-medium text-gray-900 hover:text-indigo-600">{tenant.name}</p>
                        <p className="text-xs text-gray-400">{tenant.slug}</p>
                      </Link>
                      {!hasActiveOwner && (
                        <span className="mt-1 inline-flex items-center gap-1 text-xs text-amber-700 bg-amber-50 border border-amber-100 rounded-full px-2 py-0.5">
                          {t('tenants.list.no_owner', '⚠ Sense owner actiu')}
                        </span>
                      )}
                    </td>
                    <td className="px-6 py-4 text-gray-700">
                      {tenant.plans?.display_name ?? '—'}
                    </td>
                    <td className="px-6 py-4 text-right">
                      <span
                        className={`tabular-nums text-sm ${
                          isOverQuota ? 'text-red-600 font-semibold' : 'text-gray-700'
                        }`}
                      >
                        {activeMembers}
                        {maxUsers > 0 && (
                          <span className="text-gray-400 font-normal"> / {maxUsers}</span>
                        )}
                      </span>
                      {isOverQuota && (
                          <p className="text-xs text-red-500 mt-0.5">{t('tenants.list.over_quota', 'Quota superada')}</p>
                      )}
                    </td>
                    <td className="px-6 py-4 text-right text-gray-500 tabular-nums text-xs">
                      {formatBytes(used)}
                    </td>
                    <td className="px-6 py-4">
                      {tenant.storage_blocked ? (
                        <span className="px-2 py-0.5 bg-red-50 text-red-700 text-xs font-medium rounded-full">
                          {t('tenants.list.status.blocked', 'Bloquejat')}
                        </span>
                      ) : tenant.is_active ? (
                        <span className="px-2 py-0.5 bg-green-50 text-green-700 text-xs font-medium rounded-full">
                          {t('tenants.list.status.active', 'Actiu')}
                        </span>
                      ) : (
                        <span className="px-2 py-0.5 bg-gray-100 text-gray-500 text-xs font-medium rounded-full">
                          {t('tenants.list.status.archived', 'Arxivat')}
                        </span>
                      )}
                    </td>
                    <td className="px-6 py-4 text-gray-500 text-xs whitespace-nowrap">
                      {new Date(tenant.created_at).toLocaleDateString('ca-ES')}
                    </td>
                    <td className="px-6 py-4">
                      <form action={toggleArchive}>
                        <button
                          type="submit"
                          className={`text-xs font-medium transition ${
                            tenant.is_active
                              ? 'text-red-600 hover:text-red-800'
                              : 'text-indigo-600 hover:text-indigo-800'
                          }`}
                        >
                          {tenant.is_active ? t('tenants.list.actions.archive', 'Arxivar') : t('tenants.list.actions.activate', 'Activar')}
                        </button>
                      </form>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>

          {tenants.length === 0 && (
            <div className="text-center py-12 text-gray-400">
              {t('tenants.list.empty', 'Encara no hi ha tenants registrats.')}
            </div>
          )}
        </div>
      </div>
    </>
  )
}
