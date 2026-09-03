import { useTranslation } from 'react-i18next'
import { CommentTemplatesManager } from '../../features/entity-timeline/components/CommentTemplatesManager'

export function CommentTemplatesSettingsPage() {
  const { t } = useTranslation(['settings', 'activity'])

  return (
    <div className="space-y-4">
      <div>
        <h3 className="text-base font-semibold text-foreground">
          {t('activity.templates_title', 'Plantilles de comentaris')}
        </h3>
        <p className="text-sm text-muted-foreground mt-0.5">
          {t(
            'activity:templates.manage_description',
            'Crea textos predefinits per agilitzar comentaris i tasques a la timeline.',
          )}
        </p>
      </div>
      <CommentTemplatesManager />
    </div>
  )
}
