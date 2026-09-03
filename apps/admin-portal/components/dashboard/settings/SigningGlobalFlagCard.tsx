'use client'

import { useTransition, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { upsertFeatureFlag } from '@/app/admin/actions/control-plane'

interface Props {
  isEnabled: boolean
  rolloutPercentage: number
}

export function SigningGlobalFlagCard({ isEnabled, rolloutPercentage }: Props) {
  const { t } = useTranslation('settings')
  const [isPending, startTransition] = useTransition()
  const [enabled, setEnabled] = useState(isEnabled)
  const [rollout, setRollout] = useState(rolloutPercentage.toString())
  const [savedMsg, setSavedMsg] = useState<string | null>(null)

  function showSaved() {
    setSavedMsg(t('settings.signing.flag.saved', 'Desat ✓'))
    setTimeout(() => setSavedMsg(null), 2500)
  }

  function handleToggle() {
    const newEnabled = !enabled
    setEnabled(newEnabled)
    startTransition(async () => {
      await upsertFeatureFlag({
        key: 'tenant_signing_enabled',
        is_enabled: newEnabled,
        rollout_percentage: parseInt(rollout || '0', 10),
      })
      showSaved()
    })
  }

  function handleSaveRollout() {
    const parsed = Math.min(100, Math.max(0, parseInt(rollout || '0', 10)))
    startTransition(async () => {
      await upsertFeatureFlag({
        key: 'tenant_signing_enabled',
        is_enabled: enabled,
        rollout_percentage: parsed,
      })
      showSaved()
    })
  }

  const rolloutChanged = rollout !== rolloutPercentage.toString()

  return (
    <section className="bg-white rounded-2xl border border-gray-100 p-6 shadow-sm space-y-5">
      <div>
        <h3 className="text-base font-semibold text-gray-900">
          {t('settings.signing.flag.title', 'Activació global de Firmes')}
        </h3>
        <p className="text-sm text-gray-500 mt-1">
          {t(
            'settings.signing.flag.hint',
            "Controla si el mòdul de firmes digitals és accessible per als tenants. Els overrides per tenant (a la fitxa del tenant → tab Firmes) sempre tenen prioritat sobre aquest valor global.",
          )}
        </p>
      </div>

      {/* Toggle row */}
      <div className="flex items-center justify-between gap-4 border-t border-gray-50 pt-4">
        <div>
          <p className="text-sm font-mono font-medium text-gray-800">
            tenant_signing_enabled
          </p>
          <p className="text-xs text-gray-400 mt-0.5">
            {t(
              'settings.signing.flag.global_flag_hint',
              'Valor per defecte per a tots els tenants sense override específic',
            )}
          </p>
        </div>
        <div className="flex items-center gap-3 shrink-0">
          {savedMsg && (
            <span className="text-sm text-green-600 font-medium">{savedMsg}</span>
          )}
          <button
            onClick={handleToggle}
            disabled={isPending}
            className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors disabled:opacity-50 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2 ${
              enabled ? 'bg-indigo-500' : 'bg-gray-200'
            }`}
            role="switch"
            aria-checked={enabled}
          >
            <span
              className={`inline-block h-4 w-4 rounded-full bg-white shadow transition-transform ${
                enabled ? 'translate-x-6' : 'translate-x-1'
              }`}
            />
          </button>
        </div>
      </div>

      {/* Status pill */}
      <div
        className={`inline-flex items-center gap-2 px-3 py-1.5 rounded-lg text-sm font-medium ${
          enabled
            ? 'bg-green-50 text-green-700 border border-green-200'
            : 'bg-gray-100 text-gray-500 border border-gray-200'
        }`}
      >
        <span className={`h-2 w-2 rounded-full ${enabled ? 'bg-green-500' : 'bg-gray-400'}`} />
        {enabled
          ? t('settings.signing.flag.status_enabled', 'Firmes habilitades globalment')
          : t('settings.signing.flag.status_disabled', 'Firmes deshabilitades globalment')}
      </div>

      {/* Rollout percentage */}
      <div className="border-t border-gray-50 pt-4 space-y-2">
        <label className="block text-xs font-medium text-gray-600">
          {t('settings.signing.flag.rollout_label', 'Rollout progressiu (%)')}
        </label>
        <p className="text-xs text-gray-400">
          {t(
            'settings.signing.flag.rollout_hint',
            'Percentatge de tenants (0-100) que veuen la funcionalitat quan el flag està habilitat. 100 = tots els tenants.',
          )}
        </p>
        <div className="flex items-center gap-3 pt-1">
          <input
            type="number"
            min={0}
            max={100}
            value={rollout}
            onChange={(e) => setRollout(e.target.value)}
            disabled={isPending}
            className="w-24 text-sm border border-gray-200 rounded-lg px-3 py-1.5 focus:outline-none focus:ring-2 focus:ring-indigo-500 disabled:bg-gray-50"
          />
          <button
            onClick={handleSaveRollout}
            disabled={isPending || !rolloutChanged}
            className="text-sm font-medium px-4 py-1.5 rounded-lg bg-indigo-600 text-white hover:bg-indigo-700 transition disabled:opacity-50"
          >
            {t('settings.signing.flag.save_rollout', 'Desar rollout')}
          </button>
        </div>
      </div>
    </section>
  )
}
