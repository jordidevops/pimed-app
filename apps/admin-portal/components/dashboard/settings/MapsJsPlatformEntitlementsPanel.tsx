'use client'

import { useMemo, useState, useTransition } from 'react'
import { toast } from 'sonner'
import {
  activateMapsJsPlatformEntitlement,
  deactivateMapsJsPlatformEntitlement,
  upsertMapsJsPlatformVaultKey,
  upsertMapsJsPlatformMapId,
  verifyMapsJsPlatformEntitlementActive,
  type MapsJsPlatformEntitlementRow,
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
  tenants: Array<{ id: string; name: string }>
  entitlements: MapsJsPlatformEntitlementRow[]
  byokKeys: Array<{ tenant_id: string; tenant_name: string | null; active_since: string }>
  vaultKey: {
    present: boolean
    registry_key_version: number | null
    last_rotated_at: string | null
  }
  platformMapId: string | null
}

export function MapsJsPlatformEntitlementsPanel({
  tenants,
  entitlements: initialEntitlements,
  byokKeys,
  vaultKey: initialVault,
  platformMapId: initialMapId,
}: Props) {
  const [entitlements, setEntitlements] = useState(initialEntitlements)
  const [vaultKey, setVaultKey] = useState(initialVault)
  const [platformMapId, setPlatformMapId] = useState(initialMapId)
  const [verifyMap, setVerifyMap] = useState<
    Record<string, { is_active: boolean; message: string; at: string } | undefined>
  >({})
  const [platformKeyInput, setPlatformKeyInput] = useState('')
  const [mapIdInput, setMapIdInput] = useState(initialMapId ?? '')
  const [pending, startTransition] = useTransition()

  const activeCount = useMemo(
    () => entitlements.filter((e) => e.is_active_by_dates).length,
    [entitlements],
  )

  function refreshEntitlementRow(tenantId: string, patch: Partial<MapsJsPlatformEntitlementRow>) {
    setEntitlements((prev) =>
      prev.map((e) => (e.tenant_id === tenantId ? { ...e, ...patch } : e)),
    )
  }

  function onVerify(tenantId: string) {
    startTransition(async () => {
      try {
        const res = await verifyMapsJsPlatformEntitlementActive(tenantId)
        setVerifyMap((m) => ({
          ...m,
          [tenantId]: {
            is_active: res.is_active,
            message: res.message,
            at: new Date().toISOString(),
          },
        }))
        refreshEntitlementRow(tenantId, {
          is_active_by_dates: res.is_active,
          activated_at: res.activated_at ?? entitlements.find((e) => e.tenant_id === tenantId)?.activated_at ?? '',
          expires_at: res.expires_at,
        })
        toast.success(res.message)
      } catch (err) {
        toast.error(err instanceof Error ? err.message : String(err))
      }
    })
  }

  function onSaveVaultKey() {
    startTransition(async () => {
      const res = await upsertMapsJsPlatformVaultKey(platformKeyInput)
      if (!res.ok) {
        toast.error(res.message)
        return
      }
      toast.success(res.message)
      setPlatformKeyInput('')
      setVaultKey((v) => ({
        ...v,
        present: true,
        last_rotated_at: new Date().toISOString(),
        registry_key_version: (v.registry_key_version ?? 0) + 1,
      }))
    })
  }

  function onSaveMapId() {
    startTransition(async () => {
      const res = await upsertMapsJsPlatformMapId(mapIdInput)
      if (!res.ok) {
        toast.error(res.message)
        return
      }
      toast.success(res.message)
      const next = mapIdInput.trim() || null
      setPlatformMapId(next)
      setMapIdInput(next ?? '')
    })
  }

  return (
    <div className="space-y-6">
      <div className="rounded-lg border border-gray-200 bg-white p-4 space-y-3">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div>
            <h2 className="text-sm font-semibold text-gray-900">Clau platform trial (Vault)</h2>
            <p className="text-xs text-gray-500 mt-0.5">
              Preferible desar-la aquí (Vault DB). El <code className="bg-gray-100 px-1 rounded">.env</code>{' '}
              <code className="bg-gray-100 px-1 rounded">MAPS_JS_PLATFORM_TRIAL_API_KEY</code> només és fallback local / emergència.
            </p>
            <p className="text-xs text-gray-500 mt-0.5">
              Nom Vault: <code className="bg-gray-100 px-1 rounded">maps_js_platform_trial_api_key</code>
            </p>
          </div>
          <span
            className={`text-xs font-medium px-2.5 py-1 rounded-full ${
              vaultKey.present
                ? 'bg-green-50 text-green-700'
                : 'bg-amber-50 text-amber-800'
            }`}
          >
            {vaultKey.present ? 'Present al Vault' : 'Absència al Vault'}
          </span>
        </div>
        <p className="text-xs text-gray-500">
          Versió registre: {vaultKey.registry_key_version ?? '—'} · Última rotació:{' '}
          {formatDdMmYyyy(vaultKey.last_rotated_at)}
        </p>
        <div className="flex flex-wrap gap-2 items-end">
          <div className="flex-1 min-w-[220px]">
            <label className="block text-xs text-gray-600 mb-1">Nova clau API (Maps JS)</label>
            <input
              type="password"
              autoComplete="off"
              value={platformKeyInput}
              onChange={(e) => setPlatformKeyInput(e.target.value)}
              placeholder="AIza…"
              className="w-full border rounded px-3 py-2 text-sm"
            />
          </div>
          <button
            type="button"
            disabled={pending || platformKeyInput.trim().length < 20}
            onClick={onSaveVaultKey}
            className="bg-indigo-600 text-white text-sm px-4 py-2 rounded disabled:opacity-50"
          >
            Desa al Vault
          </button>
        </div>
        {!vaultKey.present && (
          <p className="text-xs text-amber-700">
            Sense aquesta clau, els tenants amb entitlement actiu rebran{' '}
            <code>maps_js_platform_key_missing</code> (o el fallback env).
          </p>
        )}
      </div>

      <div className="rounded-lg border border-gray-200 bg-white p-4 space-y-3">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div>
            <h2 className="text-sm font-semibold text-gray-900">Map ID de plataforma</h2>
            <p className="text-xs text-gray-500 mt-0.5">
              Del mateix projecte GCP que la clau trial. No és secret (es entrega al navegador amb la clau).
              Fallback env opcional: <code className="bg-gray-100 px-1 rounded">MAPS_JS_PLATFORM_MAP_ID</code>.
            </p>
          </div>
          <span
            className={`text-xs font-medium px-2.5 py-1 rounded-full ${
              platformMapId ? 'bg-green-50 text-green-700' : 'bg-amber-50 text-amber-800'
            }`}
          >
            {platformMapId ? 'Configurat' : 'Sense Map ID'}
          </span>
        </div>
        {platformMapId ? (
          <p className="text-xs text-gray-600 font-mono">{platformMapId}</p>
        ) : null}
        <div className="flex flex-wrap gap-2 items-end">
          <div className="flex-1 min-w-[220px]">
            <label className="block text-xs text-gray-600 mb-1">Map ID</label>
            <input
              type="text"
              autoComplete="off"
              value={mapIdInput}
              onChange={(e) => setMapIdInput(e.target.value)}
              placeholder="Map ID de GCP (JavaScript)"
              className="w-full border rounded px-3 py-2 text-sm font-mono"
            />
          </div>
          <button
            type="button"
            disabled={pending}
            onClick={onSaveMapId}
            className="bg-indigo-600 text-white text-sm px-4 py-2 rounded disabled:opacity-50"
          >
            Desa Map ID
          </button>
        </div>
        <ol className="list-decimal pl-4 text-xs text-gray-500 space-y-0.5">
          <li>Al projecte GCP de la clau trial: Maps → Map Management.</li>
          <li>Crea un Map ID tipus JavaScript (mateix projecte que la API key).</li>
          <li>Enganxa’l aquí perquè el trial lliuri clau + Map ID coherents.</li>
        </ol>
        <a
          className="inline-block text-xs text-indigo-600 underline"
          href="https://console.cloud.google.com/google/maps-apis/studio/maps"
          target="_blank"
          rel="noreferrer"
        >
          Obrir Map Management (GCP)
        </a>
      </div>

      <div className="rounded-lg border border-gray-200 bg-white p-4 space-y-4">
        <h2 className="text-sm font-semibold text-gray-900">Activate / deactivate</h2>
        <p className="text-xs text-gray-500">{activeCount} actius per dates (de {entitlements.length})</p>

        <form action={activateMapsJsPlatformEntitlement} className="space-y-3">
          <div className="flex flex-wrap gap-3 items-end">
            <div>
              <label className="block text-xs text-gray-600 mb-1">Tenant</label>
              <select name="tenantId" required className="border rounded px-3 py-2 text-sm">
                <option value="" />
                {tenants.map((ten) => (
                  <option key={ten.id} value={ten.id}>
                    {ten.name}
                  </option>
                ))}
              </select>
            </div>
            <div>
              <label className="block text-xs text-gray-600 mb-1">Dies</label>
              <input
                name="days"
                type="number"
                min={1}
                max={365}
                defaultValue={30}
                className="border rounded px-3 py-2 text-sm w-28"
              />
            </div>
            <button type="submit" className="bg-gray-900 text-white text-sm px-4 py-2 rounded">
              Activate trial
            </button>
          </div>
        </form>

        <form action={deactivateMapsJsPlatformEntitlement} className="space-y-3 border-t pt-4">
          <div className="flex flex-wrap gap-3 items-end">
            <div>
              <label className="block text-xs text-gray-600 mb-1">Tenant</label>
              <select name="tenantId" required className="border rounded px-3 py-2 text-sm">
                <option value="" />
                {tenants.map((ten) => (
                  <option key={ten.id} value={ten.id}>
                    {ten.name}
                  </option>
                ))}
              </select>
            </div>
            <button
              type="submit"
              className="bg-white border border-gray-300 text-gray-900 text-sm px-4 py-2 rounded"
            >
              Deactivate
            </button>
          </div>
        </form>
      </div>

      <div className="rounded-lg border border-gray-200 bg-white overflow-hidden">
        <div className="overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead className="bg-gray-50 border-b border-gray-200">
              <tr>
                <th className="text-left py-3 px-4 font-medium text-gray-600">Tenant</th>
                <th className="text-left py-3 px-4 font-medium text-gray-600">Activat</th>
                <th className="text-left py-3 px-4 font-medium text-gray-600">Caduca</th>
                <th className="text-left py-3 px-4 font-medium text-gray-600">Actiu</th>
                <th className="text-left py-3 px-4 font-medium text-gray-600">Verificar</th>
              </tr>
            </thead>
            <tbody>
              {entitlements.length === 0 ? (
                <tr>
                  <td colSpan={5} className="py-10 px-4 text-gray-500">
                    Cap entitlement configurat.
                  </td>
                </tr>
              ) : (
                entitlements.map((e) => {
                  const verified = verifyMap[e.tenant_id]
                  const active = verified?.is_active ?? e.is_active_by_dates
                  return (
                    <tr key={e.tenant_id} className="border-b border-gray-100">
                      <td className="py-2 px-4">{e.tenant_name ?? e.tenant_id}</td>
                      <td className="py-2 px-4">{formatDdMmYyyy(e.activated_at)}</td>
                      <td className="py-2 px-4">
                        {e.expires_at ? formatDdMmYyyy(e.expires_at) : 'mai'}
                      </td>
                      <td className="py-2 px-4">
                        <span
                          className={`text-xs font-medium px-2 py-0.5 rounded-full ${
                            active ? 'bg-green-50 text-green-700' : 'bg-gray-100 text-gray-600'
                          }`}
                        >
                          {active ? 'Actiu' : 'Inactiu'}
                        </span>
                        {verified && (
                          <p className="text-[11px] text-gray-400 mt-1" title={verified.at}>
                            Postgres: {verified.message}
                          </p>
                        )}
                      </td>
                      <td className="py-2 px-4">
                        <button
                          type="button"
                          disabled={pending}
                          onClick={() => onVerify(e.tenant_id)}
                          className="text-xs px-2.5 py-1 rounded border border-gray-300 hover:bg-gray-50 disabled:opacity-50"
                        >
                          Comprovar Postgres
                        </button>
                      </td>
                    </tr>
                  )
                })
              )}
            </tbody>
          </table>
        </div>
      </div>

      <div className="rounded-lg border border-gray-200 bg-white overflow-hidden">
        <div className="px-4 py-3 border-b border-gray-100">
          <h2 className="text-sm font-semibold text-gray-900">BYOK actiu (Maps JS)</h2>
        </div>
        <div className="overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead className="bg-gray-50 border-b border-gray-200">
              <tr>
                <th className="text-left py-3 px-4 font-medium text-gray-600">Tenant</th>
                <th className="text-left py-3 px-4 font-medium text-gray-600">Actiu des de</th>
              </tr>
            </thead>
            <tbody>
              {byokKeys.length === 0 ? (
                <tr>
                  <td colSpan={2} className="py-10 px-4 text-gray-500">
                    Cap clau BYOK activa.
                  </td>
                </tr>
              ) : (
                byokKeys.map((r) => (
                  <tr key={r.tenant_id} className="border-b border-gray-100">
                    <td className="py-2 px-4">{r.tenant_name ?? r.tenant_id}</td>
                    <td className="py-2 px-4">{formatDdMmYyyy(r.active_since)}</td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  )
}
