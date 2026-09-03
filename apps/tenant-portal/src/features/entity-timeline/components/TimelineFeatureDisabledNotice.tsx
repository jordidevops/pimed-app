import { useTranslation } from 'react-i18next'

interface TimelineFeatureDisabledNoticeProps {
  titleKey: string
  titleDefault: string
  descriptionKey: string
  descriptionDefault: string
}

export function TimelineFeatureDisabledNotice({
  titleKey,
  titleDefault,
  descriptionKey,
  descriptionDefault,
}: TimelineFeatureDisabledNoticeProps) {
  const { t } = useTranslation('settings')

  return (
    <div className="rounded-2xl border border-amber-200 bg-amber-50 p-6">
      <p className="text-sm font-medium text-amber-900">
        {t(titleKey, titleDefault)}
      </p>
      <p className="mt-1 text-sm text-amber-800">
        {t(descriptionKey, descriptionDefault)}
      </p>
    </div>
  )
}
