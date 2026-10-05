import { NavLink, Outlet, useLocation } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Package } from 'lucide-react'
import { PageShell } from '@/components/layout/PageShell'
import { underlineTabClass } from '@/components/layout/UnderlineTabs'
import { ScrollableTabBar } from '@/components/ui/scrollable-tab-bar'

const CATALOG_TABS = [
  { key: 'services', to: '/catalog', end: true, labelKey: 'catalog.tabs.services', fallback: 'Serveis' },
  { key: 'products', to: '/catalog/products', labelKey: 'catalog.tabs.products', fallback: 'Productes' },
  {
    key: 'packs',
    to: '/catalog/packs',
    labelKey: 'catalog.tabs.packs',
    fallback: 'Serveis habituals',
  },
] as const

function useCatalogSection() {
  const { t } = useTranslation('catalog')
  const { pathname } = useLocation()

  if (pathname.startsWith('/catalog/packs')) {
    return {
      title: t('catalog.tabs.packs', 'Serveis habituals'),
      subtitle: t(
        'catalog.packs.subtitle',
        'Packs de línies del catàleg per aplicar ràpidament a una OS',
      ),
    }
  }
  if (pathname.startsWith('/catalog/products')) {
    return {
      title: t('catalog.tabs.products', 'Productes'),
      subtitle: t('catalog.products_subtitle', 'Productes del catàleg comercial'),
    }
  }
  return {
    title: t('catalog.tabs.services', 'Serveis'),
    subtitle: t('catalog.services_subtitle', 'Serveis del catàleg comercial'),
  }
}

export function CatalogLayout() {
  const { t } = useTranslation('catalog')
  const { pathname } = useLocation()
  const section = useCatalogSection()

  const activeKey =
    CATALOG_TABS.find((tab) => {
      const exact = 'end' in tab && tab.end
      return exact
        ? pathname === tab.to
        : pathname === tab.to || pathname.startsWith(`${tab.to}/`)
    })?.key ?? 'services'

  const isPacks = pathname.startsWith('/catalog/packs')

  return (
    <PageShell
      flush={isPacks}
      title={section.title}
      subtitle={section.subtitle}
      icon={<Package className="h-5 w-5" aria-hidden />}
      tabs={
        <ScrollableTabBar
          activeKey={activeKey}
          aria-label={t('catalog.tabs_label', 'Tipus de catàleg')}
          className="border-b border-border"
        >
          {CATALOG_TABS.map((tab) => (
            <NavLink
              key={tab.key}
              to={tab.to}
              end={'end' in tab && Boolean(tab.end)}
              data-tab-key={tab.key}
              className={({ isActive }) => underlineTabClass(isActive)}
            >
              {t(tab.labelKey, tab.fallback)}
            </NavLink>
          ))}
        </ScrollableTabBar>
      }
    >
      <Outlet />
    </PageShell>
  )
}
