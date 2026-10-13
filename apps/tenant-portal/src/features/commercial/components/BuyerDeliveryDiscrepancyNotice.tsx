import { useTranslation } from 'react-i18next'
import type { BuyerDeliveryDiscrepancy } from '../utils/buyerDeliveryDiscrepancy'

const FIELD_I18N: Record<BuyerDeliveryDiscrepancy['field'], { key: string; fallback: string }> = {
  phone: { key: 'projects.commercial.delivery_field_phone', fallback: 'Telèfon' },
  email: { key: 'projects.commercial.delivery_field_email', fallback: 'Correu' },
  display_name: { key: 'projects.commercial.delivery_field_name', fallback: 'Nom' },
}

type Props = {
  discrepancies: BuyerDeliveryDiscrepancy[]
}

export function BuyerDeliveryDiscrepancyNotice({ discrepancies }: Props) {
  const { t } = useTranslation('projects')
  if (discrepancies.length === 0) return null

  return (
    <div
      role="status"
      className="rounded-lg border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-950 dark:border-amber-800 dark:bg-amber-950/30 dark:text-amber-100"
    >
      <p className="font-medium">
        {t(
          'projects.commercial.delivery_contact_differs_title',
          'Les dades del contacte no coincideixen amb el pressupost emès',
        )}
      </p>
      <p className="mt-1 text-xs opacity-90">
        {t(
          'projects.commercial.delivery_contact_differs_help',
          'L’entrega (WhatsApp, correu, etc.) usa les dades actuals del contacte. El document PDF/HTML conserva les del pressupost.',
        )}
      </p>
      <ul className="mt-2 space-y-1 text-xs">
        {discrepancies.map((row) => {
          const label = t(FIELD_I18N[row.field].key, FIELD_I18N[row.field].fallback)
          return (
            <li key={row.field}>
              <span className="font-medium">{label}:</span>{' '}
              {t('projects.commercial.delivery_contact_differs_row', {
                snapshot: row.snapshot,
                contact: row.contact,
                defaultValue: `pressupost «{{snapshot}}» → s’entrega a «{{contact}}»`,
              })}
            </li>
          )
        })}
      </ul>
    </div>
  )
}
