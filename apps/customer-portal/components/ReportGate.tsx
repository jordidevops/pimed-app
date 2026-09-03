'use client'

import Link from 'next/link'
import { useTranslation } from 'react-i18next'

export function ReportGate({
  variant,
}: {
  variant: 'need_session' | 'unavailable' | 'unavailable_or_expired'
}) {
  const { t } = useTranslation('common')

  return (
    <main className="mx-auto max-w-2xl px-4 py-16">
      <h1 className="text-2xl font-semibold tracking-tight">
        {t('report.title', 'Butlletí')}
      </h1>
      <p className="mt-3 text-[var(--muted)]">
        {variant === 'need_session'
          ? t(
              'report.need_session',
              'Cal una sessió de client per veure aquest butlletí.',
            )
          : variant === 'unavailable'
            ? t('report.unavailable', 'Aquest butlletí no és disponible.')
            : t(
                'report.unavailable_or_expired',
                'Aquest butlletí no és disponible o la sessió ha caducat.',
              )}
      </p>
      <p className="mt-6 flex gap-4">
        {variant === 'need_session' ? (
          <Link
            href="/login"
            className="sans text-[var(--accent)] underline-offset-2 hover:underline"
          >
            {t('nav.login_with_email', 'Accedir amb el correu')}
          </Link>
        ) : (
          <>
            <Link
              href="/dashboard"
              className="sans text-[var(--accent)] underline-offset-2 hover:underline"
            >
              {t('nav.back_to_list', 'Tornar al llistat')}
            </Link>
            {variant === 'unavailable_or_expired' && (
              <a
                href="/api/logout"
                className="sans text-[var(--muted)] underline-offset-2 hover:underline"
              >
                {t('nav.logout', 'Tancar sessió')}
              </a>
            )}
          </>
        )}
      </p>
    </main>
  )
}

export function BackToListLink({ href = '/dashboard' }: { href?: string }) {
  const { t } = useTranslation('common')
  return (
    <div className="no-print mx-auto max-w-2xl px-4 pt-6">
      <Link
        href={href}
        className="sans text-sm text-[var(--muted)] underline-offset-2 hover:underline"
      >
        {t('nav.back_to_list_arrow', '← Tornar al llistat')}
      </Link>
    </div>
  )
}
