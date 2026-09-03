import { NavLink } from 'react-router-dom'
import { useTranslation } from 'react-i18next'

const pillClass = ({ isActive }: { isActive: boolean }) =>
  `rounded-full px-3.5 py-1 text-sm font-medium transition-colors ${
    isActive
      ? 'bg-primary text-primary-foreground'
      : 'text-muted-foreground hover:text-foreground hover:bg-accent'
  }`

export function DocumentsSubNav() {
  const { t } = useTranslation('documents')

  return (
    <div className="flex gap-1.5 border-b pb-3">
      <NavLink end to="/documents" className={pillClass}>
        {t('subnav.documents', 'Documents')}
      </NavLink>
      <NavLink to="/documents/signing" className={pillClass}>
        {t('subnav.signing', 'Signatures')}
      </NavLink>
      <NavLink to="/documents/templates" className={pillClass}>
        {t('subnav.templates', 'Plantilles')}
      </NavLink>
      <NavLink to="/documents/archived" className={pillClass}>
        {t('subnav.archived', 'Arxivats')}
      </NavLink>
      <NavLink to="/documents/storage" className={pillClass}>
        {t('subnav.storage', 'Emmagatzematge')}
      </NavLink>
    </div>
  )
}
