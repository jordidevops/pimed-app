'use client'

import Link from 'next/link'
import type { CustomerGrantRow } from '@/app/admin/actions/customer-identities'

function fmt(iso: string | null) {
  if (!iso) return '—'
  const d = new Date(iso)
  if (!Number.isFinite(d.getTime())) return '—'
  return d.toLocaleString('ca-ES')
}

interface Props {
  tenantId: string
  grants: CustomerGrantRow[]
}

export function TenantCustomerClientsTab({ tenantId, grants }: Props) {
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-base font-semibold text-gray-900">
            Clients del portal ({grants.length})
          </h2>
          <p className="text-sm text-gray-500 mt-1 max-w-2xl">
            Usuaris amb <code className="text-xs">customer_access_grants</code> per a aquest
            tenant. No són <code className="text-xs">tenant_members</code>. Els shares
            puntuals de butlletí no apareixen aquí (no creen Auth).
          </p>
          <p className="text-xs text-amber-800 bg-amber-50 border border-amber-100 rounded-lg px-3 py-2 mt-3 max-w-2xl">
            RGPD: emails i noms es mostren en clar només a backoffice (admin/support) per
            suport operatiu. No cal anonimitzar aquí: ja són dades del tenant a la BD i
            l&apos;accés està restringit al personal de plataforma. Eviteu exportar captures
            fora del circuit intern.
          </p>
        </div>
        <Link
          href="/dashboard/customer-identities"
          className="text-sm text-indigo-700 hover:underline"
        >
          Cerca per email →
        </Link>
      </div>

      {grants.length === 0 ? (
        <p className="text-sm text-gray-500 bg-white rounded-2xl border border-gray-100 px-4 py-6">
          Cap grant de portal client en aquest tenant.
        </p>
      ) : (
        <div className="bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
          <table className="w-full text-sm">
            <thead className="bg-gray-50 text-left text-xs uppercase tracking-wide text-gray-500">
              <tr>
                <th className="px-4 py-3 font-medium">Email</th>
                <th className="px-4 py-3 font-medium">Compte</th>
                <th className="px-4 py-3 font-medium">Principal</th>
                <th className="px-4 py-3 font-medium">Estat</th>
                <th className="px-4 py-3 font-medium">Darrer accés</th>
                <th className="px-4 py-3 font-medium">Creat</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100">
              {grants.map((g) => (
                <tr key={g.id} className="hover:bg-gray-50/80">
                  <td className="px-4 py-3">
                    <div className="font-medium text-gray-900">{g.email}</div>
                    <div className="text-xs text-gray-400 font-mono truncate max-w-[180px]">
                      {g.authUserId}
                    </div>
                  </td>
                  <td className="px-4 py-3 text-gray-700">
                    {g.accountName ?? g.accountContactId.slice(0, 8)}
                  </td>
                  <td className="px-4 py-3 text-gray-700">
                    <div>{g.principalKind}</div>
                    <div className="text-xs text-gray-400">
                      {g.principalName ?? g.principalContactId.slice(0, 8)}
                    </div>
                  </td>
                  <td className="px-4 py-3">
                    <span
                      className={`px-2 py-0.5 text-xs font-medium rounded-full ${
                        g.isActive
                          ? 'bg-green-50 text-green-700'
                          : 'bg-red-50 text-red-700'
                      }`}
                    >
                      {g.isActive ? 'Actiu' : 'Revocat'}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-gray-500 whitespace-nowrap">
                    {fmt(g.lastSeenAt)}
                  </td>
                  <td className="px-4 py-3 text-gray-500 whitespace-nowrap">
                    {fmt(g.createdAt)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <p className="text-xs text-gray-400">Tenant {tenantId}</p>
    </div>
  )
}
