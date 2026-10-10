import { useTranslation } from 'react-i18next'
import type { ContactCommercialLifecycle } from '../utils/contactCommercialLifecycle'

const STYLES: Record<ContactCommercialLifecycle, string> = {
  effective:
    'bg-emerald-100 text-emerald-800 dark:bg-emerald-900/40 dark:text-emerald-200',
  potential:
    'bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-200',
  agenda: 'bg-slate-100 text-slate-700 dark:bg-slate-800 dark:text-slate-300',
}

export function ContactLifecycleBadge({
  lifecycle,
  className = '',
}: {
  lifecycle: ContactCommercialLifecycle
  className?: string
}) {
  const { t } = useTranslation('contacts')
  const label =
    lifecycle === 'effective'
      ? t('contacts.lifecycle.effective', 'Efectiu')
      : lifecycle === 'potential'
        ? t('contacts.lifecycle.potential', 'Potencial')
        : t('contacts.lifecycle.agenda', 'Agenda')

  return (
    <span
      className={`inline-block px-2 py-0.5 rounded-full text-[10px] font-medium ${STYLES[lifecycle]} ${className}`}
      title={t(
        'contacts.lifecycle.help',
        'Estat comercial derivat (no és un camp editable)',
      )}
    >
      {label}
    </span>
  )
}
