import { Button } from '@/components/ui/button'
import { useTranslation } from 'react-i18next'
import type { OrderPrimaryAction } from '../utils/deriveOrderWorkflow'

interface OrderPrimaryActionBarProps {
  action: OrderPrimaryAction
  busy?: boolean
  onAction: (
    action: Exclude<OrderPrimaryAction, 'done' | 'start_work' | 'resume_work'>,
  ) => void
}

/**
 * In-flow phase CTA. On mobile it remains with the sticky phase header; on
 * larger screens it becomes a compact action aligned to the right.
 */
export function OrderPrimaryActionBar({
  action,
  busy = false,
  onAction,
}: OrderPrimaryActionBarProps) {
  const { t } = useTranslation(['field-service', 'projects'])

  if (
    action === 'done' ||
    action === 'start_work' ||
    action === 'resume_work'
  ) {
    return null
  }

  const labels: Record<
    Exclude<OrderPrimaryAction, 'done' | 'start_work' | 'resume_work'>,
    string
  > = {
    show_quote: t('field-service:detail.primary_show_quote', 'Mostrar pressupost'),
    create_quote: t(
      'field-service:detail.primary_create_quote',
      'Crear nou pressupost',
    ),
    review_close: t('field-service:detail.primary_review_close', 'Revisar i tancar'),
    show_delivery: t('field-service:detail.primary_show_delivery', 'Mostrar albarà'),
    office_quote_handoff: t(
      'field-service:detail.primary_office_quote',
      'Preparar pressupost (oficina)',
    ),
    collect: t('projects:projects.commercial.collect', 'Cobrar'),
    send_receipt: t('projects:projects.commercial.send_receipt', 'Enviar comprovant'),
    sync_pending: t(
      'field-service:detail.primary_sync_pending',
      'Pendent de sincronitzar',
    ),
    review_sync_error: t(
      'field-service:detail.primary_review_sync_error',
      'Revisar error de sincronització',
    ),
  }

  return (
    <div className="w-full border-t border-border/60 pt-2 lg:flex lg:justify-end">
      <Button
        type="button"
        size="lg"
        className="h-11 w-full text-base lg:h-9 lg:w-auto lg:text-sm"
        disabled={busy}
        onClick={() => onAction(action)}
      >
        {labels[action]}
      </Button>
    </div>
  )
}
