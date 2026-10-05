import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Lock } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import {
  Drawer,
  DrawerContent,
  DrawerDescription,
  DrawerHeader,
  DrawerTitle,
} from '@/components/ui/drawer'
import { toUiLocale } from './calendarDateUtils'
import type { CalendarResolvedEvent } from './calendar.types'

export function DefaultEventDetail({
  event,
  canEdit,
  onEdit,
  onDelete,
  deleting = false,
}: {
  event: CalendarResolvedEvent
  canEdit: boolean
  onEdit?: () => void
  onDelete?: () => void
  deleting?: boolean
}) {
  const { t, i18n } = useTranslation('calendar')
  const locale = toUiLocale(i18n.resolvedLanguage)
  const projectHref =
    event.entity_type === 'project' && event.entity_id
      ? `/projects/${event.entity_id}`
      : null

  const meta =
    event.metadata && typeof event.metadata === 'object' && !Array.isArray(event.metadata)
      ? (event.metadata as Record<string, unknown>)
      : null
  const slotDate = meta?.slot_date != null ? String(meta.slot_date) : null
  const locationName = meta?.location_name != null ? String(meta.location_name) : null
  const shiftsHref =
    event.entity_type === 'shift_slot'
      ? slotDate
        ? `/attendance-mgmt/planning/shifts?week=${encodeURIComponent(slotDate)}`
        : '/attendance-mgmt/planning/shifts'
      : null

  return (
    <div className="space-y-3">
      <div className="flex items-center gap-2">
        {projectHref ? (
          <Link
            to={projectHref}
            className="inline-flex items-center gap-2 font-medium text-primary underline-offset-2 hover:underline"
            title={t('calendar.detail.openProject', 'Obrir projecte')}
          >
            {typeof event.resolvedIcon === 'string' ? <span>{event.resolvedIcon}</span> : null}
            {t(`calendar.entity.${event.entity_type}`, event.resolvedLabel)}
          </Link>
        ) : shiftsHref ? (
          <Link
            to={shiftsHref}
            className="inline-flex items-center gap-2 font-medium text-primary underline-offset-2 hover:underline"
            title={t('calendar.detail.openShiftsPlanner', 'Obrir planificador de torns')}
          >
            {typeof event.resolvedIcon === 'string' ? <span>{event.resolvedIcon}</span> : null}
            {t(`calendar.entity.${event.entity_type}`, event.resolvedLabel)}
            {event.title ? ` · ${event.title}` : ''}
          </Link>
        ) : (
          <>
            {typeof event.resolvedIcon === 'string' ? <span>{event.resolvedIcon}</span> : null}
            <span className="font-medium">
              {t(`calendar.entity.${event.entity_type}`, event.resolvedLabel)}
              {event.entity_type === 'shift_slot' && event.title ? ` · ${event.title}` : ''}
            </span>
          </>
        )}
      </div>

      <p className="text-sm text-muted-foreground">
        {event.description ?? t('calendar.noDescription', 'Sense descripció')}
      </p>

      <div className="space-y-1 text-sm">
        <p>
          <strong>{t('calendar.detail.start', 'Inici')}:</strong>{' '}
          {event.start_at
            ? new Date(event.start_at).toLocaleString(locale)
            : t('calendar.notAvailable', 'No disponible')}
        </p>
        <p>
          <strong>{t('calendar.detail.end', 'Fi')}:</strong>{' '}
          {event.end_at
            ? new Date(event.end_at).toLocaleString(locale)
            : t('calendar.noEndDate', 'Sense data de fi')}
        </p>
        {event.entity_type === 'shift_slot' && slotDate ? (
          <p>
            <strong>{t('calendar.detail.slotDate', 'Data')}:</strong> {slotDate}
          </p>
        ) : null}
        {event.entity_type === 'shift_slot' && locationName ? (
          <p>
            <strong>{t('calendar.detail.location', 'Ubicació')}:</strong> {locationName}
          </p>
        ) : null}
      </div>

      {event.addonUnavailable ? (
        <div className="rounded-md border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-800">
          {t(
            'calendar.addonUpgrade',
            'Aquest mòdul no està actiu al teu pla. Actualitza el pla per gestionar aquest event.',
          )}
        </div>
      ) : null}

      {!canEdit ? (
        <div className="flex items-center gap-2 text-sm text-muted-foreground">
          <Lock className="h-4 w-4" />
          {t('calendar.readOnly', 'Mode només lectura')}
        </div>
      ) : event.entity_type === 'manual' ? (
        <div className="flex flex-wrap justify-end gap-2 pt-2">
          {onDelete ? (
            <Button
              type="button"
              size="sm"
              variant="destructive"
              disabled={deleting}
              onClick={onDelete}
            >
              {t('calendar.actions.delete', 'Eliminar event')}
            </Button>
          ) : null}
          {onEdit ? (
            <Button type="button" size="sm" variant="outline" onClick={onEdit}>
              {t('calendar.actions.edit', 'Editar event')}
            </Button>
          ) : null}
        </div>
      ) : null}
    </div>
  )
}

export function EventDetailSheet({
  event,
  canEdit,
  isDesktop,
  onClose,
  onEdit,
  onDelete,
  deleting,
}: {
  event: CalendarResolvedEvent | null
  canEdit: boolean
  isDesktop: boolean
  onClose: () => void
  onEdit?: () => void
  onDelete?: () => void
  deleting?: boolean
}) {
  const { t } = useTranslation('calendar')
  const open = Boolean(event)
  const modalTitle = event?.title ?? t('calendar.untitled', '(Sense títol)')
  const DetailComponent = event?.moduleDefinition?.DetailModal

  const body =
    event == null ? null : DetailComponent ? (
      <DetailComponent event={event} canEdit={canEdit} onClose={onClose} />
    ) : (
      <DefaultEventDetail
        event={event}
        canEdit={canEdit}
        onEdit={canEdit ? onEdit : undefined}
        onDelete={canEdit && event.entity_type === 'manual' ? onDelete : undefined}
        deleting={deleting}
      />
    )

  if (isDesktop) {
    return (
      <Dialog
        open={open}
        onOpenChange={(next) => {
          if (!next) onClose()
        }}
      >
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{modalTitle}</DialogTitle>
            <DialogDescription>
              {event
                ? t(`calendar.entity.${event.entity_type}`, event.resolvedLabel)
                : t('calendar.detail.defaultDescription', "Detall de l'event")}
            </DialogDescription>
          </DialogHeader>
          {body}
        </DialogContent>
      </Dialog>
    )
  }

  return (
    <Drawer
      open={open}
      onOpenChange={(next: boolean) => {
        if (!next) onClose()
      }}
    >
      <DrawerContent>
        <DrawerHeader>
          <DrawerTitle>{modalTitle}</DrawerTitle>
          <DrawerDescription>
            {event
              ? t(`calendar.entity.${event.entity_type}`, event.resolvedLabel)
              : t('calendar.detail.defaultDescription', "Detall de l'event")}
          </DrawerDescription>
        </DrawerHeader>
        <div className="px-4 pb-4">{body}</div>
      </DrawerContent>
    </Drawer>
  )
}
