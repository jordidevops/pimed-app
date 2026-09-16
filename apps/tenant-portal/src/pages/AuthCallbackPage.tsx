import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { supabase } from '../lib/supabase'
import { Spinner } from '../components/ui/Spinner'
import { translateAuthError } from '../features/auth/utils/translateAuthError'

/**
 * Handles the OAuth callback redirect (PKCE flow).
 * Supabase detects the `code` query param automatically when detectSessionInUrl is true (default).
 * We listen for the SIGNED_IN event and then navigate to the dashboard.
 * If the URL hash contains an error (expired or already-used link), shows an error state.
 */
export function AuthCallbackPage() {
  const { t } = useTranslation('auth')
  const navigate = useNavigate()
  const [errorMsg, setErrorMsg] = useState<string | null>(null)

  useEffect(() => {
    // Supabase puts errors in the URL hash for implicit-flow errors
    // e.g. #error=unauthorized_client&error_description=Email+link+is+invalid+or+has+expired
    const hash = window.location.hash.substring(1)
    const params = new URLSearchParams(hash)
    const hashError = params.get('error_description') ?? params.get('error')
    if (hashError) {
      setErrorMsg(translateAuthError(hashError.replace(/\+/g, ' '), t))
      return
    }

    // Safety timeout — if no auth event fires in 8 s, redirect to login
    const timeout = setTimeout(() => {
      navigate('/login', { replace: true })
    }, 8000)

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((event) => {
      // SIGNED_IN covers normal login + accepted invites (implicit flow).
      // USER_UPDATED fires in some Supabase JS versions when the invite token
      // is exchanged and the user already had a partial record.
      if (event === 'SIGNED_IN' || event === 'USER_UPDATED') {
        clearTimeout(timeout)
        navigate('/dashboard', { replace: true })
      } else if (event === 'SIGNED_OUT') {
        clearTimeout(timeout)
        navigate('/login', { replace: true })
      }
    })

    // Also check if a session already exists (e.g., page reload on /auth/callback)
    supabase.auth.getSession().then(({ data: { session } }) => {
      if (session) {
        clearTimeout(timeout)
        navigate('/dashboard', { replace: true })
      }
    })

    return () => {
      clearTimeout(timeout)
      subscription.unsubscribe()
    }
  }, [navigate, t])

  if (errorMsg) {
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

  return (
    <div className="flex flex-col items-center justify-center min-h-screen bg-background gap-4">
      <Spinner />
      <p className="text-muted-foreground text-sm">Completant l&apos;autenticació...</p>
    </div>
  )
}
