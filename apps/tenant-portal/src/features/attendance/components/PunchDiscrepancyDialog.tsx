import { useTranslation } from 'react-i18next'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import type {
  PunchDiscrepancyHint,
  PunchDiscrepancyResolution,
} from '../utils/punchDiscrepancyUtils'

const HINT_LABELS: Record<PunchDiscrepancyHint, string> = {
  outside_schedule: 'discrepancy.hint_outside_schedule',
  geo_imprecise: 'discrepancy.hint_geo_imprecise',
  late_punch_out: 'discrepancy.hint_late_out',
  early_punch_out: 'discrepancy.hint_early_out',
  early_punch_in: 'discrepancy.hint_early_in',
  no_schedule_work: 'discrepancy.hint_no_schedule_work',
}

const HINT_FALLBACKS: Record<PunchDiscrepancyHint, string> = {
  outside_schedule: 'Fitxatge fora de l’horari previst',
  geo_imprecise: 'Ubicació imprecisa o llunyana',
  late_punch_out: 'Sortida després de l’horari previst',
  early_punch_out: 'Sortida abans de l’horari previst',
  early_punch_in: 'Entrada abans de l’horari previst',
  no_schedule_work: 'Treball en un dia sense horari assignat',
}

const RESOLUTION_LABELS: Record<PunchDiscrepancyResolution, string> = {
  confirmed_ok: 'discrepancy.option_confirmed_ok',
  strip_geo: 'discrepancy.option_strip_geo',
  overtime_claimed: 'discrepancy.option_overtime',
  scheduled_hours_claimed: 'discrepancy.option_scheduled_hours',
}

const RESOLUTION_FALLBACKS: Record<PunchDiscrepancyResolution, string> = {
  confirmed_ok: 'Tot correcte',
  strip_geo: 'No guardar ubicació',
  overtime_claimed: 'He fet hores extra',
  scheduled_hours_claimed: 'He fet l’horari previst (revisió)',
}

interface PunchDiscrepancyDialogProps {
  open: boolean
  hints: PunchDiscrepancyHint[]
  options: PunchDiscrepancyResolution[]
  isSubmitting: boolean
  onSelect: (resolution: PunchDiscrepancyResolution) => void
}

export function PunchDiscrepancyDialog({
  open,
  hints,
  options,
  isSubmitting,
  onSelect,
}: PunchDiscrepancyDialogProps) {
  const { t } = useTranslation('attendance')

  return (
    <Dialog open={open} onOpenChange={() => { /* controlled */ }}>
      <DialogContent
        className="w-[calc(100%-1.5rem)] max-w-sm min-w-0 overflow-x-hidden rounded-lg p-4 sm:p-6"
        onPointerDownOutside={(e) => e.preventDefault()}
      >
        <DialogHeader className="text-left">
          <DialogTitle className="pr-8 text-balance">
            {t('discrepancy.title', 'Incidència al fitxar')}
          </DialogTitle>
          <DialogDescription asChild>
            <div className="space-y-3 text-left text-sm text-muted-foreground">
              <p>
                {t(
                  'discrepancy.intro',
                  'Hem detectat una possible incidència. Indica què ha passat per facilitar la revisió.',
                )}
              </p>
              {hints.length > 0 && (
                <ul className="list-disc space-y-1 pl-5">
                  {hints.map((hint) => (
                    <li key={hint}>
                      {t(HINT_LABELS[hint], HINT_FALLBACKS[hint])}
                    </li>
                  ))}
                </ul>
              )}
            </div>
          </DialogDescription>
        </DialogHeader>
        <div className="flex min-w-0 flex-col gap-2">
          {options.map((option) => (
            <Button
              key={option}
              type="button"
              variant={option === 'confirmed_ok' ? 'default' : 'outline'}
              className="h-auto min-h-11 w-full justify-start whitespace-normal px-3 py-2.5 text-left leading-snug"
              disabled={isSubmitting}
              onClick={() => onSelect(option)}
            >
              {t(RESOLUTION_LABELS[option], RESOLUTION_FALLBACKS[option])}
            </Button>
          ))}
        </div>
      </DialogContent>
    </Dialog>
  )
}
