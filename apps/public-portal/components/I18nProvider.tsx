'use client'

import { useEffect } from 'react'
import '@/lib/i18n'
import { I18nextProvider } from 'react-i18next'
import i18n from '@/lib/i18n'
import { isValidLocale, PLATFORM_FALLBACK_LOCALE, type SupportedLocale } from '@/lib/locales'

interface Props {
  children: React.ReactNode
  locale?: string
}

export function I18nProvider({ children, locale }: Props) {
  const resolvedLocale: SupportedLocale = isValidLocale(locale ?? '')
    ? (locale as SupportedLocale)
    : PLATFORM_FALLBACK_LOCALE

  useEffect(() => {
    if (i18n.resolvedLanguage !== resolvedLocale) {
      void i18n.changeLanguage(resolvedLocale)
    }
  }, [resolvedLocale])

  return <I18nextProvider i18n={i18n}>{children}</I18nextProvider>
}
