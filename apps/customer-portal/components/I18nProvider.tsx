'use client'

import { useEffect } from 'react'
import { I18nextProvider } from 'react-i18next'
import i18n from '@/lib/i18n'
import {
  isPlatformLocale,
  PLATFORM_FALLBACK_LOCALE,
  type PlatformLocale,
} from '@/lib/locale'

type Props = {
  children: React.ReactNode
  uiLocale?: string
}

export function I18nProvider({ children, uiLocale }: Props) {
  const lng: PlatformLocale = isPlatformLocale(uiLocale ?? '')
    ? (uiLocale as PlatformLocale)
    : PLATFORM_FALLBACK_LOCALE

  useEffect(() => {
    if (typeof document !== 'undefined') {
      document.documentElement.lang = lng
    }
    if (i18n.resolvedLanguage !== lng) {
      void i18n.changeLanguage(lng)
    }
  }, [lng])

  return (
    <I18nextProvider i18n={i18n}>
      <div lang={lng}>{children}</div>
    </I18nextProvider>
  )
}
