'use client'

import { useState, useTransition } from 'react'
import Link from 'next/link'
import {
  lookupIdentityByEmail,
  type EmailIdentityLookup,
} from '@/app/admin/actions/customer-identities'

function Badge({
  children,
  tone = 'gray',
}: {
  children: React.ReactNode
  tone?: 'gray' | 'green' | 'amber' | 'blue' | 'red' | 'purple'
}) {
  const colors: Record<string, string> = {
    gray: 'bg-gray-100 text-gray-700',
    green: 'bg-green-50 text-green-700',
    amber: 'bg-amber-50 text-amber-800',
    blue: 'bg-blue-50 text-blue-700',
    red: 'bg-red-50 text-red-700',
    purple: 'bg-purple-50 text-purple-700',
  }
  return (
    <span className={`inline-flex px-2 py-0.5 text-xs font-medium rounded-full ${colors[tone]}`}>
      {children}
    </span>
  )
}

function fmt(iso: string | null | undefined) {
  if (!iso) return '—'
  const d = new Date(iso)
  if (!Number.isFinite(d.getTime())) return '—'
  return d.toLocaleString('ca-ES')
}

export function CustomerIdentityLookupPanel() {
  const [email, setEmail] = useState('')
  const [result, setResult] = useState<EmailIdentityLookup | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [pending, startTransition] = useTransition()

  function onSubmit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)
    setResult(null)
    startTransition(async () => {
      try {
        const data = await lookupIdentityByEmail(email)
        setResult(data)
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err))
      }
    })
  }

  return (
    <section className="bg-white rounded-2xl border border-gray-100 p-6 shadow-sm space-y-5">
      <div>
        <h2 className="text-base font-semibold text-gray-900">Cerca per correu</h2>
        <p className="text-sm text-gray-500 mt-1 max-w-2xl">
          Indica un email i veuràs en quins tenants és usuari intern, client de portal
          (grant), invitació pendent o destinatari de shares puntuals de butlletí.
          Un share puntual no crea usuari a Auth.
        </p>
      </div>

      <form onSubmit={onSubmit} className="flex flex-wrap gap-2 items-end">
        <label className="flex-1 min-w-[220px]">
          <span className="block text-xs font-medium text-gray-500 mb-1">Email</span>
          <input
            type="email"
            required
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm"
            placeholder="client@exemple.com"
          />
        </label>
        <button
          type="submit"
          disabled={pending}
          className="rounded-lg bg-gray-900 text-white text-sm font-medium px-4 py-2 disabled:opacity-50"
        >
          {pending ? 'Cercant…' : 'Cercar'}
        </button>
      </form>

      {error && (
        <p className="text-sm text-red-600 bg-red-50 rounded-lg px-3 py-2">{error}</p>
      )}

      {result && (
        <div className="space-y-6">
          <div className="flex flex-wrap gap-2 items-center text-sm">
            <span className="font-medium text-gray-900">{result.email}</span>
            {result.authUserId ? (
              <Badge tone="blue">auth.users</Badge>
            ) : (
              <Badge>Sense auth.users</Badge>
            )}
            {result.isBackoffice && <Badge tone="purple">Backoffice</Badge>}
            {result.appMetadataCustomerPortal && (
              <Badge tone="amber">app_metadata.customer_portal</Badge>
            )}
            {result.profileFullName && (
              <span className="text-gray-500">{result.profileFullName}</span>
            )}
          </div>

          {result.authUserId && (
            <p className="text-xs text-gray-400 font-mono break-all">{result.authUserId}</p>
          )}

          <div>
            <h3 className="text-sm font-semibold text-gray-900 mb-2">
              Usuari de tenant ({result.tenantMemberships.length})
            </h3>
            {result.tenantMemberships.length === 0 ? (
              <p className="text-sm text-gray-500">Cap membership a tenant_members.</p>
            ) : (
              <ul className="divide-y divide-gray-100 rounded-lg border border-gray-100">
                {result.tenantMemberships.map((m) => (
                  <li
                    key={`${m.tenantId}-${m.role}`}
                    className="flex flex-wrap items-center justify-between gap-2 px-3 py-2 text-sm"
                  >
                    <div>
                      <Link
                        href={`/dashboard/tenants/${m.tenantId}?tab=membres`}
                        className="font-medium text-indigo-700 hover:underline"
                      >
                        {m.tenantName}
                      </Link>
                      <span className="text-gray-500 ml-2">{m.role}</span>
                    </div>
                    <Badge tone={m.isActive ? 'green' : 'gray'}>
                      {m.isActive ? 'Actiu' : 'Inactiu'}
                    </Badge>
                  </li>
                ))}
              </ul>
            )}
          </div>

          <div>
            <h3 className="text-sm font-semibold text-gray-900 mb-2">
              Client de portal — grants ({result.customerGrants.length})
            </h3>
            {result.customerGrants.length === 0 ? (
              <p className="text-sm text-gray-500">Cap grant de customer portal.</p>
            ) : (
              <ul className="divide-y divide-gray-100 rounded-lg border border-gray-100">
                {result.customerGrants.map((g) => (
                  <li
                    key={g.grantId}
                    className="flex flex-wrap items-center justify-between gap-2 px-3 py-2 text-sm"
                  >
                    <div>
                      <Link
                        href={`/dashboard/tenants/${g.tenantId}?tab=clients`}
                        className="font-medium text-indigo-700 hover:underline"
                      >
                        {g.tenantName}
                      </Link>
                      <span className="text-gray-500 ml-2">
                        {g.principalKind}
                        {g.accountName ? ` · ${g.accountName}` : ''}
                      </span>
                      <p className="text-xs text-gray-400 mt-0.5">
                        Creat {fmt(g.createdAt)} · Darrer accés {fmt(g.lastSeenAt)}
                      </p>
                    </div>
                    <Badge tone={g.isActive ? 'green' : 'red'}>
                      {g.isActive ? 'Actiu' : 'Revocat'}
                    </Badge>
                  </li>
                ))}
              </ul>
            )}
          </div>

          <div>
            <h3 className="text-sm font-semibold text-gray-900 mb-2">
              Invitacions pendents ({result.pendingInvitations.length})
            </h3>
            {result.pendingInvitations.length === 0 ? (
              <p className="text-sm text-gray-500">Cap invitació pendent.</p>
            ) : (
              <ul className="divide-y divide-gray-100 rounded-lg border border-gray-100">
                {result.pendingInvitations.map((i) => (
                  <li key={i.invitationId} className="px-3 py-2 text-sm">
                    <Link
                      href={`/dashboard/tenants/${i.tenantId}?tab=clients`}
                      className="font-medium text-indigo-700 hover:underline"
                    >
                      {i.tenantName}
                    </Link>
                    <span className="text-gray-500 ml-2">
                      {i.principalKind}
                      {i.accountName ? ` · ${i.accountName}` : ''}
                    </span>
                    <p className="text-xs text-gray-400 mt-0.5">
                      Caduca {fmt(i.expiresAt)} (one-shot)
                    </p>
                  </li>
                ))}
              </ul>
            )}
          </div>

          <div>
            <h3 className="text-sm font-semibold text-gray-900 mb-2">
              Shares puntuals de butlletí ({result.bulletinShares.length})
            </h3>
            {result.bulletinShares.length === 0 ? (
              <p className="text-sm text-gray-500">
                Cap share amb aquest email com a canal/destinatari.
              </p>
            ) : (
              <ul className="divide-y divide-gray-100 rounded-lg border border-gray-100">
                {result.bulletinShares.map((s) => (
                  <li
                    key={s.shareId}
                    className="flex flex-wrap items-center justify-between gap-2 px-3 py-2 text-sm"
                  >
                    <div>
                      <span className="font-medium">{s.tenantName}</span>
                      <span className="text-gray-500 ml-2">{s.channel}</span>
                      <p className="text-xs text-gray-400 mt-0.5">
                        Link fins {fmt(s.expiresAt)} · {s.sessionCount} sessions ·{' '}
                        {s.viewCount} vistes
                        {s.revokedAt ? ` · revocat ${fmt(s.revokedAt)}` : ''}
                      </p>
                    </div>
                    <Badge tone={s.isActive ? 'green' : 'gray'}>
                      {s.isActive ? 'Link actiu' : 'Inactiu'}
                    </Badge>
                  </li>
                ))}
              </ul>
            )}
          </div>
        </div>
      )}
    </section>
  )
}
