'use client'

import { useState, useTransition } from 'react'
import { useTranslation } from 'react-i18next'
import {
  updateGeocodingSettings,
  type GeocodingModuleSettings,
  type GeocodingOpsSummary,
} from '@/app/admin/actions/geocoding-settings'

interface Props {
  initial: GeocodingOpsSummary
  canEdit: boolean
}

export function AdminGeocodingOpsPanel({ initial, canEdit }: Props) {
  const { t } = useTranslation('settings')
  const [isPending, startTransition] = useTransition()
  const [settings, setSettings] = useState<GeocodingModuleSettings>(initial.settings)
  const [savedMsg, setSavedMsg] = useState<string | null>(null)
  const [errorMsg, setErrorMsg] = useState<string | null>(null)

  function showSaved() {
    setSavedMsg(t('settings.geocoding.saved', 'Desat ✓'))
    setTimeout(() => setSavedMsg(null), 2500)
  }

  function save(next: GeocodingModuleSettings) {
    if (!canEdit) return
    setErrorMsg(null)
    setSettings(next)
    startTransition(async () => {
      try {
        await updateGeocodingSettings(next)
        showSaved()
      } catch (err) {
        setErrorMsg(err instanceof Error ? err.message : String(err))
      }
    })
  }

  function handleToggleEnabled() {
    save({ ...settings, nominatim_enabled: !settings.nominatim_enabled })
  }

  function handleSaveLimits() {
    save({
      ...settings,
      nominatim_global_max_per_second: Math.max(
        1,
        Math.min(10, Math.floor(Number(settings.nominatim_global_max_per_second) || 1)),
      ),
      nominatim_global_max_per_minute: Math.max(
        1,
        Math.min(120, Math.floor(Number(settings.nominatim_global_max_per_minute) || 50)),
      ),
    })
  }

  const enabled = settings.nominatim_enabled

  return (
    <div className="space-y-8">
      <section className="bg-white rounded-2xl border border-gray-100 p-6 shadow-sm space-y-4">
        <div className="flex items-start justify-between gap-4">
          <div>
            <h2 className="text-base font-semibold text-gray-900">
              {t('settings.geocoding.nominatim_title', 'Nominatim (OpenStreetMap públic)')}
            </h2>
            <p className="text-sm text-gray-500 mt-1 max-w-2xl">
              {t(
                'settings.geocoding.nominatim_help',
                'El servei públic no té compte ni API key. La política OSM és ~1 petició/segon per IP de plataforma. Per volum de producció cal Google BYO al tenant.',
              )}{' '}
              <a
                href="https://operations.osmfoundation.org/policies/nominatim/"
                target="_blank"
                rel="noreferrer"
                className="text-indigo-600 hover:underline"
              >
                {t('settings.geocoding.policy_link', 'Política Nominatim')}
              </a>
            </p>
          </div>
          <div className="flex items-center gap-3 shrink-0">
            {savedMsg && <span className="text-sm text-green-600 font-medium">{savedMsg}</span>}
            <button
              type="button"
              onClick={handleToggleEnabled}
              disabled={isPending || !canEdit}
              className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors disabled:opacity-50 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2 ${
                enabled ? 'bg-indigo-500' : 'bg-gray-200'
              }`}
              aria-pressed={enabled}
              title={
                canEdit
                  ? t('settings.geocoding.kill_switch', 'Kill switch Nominatim')
                  : t('settings.geocoding.read_only', 'Només lectura')
              }
            >
              <span
                className={`inline-block h-4 w-4 transform rounded-full bg-white transition ${
                  enabled ? 'translate-x-6' : 'translate-x-1'
                }`}
              />
            </button>
          </div>
        </div>

        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
          <Stat
            label={t('settings.geocoding.stat_second', 'Aquest segon')}
            value={`${initial.second_used} / ${settings.nominatim_global_max_per_second}`}
          />
          <Stat
            label={t('settings.geocoding.stat_minute', 'Aquest minut')}
            value={`${initial.minute_used} / ${settings.nominatim_global_max_per_minute}`}
          />
          <Stat
            label={t('settings.geocoding.stat_status', 'Estat')}
            value={
              enabled
                ? t('settings.geocoding.status_on', 'Actiu')
                : t('settings.geocoding.status_off', 'Desactivat')
            }
          />
          <Stat
            label={t('settings.geocoding.stat_upstream_429', '429 OSM avui')}
            value={String(initial.upstream_429_today)}
          />
        </div>

        {canEdit && (
          <div className="flex flex-wrap items-end gap-4 pt-2 border-t border-gray-100">
            <label className="text-sm text-gray-700">
              {t('settings.geocoding.max_per_second', 'Màx / segon')}
              <input
                type="number"
                min={1}
                max={10}
                value={settings.nominatim_global_max_per_second}
                onChange={(e) =>
                  setSettings((s) => ({
                    ...s,
                    nominatim_global_max_per_second: Number(e.target.value),
                  }))
                }
                className="mt-1 block w-28 rounded-md border border-gray-200 px-2 py-1.5 text-sm"
              />
            </label>
            <label className="text-sm text-gray-700">
              {t('settings.geocoding.max_per_minute', 'Màx / minut')}
              <input
                type="number"
                min={1}
                max={120}
                value={settings.nominatim_global_max_per_minute}
                onChange={(e) =>
                  setSettings((s) => ({
                    ...s,
                    nominatim_global_max_per_minute: Number(e.target.value),
                  }))
                }
                className="mt-1 block w-28 rounded-md border border-gray-200 px-2 py-1.5 text-sm"
              />
            </label>
            <button
              type="button"
              onClick={handleSaveLimits}
              disabled={isPending}
              className="rounded-md bg-indigo-600 px-3 py-2 text-sm font-medium text-white hover:bg-indigo-500 disabled:opacity-50"
            >
              {t('settings.geocoding.save_limits', 'Desar límits')}
            </button>
          </div>
        )}

        {errorMsg && <p className="text-sm text-red-600">{errorMsg}</p>}
      </section>

      <section className="bg-white rounded-2xl border border-gray-100 p-6 shadow-sm space-y-4">
        <h2 className="text-base font-semibold text-gray-900">
          {t('settings.geocoding.today_title', 'Ús Nominatim (avui)')}
        </h2>
        <div className="grid grid-cols-2 sm:grid-cols-5 gap-3">
          <Stat label={t('settings.geocoding.today_success', 'Success')} value={String(initial.today.success)} />
          <Stat label={t('settings.geocoding.today_cached', 'Cache')} value={String(initial.today.cached)} />
          <Stat label={t('settings.geocoding.today_blocked', 'Blocked')} value={String(initial.today.blocked)} />
          <Stat label={t('settings.geocoding.today_errors', 'Provider err')} value={String(initial.today.provider_error)} />
          <Stat label={t('settings.geocoding.today_network', 'Network')} value={String(initial.today.network_error)} />
        </div>
      </section>

      <section className="bg-white rounded-2xl border border-gray-100 p-6 shadow-sm space-y-4">
        <div>
          <h2 className="text-base font-semibold text-gray-900">
            {t('settings.geocoding.alerts_title', 'Alertes d’abús / ops (30 dies)')}
          </h2>
          <p className="text-sm text-gray-500 mt-1">
            {t(
              'settings.geocoding.alerts_help',
              'Piques de blocked_requests per tenant, kill switch i 429 del servei públic OSM.',
            )}
          </p>
        </div>

        {initial.alerts.length === 0 ? (
          <p className="text-sm text-gray-400">
            {t('settings.geocoding.alerts_empty', 'Cap alerta recent.')}
          </p>
        ) : (
          <div className="overflow-x-auto">
            <table className="min-w-full text-sm">
              <thead>
                <tr className="text-left text-xs text-gray-500 border-b border-gray-100">
                  <th className="py-2 pr-3 font-medium">{t('settings.geocoding.col_date', 'Data')}</th>
                  <th className="py-2 pr-3 font-medium">{t('settings.geocoding.col_tenant', 'Tenant')}</th>
                  <th className="py-2 pr-3 font-medium">{t('settings.geocoding.col_provider', 'Provider')}</th>
                  <th className="py-2 pr-3 font-medium">{t('settings.geocoding.col_reason', 'Motiu')}</th>
                  <th className="py-2 pr-3 font-medium">{t('settings.geocoding.col_blocked', 'Blocked')}</th>
                </tr>
              </thead>
              <tbody>
                {initial.alerts.map((a) => (
                  <tr key={a.id} className="border-b border-gray-50">
                    <td className="py-2 pr-3 tabular-nums text-gray-700">{a.usage_date}</td>
                    <td className="py-2 pr-3 text-gray-900">
                      {a.tenant_name ?? a.tenant_id ?? '—'}
                    </td>
                    <td className="py-2 pr-3 font-mono text-xs text-gray-600">{a.provider_key ?? '—'}</td>
                    <td className="py-2 pr-3 text-gray-700">{a.reason ?? '—'}</td>
                    <td className="py-2 pr-3 tabular-nums text-gray-700">
                      {a.blocked_requests}
                      {a.threshold > 0 ? ` / ${a.threshold}` : ''}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </div>
  )
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg bg-gray-50 px-3 py-2">
      <p className="text-[11px] text-gray-500">{label}</p>
      <p className="text-lg font-semibold tabular-nums text-gray-900">{value}</p>
    </div>
  )
}
