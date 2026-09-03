import { useTranslation } from 'react-i18next'
import { ContentList, PortalModuleUsageCard } from '@/features/tenant-content'

interface Props {
  tenantId: string
  canManage: boolean
}

export function EmployeesPortalContentSection({ tenantId, canManage }: Props) {
  const { t } = useTranslation('tenant-content')

  return (
    <div className="space-y-6">
      <p className="text-sm text-muted-foreground max-w-3xl">
        {t(
          'tenant_content.hub.content_intro',
          'Anuncis i pàgines internes visibles al portal de l\'empleat (secció Notícies). Cal publicar perquè siguin visibles.',
        )}
      </p>
      <PortalModuleUsageCard tenantId={tenantId} channel="employee" />
      <ContentList
        tenantId={tenantId}
        entryContext="employee"
        canManage={canManage}
        newPath="/employee-portal/content/new"
        editPath={(id) => `/employee-portal/content/${id}/edit`}
      />
    </div>
  )
}
