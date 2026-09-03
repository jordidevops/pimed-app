'use client'

import Link from 'next/link'
import { useTranslation } from 'react-i18next'

/** Peu legal del portal empleat (Art. 13 + condicions + cookies + dades personals). */
export function EmployeePortalFooter() {
  const { t } = useTranslation('portal')

  const links = [
    {
      href: '/portal/legal/privacy_employees',
      label: t('employee_portal.footer.privacy', 'Privacitat'),
    },
    {
      href: '/portal/legal/employee_portal_terms',
      label: t('employee_portal.footer.terms', 'Condicions'),
    },
    {
      href: '/portal/legal/cookie_notice',
      label: t('employee_portal.footer.cookies', 'Cookies'),
    },
    {
      href: '/portal/personal-data',
      label: t('employee_portal.footer.personal_data', 'Les meves dades'),
    },
  ]

  return (
    <footer className="mt-10 border-t pt-6 pb-8">
      <nav
        className="flex flex-wrap gap-x-4 gap-y-2 text-sm text-muted-foreground"
        aria-label={t('employee_portal.footer.aria', 'Enllaços legals')}
      >
        {links.map((l) => (
          <Link
            key={l.href}
            href={l.href}
            className="underline-offset-2 hover:text-foreground hover:underline"
          >
            {l.label}
          </Link>
        ))}
      </nav>
      <p className="mt-3 text-xs text-muted-foreground">
        {t(
          'employee_portal.footer.note',
          'El responsable del tractament és la vostra organització. La plataforma actua com a encarregat.',
        )}
      </p>
    </footer>
  )
}
