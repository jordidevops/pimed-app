import { Check } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { cn } from '@/lib/utils'
import { TabsList, TabsTrigger } from '@/components/ui/tabs'
import type { OrderPhaseTab } from '../utils/deriveOrderWorkflow'

type Step = {
  id: OrderPhaseTab
  label: string
  micro: string
  done: boolean
}

interface OrderPhaseStepperProps {
  prepareDone: boolean
  doDone: boolean
  deliverDone: boolean
  prepareMicro: string
  doMicro: string
  deliverMicro: string
}

export function OrderPhaseStepper({
  prepareDone,
  doDone,
  deliverDone,
  prepareMicro,
  doMicro,
  deliverMicro,
}: OrderPhaseStepperProps) {
  const { t } = useTranslation('field-service')

  const steps: Step[] = [
    {
      id: 'prepare',
      label: t('detail.phase_prepare', 'Preparar'),
      micro: prepareMicro,
      done: prepareDone,
    },
    {
      id: 'do',
      label: t('detail.phase_do', 'Fer'),
      micro: doMicro,
      done: doDone,
    },
    {
      id: 'deliver',
      label: t('detail.phase_deliver', 'Entregar'),
      micro: deliverMicro,
      done: deliverDone,
    },
  ]

  return (
    <nav aria-label={t('detail.phases_aria', 'Fases de l\'ordre')} className="w-full">
      <TabsList className="!grid !h-auto !w-full grid-cols-3 flex-wrap gap-1 bg-transparent p-0">
        {steps.map((step, index) => {
          return (
            <TabsTrigger
              key={step.id}
              value={step.id}
              className={cn(
                'group flex h-auto min-w-0 w-full flex-col items-center gap-0.5 rounded-lg px-1 py-2 text-center shadow-none',
                'text-muted-foreground/70 hover:bg-muted/50',
                'data-[state=active]:bg-primary/10 data-[state=active]:text-foreground data-[state=active]:shadow-none',
              )}
            >
              <span
                className={cn(
                  'flex h-6 w-6 items-center justify-center rounded-full text-xs font-semibold',
                  step.done
                    ? 'bg-emerald-600 text-white'
                    : 'border border-border bg-background text-muted-foreground',
                  'group-data-[state=active]:border-primary group-data-[state=active]:bg-primary group-data-[state=active]:text-primary-foreground',
                )}
              >
                {step.done ? <Check className="h-3.5 w-3.5" strokeWidth={3} /> : index + 1}
              </span>
              <span className="max-w-full truncate text-xs font-semibold leading-tight">
                {step.label}
              </span>
              <span className="line-clamp-1 max-w-full text-[10px] leading-tight text-muted-foreground">
                {step.micro || '\u00a0'}
              </span>
            </TabsTrigger>
          )
        })}
      </TabsList>
    </nav>
  )
}
