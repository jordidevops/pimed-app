import { useTranslation } from 'react-i18next'
import { Users, Lock } from 'lucide-react'

/**
 * Pantalla quan el portal empleat no està efectiu (pla o toggle admin).
 */
export function EmployeePortalActivation() {
  const { t } = useTranslation('employees')

  return (
    <div className="flex flex-col items-center justify-center min-h-[40vh] text-center px-4 py-10">
      <div className="relative mb-6">
        <div className="h-20 w-20 rounded-2xl bg-muted flex items-center justify-center">
          <Users className="h-10 w-10 text-muted-foreground" />
        </div>
        <div className="absolute -bottom-1 -right-1 h-7 w-7 rounded-full bg-amber-100 border-2 border-background flex items-center justify-center">
          <Lock className="h-3.5 w-3.5 text-amber-600" />
        </div>
      </div>

      <span className="inline-flex items-center rounded-full bg-amber-100 text-amber-700 text-xs font-semibold px-3 py-1 mb-4">
        {t('portal.not_enabled.badge', 'No disponible')}
      </span>

      <h2 className="text-xl font-bold text-foreground mb-2">
        {t('portal.not_enabled.title', 'Portal d\'empleats no activat')}
      </h2>
      <p className="text-sm text-muted-foreground max-w-sm">
        {t(
          'portal.not_enabled.description',
          "El mòdul de portal d'empleats no està activat per a aquesta organització. Contacta amb l'administrador de la plataforma.",
        )}
      </p>
    </div>
  )
}
