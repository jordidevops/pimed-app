import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'

const DISMISS_KEY = 'field_service_onboarding_dismissed'

interface FieldOnboardingCardProps {
  show: boolean
}

export function FieldOnboardingCard({ show }: FieldOnboardingCardProps) {
  const { t } = useTranslation('field-service')
  const [dismissed, setDismissed] = useState(
    () =>
      typeof sessionStorage !== 'undefined' &&
      sessionStorage.getItem(DISMISS_KEY) === '1',
  )

  if (!show || dismissed) return null

  return (
    <div className="rounded-2xl border border-primary/30 bg-primary/5 p-4 space-y-3">
      <h2 className="text-base font-semibold">
        {t('onboarding.title', 'Comença a camp')}
      </h2>
      <ol className="space-y-2 text-sm text-muted-foreground list-decimal list-inside">
        <li>
          <span className="font-medium text-foreground">
            {t('onboarding.step1_title', 'Crea un client i adreça')}
          </span>
          {' — '}
          {t('onboarding.step1_desc', 'Necessites un client amb almenys una adreça d\'obra.')}
        </li>
        <li>
          <span className="font-medium text-foreground">
            {t('onboarding.step2_title', 'Crea la primera ordre')}
          </span>
          {' — '}
          {t('onboarding.step2_desc', 'Assigna client, adreça i data de visita.')}
        </li>
        <li>
          <span className="font-medium text-foreground">
            {t('onboarding.step3_title', 'Inicia la visita')}
          </span>
          {' — '}
          {t('onboarding.step3_desc', 'Des d\'Avui, prem Iniciar visita amb la geolocalització.')}
        </li>
      </ol>
      <div className="flex flex-wrap gap-2">
        <Button asChild size="sm">
          <Link to="/contacts">{t('more.clients', 'Clients')}</Link>
        </Button>
        <Button asChild size="sm" variant="outline">
          <Link to="/field/orders?create=1">{t('orders.new', 'Nova ordre')}</Link>
        </Button>
        <Button
          size="sm"
          variant="ghost"
          onClick={() => {
            sessionStorage.setItem(DISMISS_KEY, '1')
            setDismissed(true)
          }}
        >
          OK
        </Button>
      </div>
    </div>
  )
}
