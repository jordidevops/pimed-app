import Link from 'next/link'
import type { AtRiskUser } from '@/app/admin/actions/analytics'

interface Props {
  users: AtRiskUser[]
}

function fmtRelative(iso: string | null): string {
  if (!iso) return 'Mai'
  const days = Math.floor((Date.now() - new Date(iso).getTime()) / 86_400_000)
  if (days === 0) return 'Avui'
  if (days === 1) return 'Ahir'
  return `Fa ${days} dies`
}

function fmtDate(iso: string | null): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleDateString('ca-ES', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  })
}

const ROLE_LABELS: Record<string, string> = {
  owner:   'Propietari',
  manager: 'Gestor',
  member:  'Membre',
}

export function AtRiskUsersTable({ users }: Props) {
  return (
    <div className="bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
      <div className="px-6 py-4 border-b border-gray-50 flex items-center justify-between">
        <div>
          <h2 className="text-sm font-semibold text-gray-700">
            Usuaris en risc d&apos;inactivitat
          </h2>
          <p className="text-xs text-gray-400 mt-0.5">
            Han accedit almenys un cop però no han tornat en els últims 14 dies
          </p>
        </div>
        {users.length > 0 && (
          <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-amber-50 text-amber-700 border border-amber-100">
            {users.length}
          </span>
        )}
      </div>

      {users.length === 0 ? (
        <p className="px-6 py-8 text-sm text-gray-400 text-center">
          Cap usuari en risc — excel·lent!
        </p>
      ) : (
        <div className="overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead>
              <tr className="bg-gray-50 text-left">
                <th className="px-6 py-3 text-xs font-medium text-gray-500 uppercase tracking-wide">Usuari</th>
                <th className="px-4 py-3 text-xs font-medium text-gray-500 uppercase tracking-wide">Tenant</th>
                <th className="px-4 py-3 text-xs font-medium text-gray-500 uppercase tracking-wide">Pla</th>
                <th className="px-4 py-3 text-xs font-medium text-gray-500 uppercase tracking-wide">Rol</th>
                <th className="px-4 py-3 text-xs font-medium text-gray-500 uppercase tracking-wide whitespace-nowrap">Últim accés</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-50">
              {users.map((u) => {
                const daysInactive = u.lastLoginAt
                  ? Math.floor((Date.now() - new Date(u.lastLoginAt).getTime()) / 86_400_000)
                  : null
                const isHighRisk = daysInactive === null || daysInactive >= 30
                return (
                  <tr key={u.userId} className="hover:bg-gray-50 transition">
                    <td className="px-6 py-3">
                      <p className="font-medium text-gray-800">
                        {u.fullName ?? <span className="text-gray-400 italic font-normal">Sense nom</span>}
                      </p>
                      <p className="text-xs text-gray-400">{u.email}</p>
                    </td>
                    <td className="px-4 py-3">
                      {u.tenantId ? (
                        <Link
                          href={`/dashboard/tenants/${u.tenantId}`}
                          className="text-indigo-600 hover:text-indigo-800 hover:underline font-medium"
                        >
                          {u.tenantName}
                        </Link>
                      ) : (
                        <span className="text-gray-400 italic">Sense tenant</span>
                      )}
                    </td>
                    <td className="px-4 py-3 text-gray-500 text-xs">
                      {u.planName ?? '—'}
                    </td>
                    <td className="px-4 py-3 text-gray-500 text-xs">
                      {u.role ? (ROLE_LABELS[u.role] ?? u.role) : '—'}
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap">
                      <p className={`text-xs font-medium ${isHighRisk ? 'text-red-600' : 'text-amber-600'}`}>
                        {fmtRelative(u.lastLoginAt)}
                      </p>
                      <p className="text-xs text-gray-400">{fmtDate(u.lastLoginAt)}</p>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
