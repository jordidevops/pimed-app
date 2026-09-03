'use client'

import { useTranslation } from 'react-i18next'

export function HomeContent({ errorParam }: { errorParam?: string }) {
  const { t } = useTranslation('common')

  return (
    <main className="mx-auto max-w-2xl px-4 py-16">
      <h1 className="text-2xl font-semibold tracking-tight">
        {t('portal_title', 'Portal del client')}
      </h1>
      <p className="mt-3 text-[var(--muted)]">
        {errorParam === 'invalid'
          ? t(
              'home.invalid_link',
              "Aquest enllaç no és vàlid, ha caducat o s'ha revocat.",
            )
          : t(
              'home.open_link',
              "Obre l'enllaç que t'han enviat per entrar al portal.",
            )}
      </p>
      <p className="sans mt-6 text-sm text-[var(--muted)]">
        {t('home.account_access', 'Accés amb compte?')}{' '}
        <a
          href="/login"
          className="text-[var(--accent)] underline-offset-2 hover:underline"
        >
          {t('home.enter_here', 'Entra aquí')}
        </a>
      </p>
    </main>
  )
}
