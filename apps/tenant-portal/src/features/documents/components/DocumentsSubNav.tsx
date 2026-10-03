import { NavLink, useLocation } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { ScrollableTabBar } from '@/components/ui/scrollable-tab-bar'
import { underlineTabClass } from '@/components/layout/UnderlineTabs'

const DOC_TABS = [
  { key: 'documents', to: '/documents', end: true, labelKey: 'subnav.documents', fallback: 'Documents' },
  { key: 'signing', to: '/documents/signing', labelKey: 'subnav.signing', fallback: 'Signatures' },
  { key: 'templates', to: '/documents/templates', labelKey: 'subnav.templates', fallback: 'Plantilles' },
  { key: 'archived', to: '/documents/archived', labelKey: 'subnav.archived', fallback: 'Arxivats' },
  { key: 'storage', to: '/documents/storage', labelKey: 'subnav.storage', fallback: 'Emmagatzematge' },
] as const

export function DocumentsSubNav() {
  const { t } = useTranslation('documents')
  const { pathname } = useLocation()
  const activeKey =
    DOC_TABS.find((tab) =>
      tab.end
        ? pathname === tab.to
        : pathname === tab.to || pathname.startsWith(`${tab.to}/`),
    )?.key ?? 'documents'

  return (
    <ScrollableTabBar
      activeKey={activeKey}
      aria-label={t('subnav.label', 'Seccions de documents')}
      className="border-b border-border"
    >
      {DOC_TABS.map((tab) => (
        <NavLink
          key={tab.key}
          to={tab.to}
          end={'end' in tab ? Boolean(tab.end) : false}
          data-tab-key={tab.key}
          className={({ isActive }) => underlineTabClass(isActive)}
        >
          {t(tab.labelKey, tab.fallback)}
        </NavLink>
      ))}
    </ScrollableTabBar>
  )
}
