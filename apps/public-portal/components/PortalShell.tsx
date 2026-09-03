import type { ReactNode } from 'react'
import { parseThemeConfig } from '@/lib/theme'
import { PortalHeader } from './PortalHeader'
import { PortalFooter } from './PortalFooter'
import { CookieNotice } from './CookieNotice'
import type { PublicPage, PublicSite } from '@/lib/portal'
import type { SupportedLocale } from '@/lib/locales'

interface Props {
  site: PublicSite
  pages: PublicPage[]
  locale: SupportedLocale
  currentPageSlug?: string
  availableLocales: SupportedLocale[]
  localeHrefMap: Partial<Record<SupportedLocale, string>>
  /** Base URL per construir els hrefs de nav. Ex: '/acme-corp' o '' (domini propi) */
  slugBase: string
  children: ReactNode
}

/**
 * Shell del portal públic: Header + contingut + Footer.
 * Aplica el color primari com a CSS custom property (`--color-primary`).
 */
export function PortalShell({
  site,
  pages,
  locale,
  currentPageSlug,
  availableLocales,
  localeHrefMap,
  slugBase,
  children,
}: Props) {
  const theme = parseThemeConfig(site.theme_config)
  const primaryColor = theme.colors?.primary

  return (
    <div
      className="min-h-screen flex flex-col"
      style={primaryColor ? { ['--color-primary' as string]: primaryColor } : undefined}
    >
      <PortalHeader
        site={site}
        pages={pages}
        locale={locale}
        currentPageSlug={currentPageSlug}
        theme={theme}
        availableLocales={availableLocales}
        localeHrefMap={localeHrefMap}
        slugBase={slugBase}
      />
      <main className="flex-1">{children}</main>
      <PortalFooter
        pages={pages}
        locale={locale}
        theme={theme}
        slugBase={slugBase}
        siteName={site.name}
      />
      <CookieNotice slugBase={slugBase || ''} locale={locale} />
    </div>
  )
}
