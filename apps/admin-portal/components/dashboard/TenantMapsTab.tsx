'use client'

import { useState, useTransition } from 'react'
import { toast } from 'sonner'
import Link from 'next/link'
import { TenantLimitsForm } from '@/components/dashboard/TenantLimitsForm'
import type { TenantGeocodingData } from '@/app/admin/actions/control-plane'
import type { MapsJsPlatformEntitlementRow } from '@/app/admin/actions/maps-js-platform-entitlements'
import type { MapsJsClientErrorRow } from '@/app/admin/actions/maps-js-client-errors'
import {
  activateMapsJsPlatformEntitlement,
  deactivateMapsJsPlatformEntitlement,
  verifyMapsJsPlatformEntitlementActive,
} from '@/app/admin/actions/maps-js-platform-entitlements'

function formatDdMmYyyy(iso: string | null | undefined): string {
  if (!iso) return '—'
  const d = new Date(iso)
  if (!Number.isFinite(d.getTime())) return '—'
  const dd = String(d.getDate()).padStart(2, '0')
  const mm = String(d.getMonth() + 1).padStart(2, '0')
  const yyyy = d.getFullYear()
  return `${dd}/${mm}/${yyyy}`
}

type Props = {
  tenantId: string
  geocodingData: TenantGeocodingData
  entitlement: MapsJsPlatformEntitlementRow | null
  byokActiveSince: string | null
  clientErrors: MapsJsClientErrorRow[]
}

