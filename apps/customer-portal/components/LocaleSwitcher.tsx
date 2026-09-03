'use client'

import { useState, useTransition } from 'react'
import { useTranslation } from 'react-i18next'
import {
  PLATFORM_LOCALES,
  type PlatformLocale,
  isPlatformLocale,
} from '@/lib/locale'

type Props = {
  currentLocale: string
  supportedLocales: string[]
  accountContactId: string
  tenantId: string
}

export function LocaleSwitcher({
  currentLocale,
  supportedLocales,
  accountContactId,
  tenantId,
}: Props) {
  const { t, i18n } = useTranslation('common')
  const [error, setError] = useState<string | null>(null)
  const [pending, startTransition] = useTransition()
  const [selected, setSelected] = useState<PlatformLocale>(
    isPlatformLocale(currentLocale) ? currentLocale : 'es',
  )

  const options = (
    supportedLocales.length > 0 ? supportedLocales : [...PLATFORM_LOCALES]
  ).filter((l): l is PlatformLocale => isPlatformLocale(l))

  if (options.length < 2) return null

  function onChange(next: string) {
    if (!isPlatformLocale(next) || next === selected) return
    const prev = selected
    setSelected(next)
    setError(null)
    startTransition(async () => {
      try {
        const res = await fetch('/api/locale', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            locale: next,
            account_contact_id: accountContactId,
            tenant_id: tenantId,
          }),
        })
        if (!res.ok) {
          setSelected(prev)
          setError(t('locale.error', "No s'ha pogut canviar l'idioma."))
          return
        }
        await i18n.changeLanguage(next)
        if (typeof document !== 'undefined') {
          document.documentElement.lang = next
        }
      } catch {
        setSelected(prev)
        setError(t('locale.error', "No s'ha pogut canviar l'idioma."))
      }
    })
  }

  return (
    <div className="no-print sans flex flex-col items-end gap-1">
      <label className="flex items-center gap-2 text-sm text-[var(--muted)]">
        <span className="sr-only">{t('locale.label', 'Idioma')}</span>
        <select
          className="rounded-md border border-[var(--line)] bg-white/80 px-2 py-1 text-[var(--ink)]"
          value={selected}
          disabled={pending}
          onChange={(e) => onChange(e.target.value)}
          aria-label={t('locale.label', 'Idioma')}
        >
          {options.map((loc) => (
            <option key={loc} value={loc}>
              {t(`locale.${loc}`, loc)}
            </option>
          ))}
        </select>
      </label>
      {pending && (
        <span className="text-xs text-[var(--muted)]">
          {t('locale.saving', 'Desant…')}
        </span>
      )}
      {error && <span className="text-xs text-[var(--staff)]">{error}</span>}
    </div>
  )
}
