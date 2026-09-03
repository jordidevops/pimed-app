'use client'

import { useTransition, useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  upsertFeatureOverride,
  deleteFeatureOverride,
} from '@/app/admin/actions/control-plane'
import { setTenantSigningAdminDisabled, setTenantSigningCredits } from '@/app/admin/actions/signing'

interface SigningConfig {
  mode: string
  is_active: boolean
  admin_disabled: boolean
  signing_credits: number
  docuseal_api_url: string
}

interface Props {
  tenantId: string
  flagIsEnabled: boolean
  flagRolloutPct: number
  override: boolean | null
  signingConfig: SigningConfig | null
}

export function TenantSigningTab({
  tenantId,
  flagIsEnabled,
  flagRolloutPct,
  override,
  signingConfig,
}: Props) {
  const { t } = useTranslation('tenants')
  const [isPending, startTransition] = useTransition()
  const [savedMsg, setSavedMsg] = useState<string | null>(null)
  const [adminDisabledState, setAdminDisabledState] = useState(
    signingConfig?.admin_disabled ?? false,
  )
  const [creditsInput, setCreditsInput] = useState(
    String(signingConfig?.signing_credits ?? 0),
  )
  const [creditsSaved, setCreditsSaved] = useState<string | null>(null)

  const hasOverride = override !== null
  const effectiveValue = hasOverride ? override! : flagIsEnabled

  function showSaved() {
    setSavedMsg(t('tenants.limits.saved', 'Desat ✓'))
    setTimeout(() => setSavedMsg(null), 2500)
  }

  function handleToggle() {
    startTransition(async () => {
      await upsertFeatureOverride(tenantId, 'tenant_signing_enabled', !effectiveValue)
      showSaved()
    })
  }

  function handleReset() {
    startTransition(async () => {
      await deleteFeatureOverride(tenantId, 'tenant_signing_enabled')
      showSaved()
    })
  }

  return (
    <div className="space-y-6">
      {/* Override section */}
      <section className="bg-white rounded-2xl border border-gray-100 p-6 shadow-sm space-y-5">
        <div>
          <h3 className="text-base font-semibold text-gray-900">
            {t('tenants.signing.access_title', 'Accés al mòdul de Firmes')}
          </h3>
          <p className="text-sm text-gray-500 mt-1">
            {t(
              'tenants.signing.access_hint',
              'Override per a aquest tenant. Té prioritat sobre el valor global de la plataforma. Gestiona el valor global a Configuració → Signing.',
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
              {t('tenants.signing.global_value_hint', 'Valor global: {{value}}', {
                value: flagIsEnabled
                  ? t('tenants.signing.enabled', 'Habilitat') +
                    (flagRolloutPct < 100 ? ` (rollout ${flagRolloutPct}%)` : '')
                  : t('tenants.signing.disabled', 'Deshabilitat'),
              })}
            </p>
            {hasOverride && (
              <span className="inline-block mt-1 text-xs font-medium text-amber-600 bg-amber-50 px-2 py-0.5 rounded">
                {t('tenants.limits.override_active', 'Override actiu')} —{' '}
                {effectiveValue
                  ? t('tenants.signing.enabled', 'Habilitat')
                  : t('tenants.signing.disabled', 'Deshabilitat')}
              </span>
            )}
          </div>

          <div className="flex items-center gap-3 shrink-0">
            {savedMsg && (
              <span className="text-sm text-green-600 font-medium">{savedMsg}</span>
            )}
            {hasOverride && (
              <button
                onClick={handleReset}
                disabled={isPending}
                className="text-xs text-gray-400 hover:text-red-500 transition px-2 py-1 rounded hover:bg-red-50 disabled:opacity-50"
              >
                {t('tenants.limits.reset_override', 'Reseteja override')}
              </button>
            )}
            <button
              onClick={handleToggle}
              disabled={isPending}
              className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors disabled:opacity-50 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2 ${
                effectiveValue ? 'bg-indigo-500' : 'bg-gray-200'
              }`}
              role="switch"
              aria-checked={effectiveValue}
            >
              <span
                className={`inline-block h-4 w-4 rounded-full bg-white shadow transition-transform ${
                  effectiveValue ? 'translate-x-6' : 'translate-x-1'
                }`}
              />
            </button>
          </div>
        </div>

        {/* Status pill */}
        <div
          className={`inline-flex items-center gap-2 px-3 py-1.5 rounded-lg text-sm font-medium ${
            effectiveValue
              ? 'bg-green-50 text-green-700 border border-green-200'
              : 'bg-gray-100 text-gray-500 border border-gray-200'
          }`}
        >
          <span
            className={`h-2 w-2 rounded-full ${effectiveValue ? 'bg-green-500' : 'bg-gray-400'}`}
          />
          {effectiveValue
            ? t('tenants.signing.status_enabled', 'Firmes habilitades per a aquest tenant')
            : t('tenants.signing.status_disabled', 'Firmes deshabilitades per a aquest tenant')}
        </div>
      </section>

      {/* Credits management (platform mode only) */}
      <section className="bg-white rounded-2xl border border-gray-100 p-6 shadow-sm space-y-5">
        <div>
          <h3 className="text-base font-semibold text-gray-900">
            {t('tenants.signing.credits_title', 'Crèdits de signatura (mode platform)')}
          </h3>
          <p className="text-sm text-gray-500 mt-1">
            {t(
              'tenants.signing.credits_hint',
              'Cada firma de document consumeix 1 crèdit. En mode BYO els crèdits no s\'apliquen.',
            )}
          </p>
        </div>

        <div className="flex items-end gap-3 border-t border-gray-50 pt-4">
          <div className="flex-1">
            <label className="block text-xs text-gray-500 mb-1">
              {t('tenants.signing.credits_label', 'Crèdits disponibles')}
            </label>
            <input
              type="number"
              min={0}
              step={10}
              value={creditsInput}
              onChange={(e) => setCreditsInput(e.target.value)}
              disabled={isPending}
              className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-400 disabled:opacity-50"
            />
          </div>
          <div className="flex items-center gap-2 shrink-0">
            {creditsSaved && (
              <span className="text-sm text-green-600 font-medium">{creditsSaved}</span>
            )}
            <button
              onClick={() => {
                const val = parseInt(creditsInput, 10)
                if (isNaN(val) || val < 0) return
                startTransition(async () => {
                  await setTenantSigningCredits(tenantId, val)
                  setCreditsSaved(t('tenants.signing.credits_saved', 'Desat ✓'))
                  setTimeout(() => setCreditsSaved(null), 2500)
                })
              }}
              disabled={isPending}
              className="bg-indigo-600 hover:bg-indigo-700 disabled:opacity-50 text-white text-sm font-semibold px-4 py-2 rounded-lg transition"
            >
              {t('tenants.signing.credits_save', 'Desar')}
            </button>
            {/* Quick top-up buttons */}
            {[10, 50, 100].map((n) => (
              <button
                key={n}
                onClick={() => {
                  const current = parseInt(creditsInput, 10) || 0
                  setCreditsInput(String(current + n))
                }}
                disabled={isPending}
                className="text-xs text-indigo-600 border border-indigo-200 hover:bg-indigo-50 disabled:opacity-50 px-2 py-1.5 rounded-lg transition"
              >
                +{n}
              </button>
            ))}
          </div>
        </div>

        {signingConfig && signingConfig.mode !== 'platform' && (
          <p className="text-xs text-gray-400 italic">
            {t('tenants.signing.credits_byo_note', 'Aquest tenant usa mode BYO. Els crèdits no tenen efecte.')}
          </p>
        )}
        {!signingConfig && (
          <p className="text-xs text-gray-400 italic">
            {t('tenants.signing.credits_no_config', 'El tenant encara no ha activat les firmes. Els crèdits es podran assignar un cop ho faci.')}
          </p>
        )}
      </section>

      {/* Admin forced disable */}
      <section className="bg-white rounded-2xl border border-gray-100 p-6 shadow-sm space-y-5">
        <div>
          <h3 className="text-base font-semibold text-gray-900">
            {t('tenants.signing.admin_disable_title', 'Desactivació forçada per admin')}
          </h3>
          <p className="text-sm text-gray-500 mt-1">
            {t(
              'tenants.signing.admin_disable_hint',
              'Quan actiu, el tenant no pot usar la signatura independentment del seu estat. Reservat per a incidències o incompliments.',
            )}
          </p>
        </div>

        <div className="flex items-center justify-between gap-4 border-t border-gray-50 pt-4">
          <div>
            <p className="text-sm font-medium text-gray-800">
              {t('tenants.signing.admin_disabled_label', 'Desactivació forçada')}
            </p>
            {adminDisabledState && (
              <span className="inline-block mt-1 text-xs font-medium text-red-600 bg-red-50 px-2 py-0.5 rounded">
                {t(
                  'tenants.signing.admin_disabled_active_badge',
                  'Firmes BLOQUEJADES per admin-portal',
                )}
              </span>
            )}
          </div>

          <div className="flex items-center gap-3 shrink-0">
            {savedMsg && (
              <span className="text-sm text-green-600 font-medium">{savedMsg}</span>
            )}
            <button
              onClick={() => {
                const next = !adminDisabledState
                setAdminDisabledState(next)
                startTransition(async () => {
                  await setTenantSigningAdminDisabled(tenantId, next)
                  showSaved()
                })
              }}
              disabled={isPending}
              className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors disabled:opacity-50 focus:outline-none focus:ring-2 focus:ring-red-500 focus:ring-offset-2 ${
                adminDisabledState ? 'bg-red-500' : 'bg-gray-200'
              }`}
              role="switch"
              aria-checked={adminDisabledState}
            >
              <span
                className={`inline-block h-4 w-4 rounded-full bg-white shadow transition-transform ${
                  adminDisabledState ? 'translate-x-6' : 'translate-x-1'
                }`}
              />
            </button>
          </div>
        </div>
      </section>

      {/* DocuSeal config (read-only) */}
      <section className="bg-white rounded-2xl border border-gray-100 p-6 shadow-sm space-y-4">
        <div>
          <h3 className="text-base font-semibold text-gray-900">
            {t('tenants.signing.config_title', 'Configuració de DocuSeal')}
          </h3>
          <p className="text-sm text-gray-500 mt-1">
            {t(
              'tenants.signing.config_hint',
              'Configuració activa de DocuSeal per a aquest tenant. Gestionada des del portal del tenant.',
            )}
          </p>
        </div>

        {signingConfig ? (
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
            <ConfigCard
              label={t('tenants.signing.config_mode', 'Mode')}
              value={
                signingConfig.mode === 'platform'
                  ? t('tenants.signing.mode_platform', 'Platform')
                  : t('tenants.signing.mode_byo', 'BYO (clau pròpia)')
              }
            />
            <ConfigCard
              label={t('tenants.signing.config_active', 'DocuSeal actiu')}
              value={
                signingConfig.is_active
                  ? t('tenants.signing.yes', 'Sí')
                  : t('tenants.signing.no', 'No')
              }
              highlight={!signingConfig.is_active ? 'warning' : undefined}
            />
            <ConfigCard
              label={t('tenants.signing.config_credits', 'Crèdits platform')}
              value={signingConfig.mode === 'platform' ? String(signingConfig.signing_credits) : '—'}
            />
            <ConfigCard
              label={t('tenants.signing.config_url', 'URL DocuSeal')}
              value={signingConfig.docuseal_api_url || '—'}
              mono
            />
          </div>
        ) : (
          <div className="rounded-lg border border-dashed border-gray-200 px-6 py-8 text-center">
            <p className="text-sm text-gray-400">
              {t(
                'tenants.signing.config_not_configured',
                "Aquest tenant encara no ha configurat DocuSeal. La configuració es crea quan el tenant guarda els paràmetres des del portal.",
              )}
            </p>
          </div>
        )}
      </section>
    </div>
  )
}

function ConfigCard({
  label,
  value,
  mono,
  highlight,
}: {
  label: string
  value: string
  mono?: boolean
  highlight?: 'warning'
}) {
  return (
    <div className={`rounded-xl p-4 ${highlight === 'warning' ? 'bg-amber-50' : 'bg-gray-50'}`}>
      <p className="text-xs text-gray-400 mb-0.5 truncate">{label}</p>
      <p
        className={`text-sm font-semibold truncate ${
          highlight === 'warning' ? 'text-amber-700' : 'text-gray-800'
        } ${mono ? 'font-mono text-xs' : ''}`}
      >
        {value}
      </p>
    </div>
  )
}
