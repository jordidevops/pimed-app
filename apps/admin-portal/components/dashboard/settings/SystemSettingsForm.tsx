'use client'

import { useState, useTransition } from 'react'
import { updateAuthSettings, updateOnboardingSettings } from '@/app/admin/actions/control-plane'
import type { AuthSettings, OnboardingSettings } from '@/app/admin/actions/control-plane'
import { useTranslation } from 'react-i18next'

// ---------------------------------------------------------------------------
// Reusable toggle row
// ---------------------------------------------------------------------------
function ToggleRow({
  label,
  description,
  checked,
  onChange,
  disabled,
}: {
  label: string
  description: string
  checked: boolean
  onChange: (v: boolean) => void
  disabled?: boolean
}) {
  return (
    <div className="flex items-start justify-between gap-4 py-4 border-b border-gray-100 last:border-0">
      <div className="min-w-0">
        <p className="text-sm font-medium text-gray-800">{label}</p>
        <p className="text-xs text-gray-500 mt-0.5">{description}</p>
      </div>
      <button
        type="button"
        role="switch"
        aria-checked={checked}
        disabled={disabled}
        onClick={() => onChange(!checked)}
        className={`relative inline-flex h-6 w-11 shrink-0 items-center rounded-full transition-colors focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2 disabled:opacity-50 ${
          checked ? 'bg-indigo-600' : 'bg-gray-200'
        }`}
      >
        <span
          className={`inline-block h-4 w-4 transform rounded-full bg-white shadow transition-transform ${
            checked ? 'translate-x-6' : 'translate-x-1'
          }`}
        />
      </button>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Section card wrapper
// ---------------------------------------------------------------------------
function SettingsSection({
  title,
  description,
  children,
}: {
  title: string
  description: string
  children: React.ReactNode
}) {
  return (
    <div className="bg-white rounded-xl border border-gray-200 shadow-sm overflow-hidden">
      <div className="px-6 py-4 border-b border-gray-100 bg-gray-50">
        <h2 className="text-base font-semibold text-gray-900">{title}</h2>
        <p className="text-sm text-gray-500 mt-0.5">{description}</p>
      </div>
      <div className="px-6 divide-y divide-gray-100">{children}</div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Main component
// ---------------------------------------------------------------------------
export function SystemSettingsForm({
  initialAuth,
  initialOnboarding,
}: {
  initialAuth: AuthSettings
  initialOnboarding: OnboardingSettings
}) {
  const { t } = useTranslation('settings')
  const [auth, setAuth] = useState<AuthSettings>(initialAuth)
  const [onboarding, setOnboarding] = useState<OnboardingSettings>(initialOnboarding)
  const [isPending, startTransition] = useTransition()
  const [saved, setSaved] = useState(false)
  const [error, setError] = useState<string | null>(null)

  function patchAuth(key: keyof AuthSettings, value: boolean) {
    setSaved(false)
    setError(null)
    setAuth((prev) => ({ ...prev, [key]: value }))
  }

  function patchOnboarding(key: keyof OnboardingSettings, value: boolean) {
    setSaved(false)
    setError(null)
    setOnboarding((prev) => ({ ...prev, [key]: value }))
  }

  function handleSave() {
    startTransition(async () => {
      try {
        await Promise.all([
          updateAuthSettings(auth),
          updateOnboardingSettings(onboarding),
        ])
        setSaved(true)
      } catch (err) {
        setError(err instanceof Error ? err.message : t('settings.system.error', 'Error desant la configuració'))
      }
    })
  }

  return (
    <div className="space-y-6">
      {/* Auth module */}
      <SettingsSection
        title={t('settings.system.auth_section.title', 'Autenticació')}
        description={t('settings.system.auth_section.description', "Mètodes d'accés disponibles per als usuaris del portal de clients.")}
      >
        <ToggleRow
          label={t('settings.system.auth_section.google_label', 'Accés amb Google')}
          description={t('settings.system.auth_section.google_desc', "Mostra el botó 'Continuar amb Google' al formulari de login del portal de clients.")}
          checked={auth.google_oauth_enabled}
          onChange={(v) => patchAuth('google_oauth_enabled', v)}
          disabled={isPending}
        />
        <ToggleRow
          label={t('settings.system.auth_section.password_label', 'Accés amb contrasenya')}
          description={t('settings.system.auth_section.password_desc', 'Permet als usuaris iniciar sessió amb correu i contrasenya.')}
          checked={auth.password_login_enabled}
          onChange={(v) => patchAuth('password_login_enabled', v)}
          disabled={isPending}
        />
        <ToggleRow
          label={t('settings.system.auth_section.magic_link_label', 'Magic link per correu')}
          description={t('settings.system.auth_section.magic_link_desc', "L'usuari introdueix el seu correu i rep un link per accedir directament, sense contrasenya.")}
          checked={auth.magic_link_enabled}
          onChange={(v) => patchAuth('magic_link_enabled', v)}
          disabled={isPending}
        />
      </SettingsSection>

      {/* Onboarding module */}
      <SettingsSection
        title={t('settings.system.onboarding_section.title', 'Alta de nous clients')}
        description={t('settings.system.onboarding_section.description', "Control del flux d'incorporació de nous tenants a la plataforma.")}
      >
        <ToggleRow
          label={t('settings.system.onboarding_section.self_signup_label', 'Auto-registre públic')}
          description={t('settings.system.onboarding_section.self_signup_desc', "Permet que nous usuaris creïn el seu propi tenant sense invitació prèvia de l'administrador.")}
          checked={onboarding.self_signup_enabled}
          onChange={(v) => patchOnboarding('self_signup_enabled', v)}
          disabled={isPending}
        />
      </SettingsSection>

      {/* Footer */}
      <div className="flex items-center justify-between">
        <div>
          {saved && (
            <p className="text-sm text-green-600 font-medium">{t('settings.system.saved', '✓ Configuració desada correctament')}</p>
          )}
          {error && (
            <p className="text-sm text-red-600">{error}</p>
          )}
        </div>
        <button
          type="button"
          onClick={handleSave}
          disabled={isPending}
          className="bg-indigo-600 hover:bg-indigo-700 disabled:opacity-50 text-white text-sm font-semibold px-5 py-2.5 rounded-lg transition"
        >
          {isPending ? t('settings.system.saving', 'Desant...') : t('settings.system.save', 'Desar canvis')}
        </button>
      </div>
    </div>
  )
}
