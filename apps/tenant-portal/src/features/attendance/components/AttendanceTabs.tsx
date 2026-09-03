import { NavLink } from 'react-router-dom'
import { useTranslation } from 'react-i18next'

export function AttendanceTabs() {
  const { t } = useTranslation('attendance')

  const tabClass = ({ isActive }: { isActive: boolean }) =>
    `px-4 py-2.5 text-sm font-medium border-b-2 transition-colors ${
      isActive
        ? 'border-indigo-600 text-indigo-600'
        : 'border-transparent text-muted-foreground hover:text-foreground hover:border-border'
    }`

  return (
    <div className="flex border-b border-border -mx-4 px-4">
      <NavLink end to="/attendance" className={tabClass}>
        {t('tab_punch', 'Fitxatge')}
      </NavLink>
      <NavLink to="/attendance/record" className={tabClass}>
        {t('tab_record', 'Historial')}
      </NavLink>
    </div>
  )
}
