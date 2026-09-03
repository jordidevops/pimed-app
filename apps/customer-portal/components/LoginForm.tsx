'use client'

import { useTranslation } from 'react-i18next'

type Props = {
  showSent: boolean
  showInvalid: boolean
  action: (formData: FormData) => Promise<void>
}

export function LoginForm({ showSent, showInvalid, action }: Props) {
  const { t } = useTranslation('common')

  return (
    <main className="mx-auto max-w-md px-4 py-16 sm:py-20">
      <p className="sans text-xs uppercase tracking-[0.18em] text-[var(--muted)]">
        {t('portal_title', 'Portal del client')}
      </p>
      <h1 className="mt-2 text-3xl font-semibold tracking-tight">
        {t('login.title', 'Accedir')}
      </h1>
      <p className="mt-3 text-[var(--muted)]">
        {t(
          'login.subtitle',
          "Introdueix el correu amb què et van convidar. T'enviarem un enllaç d'accés temporal.",
        )}
      </p>

      {showInvalid && (
        <p className="sans mt-6 text-sm text-[var(--staff)]">
          {t(
            'login.invalid_link',
            "Aquest enllaç no és vàlid, ha caducat o s'ha revocat. Demana'n un de nou.",
          )}
        </p>
      )}

      {showSent ? (
        <p className="mt-8 rounded-xl border border-[var(--line)] bg-white/60 px-4 py-4 text-[var(--ink)]">
          {t(
            'login.sent',
            "Si tenim el teu correu registrat, t'enviarem un enllaç d'accés en uns moments. Revisa la safata d'entrada i el correu no desitjat.",
          )}
        </p>
      ) : (
        <form action={action} className="mt-8 space-y-4">
          <label className="block">
            <span className="sans text-sm font-medium text-[var(--muted)]">
              {t('login.email_label', 'Correu electrònic')}
            </span>
            <input
              type="email"
              name="email"
              required
              autoComplete="email"
              className="sans mt-1.5 w-full rounded-lg border border-[var(--line)] bg-white/80 px-3 py-2.5 text-[var(--ink)] outline-none focus:border-[var(--accent)]"
              placeholder={t('login.email_placeholder', 'nom@exemple.com')}
            />
          </label>
          <button
            type="submit"
            className="sans w-full rounded-lg bg-[var(--accent)] px-4 py-2.5 text-sm font-medium text-white hover:opacity-95"
          >
            {t('login.submit', 'Enviar enllaç')}
          </button>
        </form>
      )}
    </main>
  )
}
