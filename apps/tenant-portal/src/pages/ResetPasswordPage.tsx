import { useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { supabase } from '../lib/supabase'
import { Spinner } from '../components/ui/Spinner'
import { translateAuthError } from '../features/auth/utils/translateAuthError'

type Phase = 'loading' | 'form' | 'error'

/**
 * Handles the password-recovery flow triggered by supabase.auth.resetPasswordForEmail().
 *
 * Flow:
 *  1. User requests reset from LoginPage → Supabase sends email with link to /auth/reset-password
 *  2. Supabase JS auto-exchanges the token and fires the PASSWORD_RECOVERY event
 *  3. This page shows the new-password form
 *  4. On submit, calls supabase.auth.updateUser({ password }) and navigates to /dashboard
 *
 * Note: invite links continue to use /auth/callback (they fire SIGNED_IN, not PASSWORD_RECOVERY).
 */
export function ResetPasswordPage() {
  const { t } = useTranslation('auth')
  const navigate = useNavigate()
  const [phase, setPhase] = useState<Phase>('loading')
  const [errorMsg, setErrorMsg] = useState<string | null>(null)
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [formError, setFormError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  // Prevent double-navigate when PASSWORD_RECOVERY fires more than once
  const handled = useRef(false)

  useEffect(() => {
    // Supabase reports hash errors for expired / already-used links
    const hash = window.location.hash.substring(1)
    const params = new URLSearchParams(hash)
    const hashError = params.get('error_description') ?? params.get('error')
    if (hashError) {
      setErrorMsg(translateAuthError(hashError.replace(/\+/g, ' '), t))
      setPhase('error')
      return
    }

    // Safety timeout — if no token arrives in 10 s, send user back to login
    const timeout = setTimeout(() => {
      if (!handled.current) {
        navigate('/login', { replace: true })
      }
    }, 10000)

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((event) => {
      if (event === 'PASSWORD_RECOVERY' && !handled.current) {
        handled.current = true
        clearTimeout(timeout)
        setPhase('form')
      }
    })

    return () => {
      clearTimeout(timeout)
      subscription.unsubscribe()
    }
  }, [navigate, t])

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setFormError(null)

    if (password.length < 8) {
      setFormError(t('resetPasswordPage.minLength', 'La contrasenya ha de tenir com a mínim 8 caràcters.'))
      return
    }
    if (password !== confirm) {
      setFormError(t('resetPasswordPage.mismatch', 'Les contrasenyes no coincideixen.'))
      return
    }

    setSaving(true)
    const { error } = await supabase.auth.updateUser({ password })
    setSaving(false)

    if (error) {
      setFormError(translateAuthError(error, t))
      return
    }

    navigate('/dashboard', { replace: true })
  }

  // ---- Error state (expired / used link) -----------------------------------
  if (phase === 'error') {
    return (
      <div className="flex flex-col items-center justify-center min-h-screen bg-background px-4">
        <div className="bg-card rounded-2xl shadow-md p-8 max-w-sm w-full text-center space-y-4">
          <div className="w-12 h-12 rounded-full bg-red-50 flex items-center justify-center text-red-500 text-2xl mx-auto">
            ⚠
          </div>
          <h1 className="text-base font-semibold text-foreground">{t('resetPasswordPage.invalidLink', 'Enllaç no vàlid')}</h1>
          <p className="text-sm text-muted-foreground">{errorMsg}</p>
          <a
            href="/login"
            className="block w-full py-2 text-sm font-medium rounded-lg bg-indigo-600 text-white hover:bg-indigo-700 transition"
          >
            {t('resetPasswordPage.goToLogin', 'Anar al login')}
          </a>
        </div>
      </div>
    )
  }

  // ---- Loading state (waiting for PASSWORD_RECOVERY event) -----------------
  if (phase === 'loading') {
    return (
      <div className="flex flex-col items-center justify-center min-h-screen bg-background gap-4">
        <Spinner />
        <p className="text-muted-foreground text-sm">{t('resetPasswordPage.verifying', "Verificant l'enllaç...")}</p>
      </div>
    )
  }

  // ---- Password form -------------------------------------------------------
  return (
    <div className="min-h-screen bg-gradient-to-br from-indigo-50 to-blue-100 dark:from-slate-950 dark:to-slate-900 flex items-center justify-center p-4">
      <div className="w-full max-w-md">
        <div className="text-center mb-8">
          <div className="inline-flex items-center justify-center w-16 h-16 bg-indigo-600 rounded-2xl mb-4 shadow-lg">
            <LockIcon className="w-9 h-9 text-white" />
          </div>
          <h1 className="text-2xl font-bold text-foreground">{t('resetPasswordPage.title', 'Nova contrasenya')}</h1>
          <p className="text-muted-foreground mt-1 text-sm">{t('resetPasswordPage.description', 'Introdueix la teva nova contrasenya segura.')}</p>
        </div>

        <div className="bg-card rounded-2xl shadow-xl p-8">
          <form onSubmit={handleSubmit} noValidate className="space-y-5">
            <div>
              <label htmlFor="new-password" className="block text-sm font-medium text-foreground mb-1">
                {t('resetPasswordPage.newPasswordLabel', 'Nova contrasenya')}
              </label>
              <input
                id="new-password"
                type="password"
                autoComplete="new-password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder={t('resetPasswordPage.newPasswordPlaceholder', 'Mínim 8 caràcters')}
                className="w-full px-4 py-2.5 border border-input rounded-lg focus:ring-2 focus:ring-primary focus:border-transparent outline-none transition bg-background text-foreground"
              />
            </div>

            <div>
              <label htmlFor="confirm-password" className="block text-sm font-medium text-foreground mb-1">
                {t('resetPasswordPage.confirmPasswordLabel', 'Confirmar contrasenya')}
              </label>
              <input
                id="confirm-password"
                type="password"
                autoComplete="new-password"
                value={confirm}
                onChange={(e) => setConfirm(e.target.value)}
                placeholder={t('resetPasswordPage.confirmPasswordPlaceholder', 'Repeteix la contrasenya')}
                className="w-full px-4 py-2.5 border border-input rounded-lg focus:ring-2 focus:ring-primary focus:border-transparent outline-none transition bg-background text-foreground"
              />
            </div>

            {formError && (
              <div role="alert" className="bg-red-50 border border-red-200 text-red-700 px-4 py-3 rounded-lg text-sm dark:bg-red-950/50 dark:border-red-800 dark:text-red-400">
                {formError}
              </div>
            )}

            <button
              type="submit"
              disabled={saving || !password || !confirm}
              className="w-full bg-indigo-600 hover:bg-indigo-700 disabled:opacity-50 text-white font-semibold py-2.5 rounded-lg transition"
            >
              {saving ? t('resetPasswordPage.submitting', 'Desant...') : t('resetPasswordPage.submit', 'Desar contrasenya')}
            </button>
          </form>
        </div>
      </div>
    </div>
  )
}

function LockIcon({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" aria-hidden="true">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z" />
    </svg>
  )
}
