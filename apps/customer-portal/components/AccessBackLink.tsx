'use client'

import Link from 'next/link'
import { useTranslation } from 'react-i18next'

export function AccessBackLink({ actor }: { actor: 'staff' | 'grant' }) {
  const { t } = useTranslation('common')
  const href = actor === 'staff' ? '/r' : '/dashboard'
  const label =
    actor === 'staff'
      ? t('nav.back_to_list_arrow', '← Tornar al llistat')
      : t('nav.back_to_dashboard', '← Dashboard')

  return (
    <p className="sans mb-6">
      <Link
        href={href}
        className="text-sm text-[var(--muted)] underline-offset-2 hover:underline"
      >
        {label}
      </Link>
    </p>
  )
}
