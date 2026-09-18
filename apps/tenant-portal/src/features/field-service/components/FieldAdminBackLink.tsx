import { Link, useLocation } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { ArrowLeft } from 'lucide-react'
import { fieldAdminBackTo, isFieldSettingsPath } from '../utils/fieldAdminPaths'

export function FieldAdminBackLink() {
  const { t } = useTranslation('field-service')
  const { pathname } = useLocation()
  const inSettings = isFieldSettingsPath(pathname)

  return (
    <Link
      to={fieldAdminBackTo(pathname)}
      className={
        inSettings
          ? 'mb-2 inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground lg:hidden'
          : 'mb-2 inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground'
      }
    >
      <ArrowLeft className="h-4 w-4" />
      {inSettings
        ? t('more.settings', 'Configuració')
        : t('more.title', 'Més')}
    </Link>
  )
}
