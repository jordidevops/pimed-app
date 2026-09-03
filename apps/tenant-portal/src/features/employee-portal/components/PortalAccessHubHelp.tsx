import { useTranslation } from 'react-i18next'
import { CircleHelp } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover'
import { ATTENDANCE_STATIONS_PLAN_URL } from '../constants/portalAccessDocs'

export function PortalAccessHubHelp() {
  const { t } = useTranslation('employees')

  return (
    <Popover>
      <PopoverTrigger asChild>
        <Button variant="ghost" size="sm" className="gap-2">
          <CircleHelp className="h-4 w-4" />
          {t('employees.portal_hub.help_button', 'Ajuda')}
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-80 space-y-2 text-sm" align="end">
        <p className="font-medium">
          {t('employees.portal_hub.help_title', 'Accés al portal')}
        </p>
        <ul className="list-disc pl-5 space-y-1 text-muted-foreground">
          <li>
            {t(
              'employees.portal_hub.help_personal',
              'Personal: enllaç individual per mòbil; es pot exigir PIN i verificació de DNI al primer accés.',
            )}
          </li>
          <li>
            {t(
              'employees.portal_hub.help_pin',
              'PIN pendent = l\'empleat encara no l\'ha configurat al portal.',
            )}
          </li>
          <li>
            {t(
              'employees.portal_hub.help_bulk',
              'Selecciona files amb DNI per generar accés massiu i exportar CSV o QR.',
            )}
          </li>
        </ul>
        <a
          href={ATTENDANCE_STATIONS_PLAN_URL}
          target="_blank"
          rel="noopener noreferrer"
          className="inline-block text-primary hover:underline text-xs"
        >
          {t(
            'employees.portal_access.stations_plan_link_label',
            'Pla d\'estacions de fitxatge',
          )}
        </a>
      </PopoverContent>
    </Popover>
  )
}
