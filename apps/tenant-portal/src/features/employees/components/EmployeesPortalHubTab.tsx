import { useSearchParams } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useTenant } from '@/contexts/TenantContext'
import { useCanManageTenantContent } from '@/features/tenant-content/api/useCanManageTenantContent'
import { ScrollableTabBar } from '@/components/ui/scrollable-tab-bar'
import { EmployeesPortalAccessTab } from './EmployeesPortalAccessTab'
import { EmployeesPortalContentSection } from './EmployeesPortalContentSection'

type HubSection = 'access' | 'content'

interface Props {
  onSubtitleChange?: (count: number) => void
}

export function EmployeesPortalHubTab({ onSubtitleChange }: Props) {
  const { t } = useTranslation('employees')
  const { activeTenant } = useTenant()
  const [searchParams, setSearchParams] = useSearchParams()
  const canManageContent = useCanManageTenantContent()

  const section: HubSection =
    searchParams.get('section') === 'content' ? 'content' : 'access'

  function selectSection(next: HubSection) {
    const params = new URLSearchParams(searchParams)
    params.set('tab', 'portal_hub')
    if (next === 'content') params.set('section', 'content')
    else params.delete('section')
    setSearchParams(params, { replace: true })
  }

  if (!activeTenant) return null

  return (
    <div className="space-y-4">
      <ScrollableTabBar
        activeKey={section}
        aria-label={t('employees.portal_hub.sections_label', 'Seccions del portal')}
        className="border-b mb-4"
      >
        <button
          type="button"
          role="tab"
          data-tab-key="access"
          aria-selected={section === 'access'}
          onClick={() => selectSection('access')}
          className={`px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors whitespace-nowrap ${
            section === 'access'
              ? 'border-primary text-primary'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          {t('employees.portal_hub.sections.access', 'Accés')}
        </button>
        <button
          type="button"
          role="tab"
          data-tab-key="content"
          aria-selected={section === 'content'}
          onClick={() => selectSection('content')}
          className={`px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors whitespace-nowrap ${
            section === 'content'
              ? 'border-primary text-primary'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          {t('employees.portal_hub.sections.content', 'Contingut')}
        </button>
      </ScrollableTabBar>

      {section === 'access' ? (
        <EmployeesPortalAccessTab onSubtitleChange={onSubtitleChange} />
      ) : (
        <EmployeesPortalContentSection tenantId={activeTenant.id} canManage={canManageContent} />
      )}
    </div>
  )
}
