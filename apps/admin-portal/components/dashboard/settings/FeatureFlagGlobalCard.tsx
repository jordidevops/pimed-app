'use client'

import { useTransition, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { upsertFeatureFlag } from '@/app/admin/actions/control-plane'
import { getFeatureFlagHint, getFeatureFlagTitle } from '@/lib/featureFlags'

export type GlobalFeatureFlag = {
  key: string
  description: string | null
  is_enabled: boolean
  rollout_percentage: number
}

interface Props {
  flag: GlobalFeatureFlag
}

export function FeatureFlagGlobalCard({ flag }: Props) {
  const { t } = useTranslation('settings')
  const [isPending, startTransition] = useTransition()
  const [enabled, setEnabled] = useState(flag.is_enabled)
  const [rollout, setRollout] = useState(String(flag.rollout_percentage))
  const [savedMsg, setSavedMsg] = useState<string | null>(null)

  const title = getFeatureFlagTitle(flag.key)
  const hint = getFeatureFlagHint(flag.key, flag.description)

  function showSaved() {
    setSavedMsg(t('settings.feature_flags.saved', 'Desat ✓'))
    setTimeout(() => setSavedMsg(null), 2500)
  }

  function handleToggle() {
    const newEnabled = !enabled
    setEnabled(newEnabled)
    startTransition(async () => {
      await upsertFeatureFlag({
        key: flag.key,
        description: flag.description ?? undefined,
        is_enabled: newEnabled,
        rollout_percentage: Math.min(100, Math.max(0, parseInt(rollout || '0', 10))),
      })
      showSaved()
    })
  }

  function handleSaveRollout() {
    const parsed = Math.min(100, Math.max(0, parseInt(rollout || '0', 10)))
    setRollout(String(parsed))
    startTransition(async () => {
      await upsertFeatureFlag({
        key: flag.key,
        description: flag.description ?? undefined,
        is_enabled: enabled,
        rollout_percentage: parsed,
      })
      showSaved()
    })
  }

  const rolloutChanged = rollout !== String(flag.rollout_percentage)

  return (
    <section className="bg-white rounded-2xl border border-gray-100 p-6 shadow-sm space-y-4">
      <div className="flex items-start justify-between gap-4">
        <div className="min-w-0">
          <h3 className="text-base font-semibold text-gray-900">{title}</h3>
          <p className="text-xs font-mono text-gray-400 mt-0.5 truncate">{flag.key}</p>
          {hint && <p className="text-sm text-gray-500 mt-2">{hint}</p>}
        </div>
        <div className="flex items-center gap-3 shrink-0">
          {savedMsg && <span className="text-sm text-green-600 font-medium">{savedMsg}</span>}
          <button
            type="button"
            onClick={handleToggle}
            disabled={isPending}
            className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors disabled:opacity-50 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2 ${
              enabled ? 'bg-indigo-500' : 'bg-gray-200'
            }`}
            role="switch"
            aria-checked={enabled}
            aria-label={title}
          >
            <span
              className={`inline-block h-4 w-4 rounded-full bg-white shadow transition-transform ${
                enabled ? 'translate-x-6' : 'translate-x-1'
              }`}
            />
          </button>
        </div>
      </div>

      <div
        className={`inline-flex items-center gap-2 px-3 py-1.5 rounded-lg text-sm font-medium ${
          enabled
            ? 'bg-green-50 text-green-700 border border-green-200'
            : 'bg-gray-100 text-gray-500 border border-gray-200'
        }`}
      >
        <span className={`h-2 w-2 rounded-full ${enabled ? 'bg-green-500' : 'bg-gray-400'}`} />
        {enabled
          ? t('settings.feature_flags.status_on', 'Actiu globalment')
          : t('settings.feature_flags.status_off', 'Inactiu globalment')}
      </div>

      <div className="border-t border-gray-50 pt-4 space-y-2">
        <label className="block text-xs font-medium text-gray-600">
          {t('settings.feature_flags.rollout_label', 'Rollout progressiu (%)')}
        </label>
        <p className="text-xs text-gray-400">
          {t(
            'settings.feature_flags.rollout_hint',
            'Percentatge de tenants (0–100) quan el flag està habilitat i no hi ha override. 100 = tots.',
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
            type="button"
            onClick={handleSaveRollout}
            disabled={isPending || !rolloutChanged}
            className="text-sm font-medium px-4 py-1.5 rounded-lg bg-indigo-600 text-white hover:bg-indigo-700 transition disabled:opacity-50"
          >
            {t('settings.feature_flags.save_rollout', 'Desar rollout')}
          </button>
        </div>
      </div>
    </section>
  )
}
