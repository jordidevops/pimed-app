import Link from 'next/link'
import Image from 'next/image'
import type { ThemeConfig } from '@/lib/theme'
import type { PublicPage, PublicSite } from '@/lib/portal'
import { LanguageSwitcher } from './LanguageSwitcher'
import type { SupportedLocale } from '@/lib/locales'

interface Props {
  site: PublicSite
  pages: PublicPage[]
  locale: SupportedLocale
  currentPageSlug?: string
  theme: ThemeConfig
  availableLocales: SupportedLocale[]
  localeHrefMap: Partial<Record<SupportedLocale, string>>
  slugBase: string
}

/**
 * Capçalera del portal públic.
 * - Logo del branding (si n'hi ha)
 * - Navegació amb les pàgines que tenen show_in_nav=true
 * - Selector d'idioma
 * - Botó de contacte (opcional)
 */
export function PortalHeader({
  site,
  pages,
  locale,
  currentPageSlug,
  theme,
  availableLocales,
  localeHrefMap,
  slugBase,
}: Props) {
  const { header = {}, branding = {}, colors = {} } = theme

  const showNav = header.show_nav !== false
  const showLangSwitcher = header.show_language_switcher !== false
  const showContactBtn = header.show_contact_button === true

  const navPages = showNav
    ? pages
        .filter((p) => p.show_in_nav && p.status === 'published')
        .sort((a, b) => (a.sort_order ?? 0) - (b.sort_order ?? 0))
    : []

  const primaryColor = colors.primary

  return (
    <header
      className="w-full border-b bg-white"
      style={primaryColor ? { borderBottomColor: primaryColor } : undefined}
    >
      <div className="mx-auto max-w-5xl px-4 py-3 flex items-center gap-4">
        {/* Logo / nom */}
        <Link href={`${slugBase}/${locale}`} className="flex items-center gap-2 shrink-0">
          {branding.logo_url ? (
            <Image
              src={branding.logo_url}
              alt={branding.logo_alt ?? site.name ?? 'Logo'}
              width={120}
              height={40}
              className="h-8 w-auto object-contain"
            />
          ) : (
            <span
              className="text-lg font-semibold"
              style={primaryColor ? { color: primaryColor } : undefined}
            >
              {site.name}
            </span>
          )}
        </Link>

        {/* Navegació */}
        <nav className="flex items-center gap-1 flex-1">
          {navPages.map((page) => {
            const isActive = page.slug === currentPageSlug
            return (
              <Link
                key={page.id}
                href={
                  page.slug === 'home'
                    ? `${slugBase}/${locale}`
                    : `${slugBase}/${locale}/${page.slug}`
                }
                aria-current={isActive ? 'page' : undefined}
                className={[
                  'px-3 py-1.5 rounded text-sm transition-colors',
                  isActive
                    ? 'font-semibold text-foreground'
                    : 'text-muted-foreground hover:text-foreground hover:bg-muted',
                ].join(' ')}
                style={isActive && primaryColor ? { color: primaryColor } : undefined}
              >
                {page.title}
              </Link>
            )
          })}
          <Link
            href={`${slugBase}/${locale}/careers`}
            aria-current={currentPageSlug === 'careers' ? 'page' : undefined}
            className={[
              'px-3 py-1.5 rounded text-sm transition-colors',
              currentPageSlug === 'careers'
                ? 'font-semibold text-foreground'
                : 'text-muted-foreground hover:text-foreground hover:bg-muted',
            ].join(' ')}
            style={
              currentPageSlug === 'careers' && primaryColor ? { color: primaryColor } : undefined
            }
          >
            Ofertes
          </Link>
        </nav>

        <div className="flex items-center gap-2 ml-auto">
          {/* Selector d'idioma */}
          {showLangSwitcher && (
            <LanguageSwitcher
              availableLocales={availableLocales}
              currentLocale={locale}
              localeHrefMap={localeHrefMap}
            />
          )}

          {/* Botó de contacte */}
          {showContactBtn && header.contact_button_url && (
            <Link
              href={header.contact_button_url}
              className="px-4 py-1.5 rounded text-sm font-medium text-white transition-opacity hover:opacity-90"
              style={{ backgroundColor: primaryColor ?? '#2563eb' }}
            >
              {header.contact_button_label ?? 'Contacta\'ns'}
            </Link>
          )}
        </div>
      </div>
    </header>
  )
}