export function TenantMapsTab({
  tenantId,
  geocodingData,
  entitlement: initialEntitlement,
  byokActiveSince,
  clientErrors,
}: Props) {
  const [entitlement, setEntitlement] = useState(initialEntitlement)
  const [days, setDays] = useState('30')
  const [pending, startTransition] = useTransition()
  const [verifyMsg, setVerifyMsg] = useState<string | null>(null)

  const active = entitlement?.is_active_by_dates ?? false

  function onActivate() {
    startTransition(async () => {
      const fd = new FormData()
      fd.set('tenantId', tenantId)
      fd.set('days', days)
      const res = await activateMapsJsPlatformEntitlement(fd)
      if (!res.ok) {
        toast.error(res.message)
        return
      }
      toast.success('Trial activat')
      const expires = new Date(Date.now() + Number(days) * 24 * 60 * 60 * 1000).toISOString()
      setEntitlement({
        tenant_id: tenantId,
        tenant_name: entitlement?.tenant_name ?? null,
        activated_at: new Date().toISOString(),
        expires_at: expires,
        is_active_by_dates: true,
      })
    })
  }

  function onDeactivate() {
    startTransition(async () => {
      const fd = new FormData()
      fd.set('tenantId', tenantId)
      const res = await deactivateMapsJsPlatformEntitlement(fd)
      if (!res.ok) {
        toast.error(res.message)
        return
      }
      toast.success('Trial desactivat')
      setEntitlement(null)
      setVerifyMsg(null)
    })
  }

  function onVerify() {
    startTransition(async () => {
      try {
        const res = await verifyMapsJsPlatformEntitlementActive(tenantId)
        setVerifyMsg(res.message)
        if (res.activated_at) {
          setEntitlement({
            tenant_id: tenantId,
            tenant_name: entitlement?.tenant_name ?? null,
            activated_at: res.activated_at,
            expires_at: res.expires_at,
            is_active_by_dates: res.is_active,
          })
        } else {
          setEntitlement(null)
        }
        toast.success(res.message)
      } catch (err) {
        toast.error(err instanceof Error ? err.message : String(err))
      }
    })
  }

  return (
    <div className="space-y-6">
      <TenantLimitsForm
        tenantId={tenantId}
        storageBlocked={false}
        storageBlockedReason={null}
        limits={null}
        bucketFileSizeLimitBytes={null}
        bucketAllowedMimes={null}
        emailDomainsEnabled={false}
        maxEmailDomains={1}
        geocodingData={geocodingData}
        sections="geocoding"
      />

      <section className="bg-white rounded-2xl border border-gray-100 p-6 space-y-4 shadow-sm">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h3 className="text-base font-semibold text-gray-900">Maps JS — platform trial</h3>
            <p className="text-xs text-gray-400 mt-0.5">
              Entitlement de plataforma quan no hi ha BYOK.{' '}
              <Link
                href="/dashboard/settings/maps-js-platform-entitlements"
                className="text-indigo-600 hover:underline"
              >
                Gestió global
              </Link>
            </p>
          </div>
          <span
            className={`text-xs font-medium px-2.5 py-1 rounded-full ${
              active ? 'bg-green-50 text-green-700' : 'bg-gray-100 text-gray-600'
            }`}
          >
            {active ? 'Actiu' : 'Inactiu'}
          </span>
        </div>

        <dl className="grid grid-cols-1 sm:grid-cols-3 gap-3 text-sm">
          <div className="rounded-lg bg-gray-50 p-3">
            <dt className="text-xs text-gray-500">Activat</dt>
            <dd className="font-medium mt-0.5">{formatDdMmYyyy(entitlement?.activated_at)}</dd>
          </div>
          <div className="rounded-lg bg-gray-50 p-3">
            <dt className="text-xs text-gray-500">Caduca</dt>
            <dd className="font-medium mt-0.5">
              {entitlement?.expires_at ? formatDdMmYyyy(entitlement.expires_at) : entitlement ? 'mai' : '—'}
            </dd>
          </div>
          <div className="rounded-lg bg-gray-50 p-3">
            <dt className="text-xs text-gray-500">BYOK Maps JS</dt>
            <dd className="font-medium mt-0.5">
              {byokActiveSince ? `Actiu des de ${formatDdMmYyyy(byokActiveSince)}` : 'No configurat'}
            </dd>
          </div>
        </dl>

        {verifyMsg && <p className="text-xs text-gray-500">Postgres: {verifyMsg}</p>}

        <div className="flex flex-wrap gap-2 items-end">
          <div>
            <label className="block text-xs text-gray-600 mb-1">Dies</label>
            <input
              type="number"
              min={1}
              max={365}
              value={days}
              onChange={(e) => setDays(e.target.value)}
              className="border rounded px-3 py-2 text-sm w-24"
            />
          </div>
          <button
            type="button"
            disabled={pending}
            onClick={onActivate}
            className="bg-gray-900 text-white text-sm px-4 py-2 rounded disabled:opacity-50"
          >
            Activar / renovar
          </button>
          <button
            type="button"
            disabled={pending || !entitlement}
            onClick={onDeactivate}
            className="border border-gray-300 text-sm px-4 py-2 rounded disabled:opacity-50"
          >
            Desactivar
          </button>
          <button
            type="button"
            disabled={pending}
            onClick={onVerify}
            className="border border-gray-300 text-sm px-4 py-2 rounded disabled:opacity-50"
          >
            Comprovar Postgres
          </button>
        </div>
      </section>

      <section className="bg-white rounded-2xl border border-gray-100 overflow-hidden shadow-sm">
        <div className="px-6 py-4 border-b border-gray-100 flex flex-wrap items-center justify-between gap-2">
          <div>
            <h3 className="text-base font-semibold text-gray-900">Errors Maps JS (client)</h3>
            <p className="text-xs text-gray-400 mt-0.5">
              Telemetria{' '}
              <code className="bg-gray-100 px-1 rounded">onError</code> /{' '}
              <code className="bg-gray-100 px-1 rounded">gm_authFailure</code>.{' '}
              <Link
                href="/dashboard/settings/maps-js-client-errors"
                className="text-indigo-600 hover:underline"
              >
                Vista global
              </Link>
            </p>
          </div>
        </div>
        <div className="overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead className="bg-gray-50 border-b border-gray-200">
              <tr>
                <th className="text-left py-3 px-4 font-medium text-gray-600">Category</th>
                <th className="text-left py-3 px-4 font-medium text-gray-600">Code</th>
                <th className="text-left py-3 px-4 font-medium text-gray-600">Origin</th>
                <th className="text-left py-3 px-4 font-medium text-gray-600">First</th>
                <th className="text-left py-3 px-4 font-medium text-gray-600">Last</th>
                <th className="text-left py-3 px-4 font-medium text-gray-600">Count</th>
              </tr>
            </thead>
            <tbody>
              {clientErrors.length === 0 ? (
                <tr>
                  <td colSpan={6} className="py-8 px-4 text-gray-500">
                    Cap error registrat per aquest tenant.
                  </td>
                </tr>
              ) : (
                clientErrors.map((r, idx) => (
                  <tr
                    key={`${r.category}-${r.code}-${r.origin}-${idx}`}
                    className="border-b border-gray-100"
                  >
                    <td className="py-2 px-4">{r.category}</td>
                    <td className="py-2 px-4">{r.code}</td>
                    <td className="py-2 px-4">{r.origin}</td>
                    <td className="py-2 px-4">{formatDdMmYyyy(r.first_seen_at)}</td>
                    <td className="py-2 px-4">{formatDdMmYyyy(r.last_seen_at)}</td>
                    <td className="py-2 px-4 font-medium">{r.count}</td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  )
}
