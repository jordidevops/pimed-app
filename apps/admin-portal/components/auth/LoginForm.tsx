'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslation } from 'react-i18next'
import { createSupabaseClient } from '@/lib/supabase/client'

export function LoginForm() {
  const { t } = useTranslation('auth')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const router = useRouter()
  const supabase = createSupabaseClient()

  const handleEmailLogin = async (e: React.FormEvent) => {
    e.preventDefault()
    setLoading(true)
    setError(null)

    const { error } = await supabase.auth.signInWithPassword({ email, password })
    if (error) {
      setError(error.message)
    } else {
      router.push('/dashboard')
      router.refresh() // Revalidate Server Components with the new session
    }
    setLoading(false)
  }

  // Show error from OAuth callback (e.g., ?error=auth_callback_error in URL)
  const urlError =
    typeof window !== 'undefined'
      ? new URLSearchParams(window.location.search).get('error')
      : null

  return (
    <div className="bg-white rounded-2xl shadow-2xl p-8">
      {urlError && (
        <div className="mb-5 bg-red-50 border border-red-200 text-red-700 px-4 py-3 rounded-lg text-sm">
          {t('auth.form.error_oauth', "Error d'autenticació. Torna-ho a intentar.")}
        </div>
      )}

      <form onSubmit={handleEmailLogin} className="space-y-5">
        <div>
          <label htmlFor="email" className="block text-sm font-medium text-gray-700 mb-1">
            {t('auth.form.email_label', 'Email')}
          </label>
          <input
            id="email"
            type="email"
            required
            autoComplete="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className="w-full px-4 py-2.5 border border-gray-300 rounded-lg focus:ring-2 focus:ring-indigo-500 focus:border-transparent outline-none transition"
            placeholder={t('auth.form.email_placeholder', 'admin@example.com')}
          />
        </div>

        <div>
          <label htmlFor="password" className="block text-sm font-medium text-gray-700 mb-1">
            {t('auth.form.password_label', 'Contrasenya')}
          </label>
          <input
            id="password"
            type="password"
            required
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className="w-full px-4 py-2.5 border border-gray-300 rounded-lg focus:ring-2 focus:ring-indigo-500 focus:border-transparent outline-none transition"
            placeholder={t('auth.form.password_placeholder', '••••••••')}
          />
        </div>

        {error && (
          <div className="bg-red-50 border border-red-200 text-red-700 px-4 py-3 rounded-lg text-sm">
            {error}
          </div>
        )}

        <button
          type="submit"
          disabled={loading}
          className="w-full bg-indigo-600 hover:bg-indigo-700 disabled:opacity-50 text-white font-semibold py-2.5 rounded-lg transition"
        >
          {loading
            ? t('auth.form.submitting', 'Accedint...')
            : t('auth.form.submit', 'Iniciar sessió')}
        </button>
      </form>
    </div>
  )
}
