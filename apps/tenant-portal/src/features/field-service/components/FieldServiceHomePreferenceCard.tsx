import { useTranslation } from 'react-i18next'
import { useMemberSettingsMutation } from '@/hooks/useSettings'
import {
  FIELD_SERVICE_HOME_SETTING_KEY,
  type FieldServiceHomePreference,
} from '../utils/resolveFieldServiceHome'

export function FieldServiceHomePreferenceCard({
  preference,
  disabled,
  embedded = false,
}: {
  preference: FieldServiceHomePreference
  disabled?: boolean
  embedded?: boolean
}) {
  const { t } = useTranslation('field-service')
  const memberSettingsMut = useMemberSettingsMutation()

  return (
    <div className={embedded ? 'space-y-3 text-sm' : 'space-y-3 rounded-2xl border border-border bg-card p-4 text-sm'}>
      <p className="font-medium">
        {t('more.home_pref_title', 'Pantalla d\'inici')}
      </p>
      <label className="flex flex-col gap-1">
        <span className="text-xs text-muted-foreground">
          {t(
            'more.home_pref_help',
            'En entrar a l\'app: mòbil obre Avui i l\'escriptori obre Inici, si no tries una altra opció.',
          )}
        </span>
        <select
          className="rounded-md border border-input bg-background px-3 py-2"
          value={preference}
          disabled={disabled || memberSettingsMut.isPending}
          onChange={(e) => {
            const next = e.target.value as FieldServiceHomePreference
            void memberSettingsMut.mutateAsync({
              [FIELD_SERVICE_HOME_SETTING_KEY]: next,
            })
          }}
        >
          <option value="auto">
            {t('more.home_pref_auto', 'Automàtica (mòbil Avui, escriptori Inici)')}
          </option>
          <option value="field_today">
            {t('more.home_pref_today', 'Sempre Avui')}
          </option>
          <option value="dashboard">
            {t('more.home_pref_dashboard', 'Sempre Inici')}
          </option>
        </select>
      </label>
    </div>
  )
}
