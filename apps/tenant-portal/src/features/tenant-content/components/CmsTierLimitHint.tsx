import { Info } from 'lucide-react'
import { useTranslation } from 'react-i18next'

interface Props {
  channel: 'employee' | 'public'
  tier: string
}

export function CmsTierLimitHint({ channel, tier }: Props) {
  const { t } = useTranslation('tenant-content')

  if (tier === 'advanced' || tier === 'none') return null

  const bodyKey =
    channel === 'employee'
      ? 'tenant_content.tier_hint.employee_body'
      : 'tenant_content.tier_hint.public_body'

  return (
    <div
      className="flex gap-2 rounded-lg border border-amber-200/80 bg-amber-50/80 dark:bg-amber-950/30 dark:border-amber-800/50 px-3 py-2.5 text-sm text-amber-950 dark:text-amber-100"
      role="note"
    >
      <Info className="h-4 w-4 shrink-0 mt-0.5 text-amber-700 dark:text-amber-400" aria-hidden />
      <div className="space-y-1">
        <p className="font-medium">
          {t('tenant_content.tier_hint.title', 'Pla {{tier}} — funcions limitades', { tier })}
        </p>
        <p className="text-xs text-amber-900/90 dark:text-amber-100/90 leading-relaxed">
          {t(
            bodyKey,
            channel === 'employee'
              ? 'Amb el pla basic pots publicar per a tota l\'organització. La segmentació per local o departament, els destacats i la programació requereixen pla advanced.'
              : 'Amb el pla basic pots crear pàgines web. Les traduccions i el formulari de contacte requereixen pla advanced.',
          )}
        </p>
      </div>
    </div>
  )
}
