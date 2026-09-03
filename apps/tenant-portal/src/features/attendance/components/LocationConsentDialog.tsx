import { useTranslation } from 'react-i18next'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'

interface LocationConsentDialogProps {
  open: boolean
  onAccept: () => void
  onDecline: () => void
}

export function LocationConsentDialog({ open, onAccept, onDecline }: LocationConsentDialogProps) {
  const { t } = useTranslation('attendance')

  return (
    <Dialog
      open={open}
      onOpenChange={(nextOpen) => {
        if (!nextOpen) onDecline()
      }}
    >
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{t('geo.consent_title', 'Geolocalització al fitxar')}</DialogTitle>
          <DialogDescription asChild>
            <div className="space-y-3 text-left text-sm text-muted-foreground">
              <p>
                {t(
                  'geo.consent_intro',
                  'La teva empresa pot registrar la ubicació només en el moment del fitxatge, per complir el control horari legal.',
                )}
              </p>
              <ul className="list-disc space-y-1.5 pl-5">
                <li>
                  {t(
                    'geo.consent_bullet_company',
                    'L’empresa sap si comparteixes la ubicació en fitxar i pot exigir-la segons la seva política.',
                  )}
                </li>
                <li>
                  {t(
                    'geo.consent_bullet_purpose',
                    'Només s’utilitza per acreditar el fitxatge; les dades s’anonimitzen passat el termini legal.',
                  )}
                </li>
                <li>
                  {t(
                    'geo.consent_bullet_decline',
                    'Si no l’acceptes, pots continuar fitxant igualment (sense ubicació o amb limitacions).',
                  )}
                </li>
              </ul>
              <p className="text-xs">
                {t(
                  'geo.consent_once',
                  'Aquest avís es mostra una sola vegada per dispositiu. L’acceptació queda registrada al teu expedient.',
                )}
              </p>
            </div>
          </DialogDescription>
        </DialogHeader>
        <DialogFooter className="gap-2 sm:gap-0">
          <Button variant="outline" onClick={onDecline}>
            {t('geo.consent_decline', 'No registrar ubicació')}
          </Button>
          <Button onClick={onAccept}>{t('geo.consent_accept', 'Accepto registrar ubicació')}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
