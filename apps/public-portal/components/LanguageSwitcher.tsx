'use client'

import Link from 'next/link'
import type { SupportedLocale } from '@/lib/locales'

interface Props {
  /** Llista de locales disponibles per al site. */
  availableLocales: SupportedLocale[]
  /** Locale actiu. */
  currentLocale: SupportedLocale
  /**
   * Mapa locale -> URL de destí.
   * Ex: { ca: '/acme/ca', es: '/acme/es' }
   */
  localeHrefMap: Partial<Record<SupportedLocale, string>>
}

const LOCALE_LABELS: Record<SupportedLocale, string> = {
  ca: 'CA',
  es: 'ES',
  en: 'EN',
}

/**
 * Selector d'idioma basat en navegació per URL (Link), NO en i18n.changeLanguage().
 * Permet que cada pàgina localitzada tingui la seva pròpia URL (SEO, compartir, etc.).
 */
export function LanguageSwitcher({ availableLocales, currentLocale, localeHrefMap }: Props) {
  if (availableLocales.length <= 1) return null

  return (
    <nav aria-label="Canvi d'idioma" className="flex items-center gap-1">
      {availableLocales.map((locale) => {
        const href = localeHrefMap[locale]
        if (!href) return null

        return (
          <Link
            key={locale}
            href={href}
            aria-current={locale === currentLocale ? 'true' : undefined}
            className={[
              'px-2 py-1 rounded text-xs font-medium transition-colors',
              locale === currentLocale
                ? 'bg-primary text-primary-foreground'
                : 'text-muted-foreground hover:text-foreground hover:bg-muted',
            ].join(' ')}
          >
            {LOCALE_LABELS[locale]}
          </Link>
        )
      })}
    </nav>
  )
}
