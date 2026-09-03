import { useTranslation } from 'react-i18next'
import { Lock } from 'lucide-react'

interface Props {
  channel: 'employee' | 'public'
}

export function ModuleNotEnabledScreen({ channel }: Props) {
  const { t } = useTranslation('tenant-content')

  return (
    <div className="flex flex-col items-center justify-center min-h-[50vh] text-center px-4">
      <div className="h-16 w-16 rounded-2xl bg-muted flex items-center justify-center mb-4">
        <Lock className="h-8 w-8 text-muted-foreground" />
      </div>
      <h2 className="text-xl font-bold text-foreground mb-2">
        {channel === 'employee'
          ? t('tenant_content.not_enabled.employee_title', 'Portal d\'empleats no activat')
          : t('tenant_content.not_enabled.public_title', 'Web pública no activada')}
      </h2>
      <p className="text-sm text-muted-foreground max-w-md">
        {t(
          'tenant_content.not_enabled.description',
          "Contacta amb l'administrador de la plataforma per activar aquest mòdul.",
        )}
      </p>
    </div>
  )
}
