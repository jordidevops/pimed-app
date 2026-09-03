'use client'

import Link from 'next/link'
import { useTransition } from 'react'
import { useTranslation } from 'react-i18next'
import {
  deleteFeatureOverride,
  upsertFeatureOverride,
} from '@/app/admin/actions/control-plane'
import {
  getFeatureFlagHint,
  getFeatureFlagTitle,
  isTenantFeatureEffectivelyOn,
} from '@/lib/featureFlags'

export type TenantFeatureFlagRow = {
  key: string
  description: string | null
  is_enabled: boolean
  rollout_percentage: number
}

export type TenantFeatureOverrideRow = {
  feature_key: string
  override_status: boolean
}

interface Props {
  tenantId: string
  flags: TenantFeatureFlagRow[]
  overrides: TenantFeatureOverrideRow[]
}

export function TenantFeatureFlagsTab({ tenantId, flags, overrides }: Props) {
  const { t } = useTranslation('tenants')
  const [isPending, startTransition] = useTransition()

  const overrideMap = new Map(overrides.map((o) => [o.feature_key, o.override_status]))

  const activeCount = flags.filter((f) =>
    isTenantFeatureEffectivelyOn(f, overrideMap.get(f.key)),
  ).length

  function handleToggle(key: string, currentOverride: boolean | undefined) {
    startTransition(async () => {
      // Sense override: el toggle crea override al valor contrari de l'efectiu global 100%
      // Amb override: inverteix; si queda igual que el global 100% es podria deixar — mantenim override explícit
      const currentlyOn = isTenantFeatureEffectivelyOn(
        flags.find((f) => f.key === key)!,
        currentOverride,
      )
      await upsertFeatureOverride(tenantId, key, !currentlyOn)
    })
  }

  function handleClearOverride(key: string) {
    startTransition(async () => {
      await deleteFeatureOverride(tenantId, key)
    })
  }

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h2 className="text-base font-semibold text-gray-900">
            {t('tenants.detail.feature_flags.title', 'Feature flags')}
          </h2>
          <p className="text-sm text-gray-500 mt-1 max-w-xl">
            {t(
              'tenants.detail.feature_flags.hint',
              'Override per aquest tenant. Sense override s’aplica el valor global (i el rollout).',
            )}{' '}
            <Link
              href="/dashboard/settings/feature-flags"
              className="text-indigo-600 hover:underline"
            >
              {t('tenants.detail.feature_flags.global_link', 'Configuració global')}
            </Link>
          </p>
        </div>
        <span className="inline-flex items-center rounded-full bg-indigo-50 text-indigo-700 text-sm font-semibold px-3 py-1 border border-indigo-100">
          {activeCount}/{flags.length}{' '}
          {t('tenants.detail.feature_flags.active_suffix', 'actius')}
        </span>
      </div>

      <div className="bg-white rounded-2xl border border-gray-100 shadow-sm divide-y divide-gray-50">
        {flags.map((flag) => {
          const override = overrideMap.get(flag.key)
          const hasOverride = override !== undefined
          const effectiveOn = isTenantFeatureEffectivelyOn(flag, override)
          const title = getFeatureFlagTitle(flag.key)
          const hint = getFeatureFlagHint(flag.key, flag.description)

          return (
            <div key={flag.key} className="px-5 py-4 flex items-center justify-between gap-4">
              <div className="min-w-0">
                <p className="text-sm font-semibold text-gray-900">{title}</p>
                <p className="text-xs font-mono text-gray-400 mt-0.5">{flag.key}</p>
                {hint && <p className="text-xs text-gray-500 mt-1 line-clamp-2">{hint}</p>}
                <div className="flex flex-wrap gap-2 mt-2">
                  {hasOverride ? (
                    <span className="text-xs font-medium text-amber-700 bg-amber-50 border border-amber-100 rounded-full px-2 py-0.5">
                      {t('tenants.detail.feature_flags.override_active', 'Override actiu')}
                    </span>
                  ) : (
                    <span className="text-xs text-gray-400">
                      {t('tenants.detail.feature_flags.from_global', 'Des del global')}
                      {flag.is_enabled && flag.rollout_percentage < 100
                        ? ` · rollout ${flag.rollout_percentage}%`
                        : ''}
                    </span>
                  )}
                  <span
                    className={`text-xs font-medium rounded-full px-2 py-0.5 border ${
                      effectiveOn
                        ? 'bg-green-50 text-green-700 border-green-100'
                        : 'bg-gray-50 text-gray-500 border-gray-100'
                    }`}
                  >
                    {effectiveOn
                      ? t('tenants.detail.feature_flags.on', 'Actiu')
                      : t('tenants.detail.feature_flags.off', 'Inactiu')}
                  </span>
                </div>
              </div>

              <div className="flex items-center gap-2 shrink-0">
                <button
                  type="button"
                  onClick={() => handleToggle(flag.key, override)}
                  disabled={isPending}
                  className={`relative inline-flex h-5 w-9 items-center rounded-full transition-colors disabled:opacity-50 ${
                    effectiveOn ? 'bg-indigo-500' : 'bg-gray-200'
                  }`}
                  role="switch"
                  aria-checked={effectiveOn}
                  aria-label={title}
                >
                  <span
                    className={`inline-block h-3.5 w-3.5 rounded-full bg-white shadow transition-transform ${
                      effectiveOn ? 'translate-x-4.5' : 'translate-x-0.5'
                    }`}
                  />
                </button>
                {hasOverride && (
                  <button
                    type="button"
                    onClick={() => handleClearOverride(flag.key)}
                    disabled={isPending}
                    className="text-xs text-gray-400 hover:text-red-500 transition"
                    title={t('tenants.detail.feature_flags.clear_override', 'Treure override')}
                  >
                    ✕
                  </button>
                )}
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}
