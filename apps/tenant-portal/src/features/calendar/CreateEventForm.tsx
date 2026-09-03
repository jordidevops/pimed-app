import { useState, useEffect } from 'react'

/** Formata un Date com a string per a <input type="datetime-local"> usant hora local,
 *  evitant que toISOString() (UTC) mostri el dia anterior a UTC+X.
 */
function toLocalDatetimeInput(date: Date): string {
  const y = date.getFullYear()
  const mo = String(date.getMonth() + 1).padStart(2, '0')
  const d  = String(date.getDate()).padStart(2, '0')
  const h  = String(date.getHours()).padStart(2, '0')
  const mi = String(date.getMinutes()).padStart(2, '0')
  return `${y}-${mo}-${d}T${h}:${mi}`
}
import { useTranslation } from 'react-i18next'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { MapPin, Plus } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useTenant } from '@/contexts/TenantContext'
import { usePermission } from '@/hooks/usePermission'
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
import type { CreateEventFormInput, ReminderInput } from './calendar.form.types'
import { validateCreateEventForm, mapFormToRpcPayload, REMINDER_PRESETS } from './calendar.form.validation'
import type { CalendarResolvedEvent } from './calendar.types'

interface CreateEventFormProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  initialDate?: Date
  siteId?: string | null
  isDesktop?: boolean
  /** When provided, the form enters edit mode pre-filled with this event */
  editEvent?: CalendarResolvedEvent | null
}

export function CreateEventForm({
  open,
  onOpenChange,
  initialDate = new Date(),
  siteId,
  isDesktop = true,
  editEvent,
}: CreateEventFormProps) {
  const { t } = useTranslation('calendar')
  const { selectedTenantId, sites, selectedSiteId, activeRole } = useTenant()
  const queryClient = useQueryClient()

  const isEditMode = !!editEvent

  // Fix: en mode edició usa el site_id de l'event (no el siteId del widget, que pot ser
  // null en vista global). Això evita que un usuari site-only vegi el botó "Editar" actiu
  // però no pugui desar perquè el formulari comprova el context global incorrecte.
  const permissionSiteId = isEditMode
    ? (editEvent?.site_id ?? undefined)
    : (siteId !== undefined ? siteId : undefined)
  const hasCalendarEditPermission = usePermission('calendar.edit', permissionSiteId)
  const canWrite = activeRole === 'owner' || hasCalendarEditPermission

  // Resolve site name for display
  const effectiveSiteId = siteId ?? selectedSiteId
  const siteName = effectiveSiteId
    ? (sites.find((s) => s.id === effectiveSiteId)?.name ?? null)
    : null

  // Form state — reset whenever the modal opens or editEvent changes
  const [formData, setFormData] = useState<CreateEventFormInput>(() => ({
    title: editEvent?.title ?? '',
    description: editEvent?.description ?? '',
    start_at: editEvent?.start_at ? new Date(editEvent.start_at) : initialDate,
    end_at: editEvent?.end_at ? new Date(editEvent.end_at) : undefined,
    all_day: editEvent?.all_day ?? false,
    color: undefined,
    reminders: [],
  }))
  const [errors, setErrors] = useState<Record<string, string>>({})
  const [tempReminderId, setTempReminderId] = useState(0)

  useEffect(() => {
    if (open) {
      setFormData({
        title: editEvent?.title ?? '',
        description: editEvent?.description ?? '',
        start_at: editEvent?.start_at ? new Date(editEvent.start_at) : initialDate,
        end_at: editEvent?.end_at ? new Date(editEvent.end_at) : undefined,
        all_day: editEvent?.all_day ?? false,
        color: undefined,
        reminders: [],
      })
      setErrors({})
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, editEvent])

  // Mutation to create or update event
  const createEventMutation = useMutation({
    mutationFn: async () => {
      if (!selectedTenantId) throw new Error('No tenant selected')

      if (isEditMode && editEvent?.id) {
        // UPDATE path via RPC
        const { error } = await supabase.rpc('update_calendar_event', {
          p_id: editEvent.id,
          p_title: formData.title,
          p_description: formData.description || undefined,
          p_start_at: formData.start_at.toISOString(),
          p_end_at: formData.end_at ? formData.end_at.toISOString() : undefined,
          p_all_day: formData.all_day ?? false,
        })

        if (error) throw error
        return null
      }

      // CREATE path
      const payload = mapFormToRpcPayload(formData, selectedTenantId, siteId)
      const { data, error } = await supabase.rpc('create_calendar_event_with_reminders', payload)
      if (error) throw error
      return data
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['calendar_events'] })
      setErrors({})
      onOpenChange(false)
    },
    onError: (err) => {
      console.error('Failed to save event:', err)
      setErrors({ general: 'calendar.error.saveFailed' })
    },
  })

  function handleSubmit() {
    // Run validation inline before mutating
    const validationErrors = validateCreateEventForm(formData)
    if (validationErrors.length > 0) {
      const errMap: Record<string, string> = {}
      for (const err of validationErrors) errMap[err.field] = err.message
      setErrors(errMap)
      return
    }
    setErrors({})
    createEventMutation.mutate()
  }

  const handleAddReminder = () => {
    if (formData.reminders.length >= 5) return

    const newReminder: ReminderInput = {
      offset_minutes: 30,
      channel: 'email',
      _tempId: `temp-${tempReminderId}`,
    }
    setFormData((prev) => ({
      ...prev,
      reminders: [...prev.reminders, newReminder],
    }))
    setTempReminderId((prev) => prev + 1)
  }

  const handleRemoveReminder = (tempId: string | undefined) => {
    setFormData((prev) => ({
      ...prev,
      reminders: prev.reminders.filter((r) => r._tempId !== tempId),
    }))
  }

  const handleUpdateReminder = (tempId: string | undefined, field: string, value: unknown) => {
    setFormData((prev) => ({
      ...prev,
      reminders: prev.reminders.map((r) =>
        r._tempId === tempId
          ? { ...r, [field]: value }
          : r,
      ),
    }))
  }

  const isSubmitting = createEventMutation.isPending
  const generalError = errors.general

  const content = (
    <div className="space-y-4">
      {/* Title */}
      <div>
        <label className="text-sm font-medium">
          {t('calendar.form.titleLabel', 'Títol *')}
        </label>
        <input
          type="text"
          value={formData.title}
          onChange={(e) => {
            setFormData((prev) => ({ ...prev, title: e.target.value }))
            if (errors.title) setErrors((prev) => ({ ...prev, title: '' }))
          }}
          placeholder={t('calendar.form.titlePlaceholder', 'Afegir títol del event')}
          className={[
            'mt-1 w-full rounded-md border px-3 py-2 text-sm',
            errors.title ? 'border-red-500' : 'border-border',
          ].join(' ')}
          disabled={isSubmitting}
        />
        {errors.title && <p className="text-xs text-red-500 mt-1">{t(errors.title, errors.title)}</p>}
      </div>

      {/* Description */}
      <div>
        <label className="text-sm font-medium">
          {t('calendar.form.descriptionLabel', 'Descripció')}
        </label>
        <textarea
          value={formData.description || ''}
          onChange={(e) => setFormData((prev) => ({ ...prev, description: e.target.value }))}
          placeholder={t('calendar.form.descriptionPlaceholder', 'Afegir més detalls...')}
          className="mt-1 w-full rounded-md border border-border px-3 py-2 text-sm"
          rows={3}
          disabled={isSubmitting}
        />
      </div>

      {/* Start date */}
      <div className="grid grid-cols-2 gap-3">
        <div>
          <label className="text-sm font-medium">
            {t('calendar.form.startDateLabel', 'Data i hora inici *')}
          </label>
          <input
          title={t('calendar.form.startDateTitle', 'Selecciona la data i hora d\'inici')}
            type="datetime-local"
            value={toLocalDatetimeInput(formData.start_at)}
            onChange={(e) => {
              const date = new Date(e.target.value)
              setFormData((prev) => ({ ...prev, start_at: date }))
              if (errors.start_at) setErrors((prev) => ({ ...prev, start_at: '' }))
            }}
            className={[
              'mt-1 w-full rounded-md border px-3 py-2 text-sm',
              errors.start_at ? 'border-red-500' : 'border-border',
            ].join(' ')}
            disabled={isSubmitting}
          />
          {errors.start_at && <p className="text-xs text-red-500 mt-1">{t(errors.start_at, errors.start_at)}</p>}
        </div>

        {/* End date */}
        <div>
          <label className="text-sm font-medium">
            {t('calendar.form.endDateLabel', 'Data i hora fi')}
          </label>
          <input
            title={t('calendar.form.endDateTitle', 'Selecciona la data i hora de fi')}
            type="datetime-local"
            value={formData.end_at ? toLocalDatetimeInput(formData.end_at) : ''}
            onChange={(e) => {
              const date = e.target.value ? new Date(e.target.value) : undefined
              setFormData((prev) => ({ ...prev, end_at: date }))
              if (errors.end_at) setErrors((prev) => ({ ...prev, end_at: '' }))
            }}
            className={[
              'mt-1 w-full rounded-md border px-3 py-2 text-sm',
              errors.end_at ? 'border-red-500' : 'border-border',
            ].join(' ')}
            disabled={isSubmitting}
          />
          {errors.end_at && <p className="text-xs text-red-500 mt-1">{t(errors.end_at, errors.end_at)}</p>}
        </div>
      </div>

      {/* All day checkbox */}
      <div className="flex items-center gap-2">
        <input
          type="checkbox"
          id="all-day"
          checked={formData.all_day ?? false}
          onChange={(e) => setFormData((prev) => ({ ...prev, all_day: e.target.checked }))}
          disabled={isSubmitting}
        />
        <label htmlFor="all-day" className="text-sm">
          {t('calendar.form.allDayLabel', 'Event de tot el dia')}
        </label>
      </div>

      {/* Reminders — ocults en mode edició: el RPC update_calendar_event no gestiona
           recordatoris. S'implementarà en una iteració futura amb api.upsert_event_reminders */}
      {!isEditMode && <div className="space-y-2 border-t pt-4">
        <div className="flex items-center justify-between">
          <label className="text-sm font-medium">
            {t('calendar.reminders.title', 'Recordatoris')}
          </label>
          {formData.reminders.length < 5 && (
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={handleAddReminder}
              disabled={isSubmitting}
            >
              <Plus className="h-4 w-4 mr-1" />
              {t('calendar.reminders.addReminder', 'Afegir recordatori')}
            </Button>
          )}
        </div>

        {formData.reminders.map((reminder, idx) => (
          <div key={reminder._tempId || idx} className="flex gap-2 items-end">
            <div className="flex-1">
              <label className="text-xs text-muted-foreground">
                {t('calendar.reminders.offsetLabel', 'Recordar')}
              </label>
              <select
                title={t('calendar.reminders.offsetTitle', 'Selecciona quan vols ser recordat')}
                value={reminder.offset_minutes}
                onChange={(e) =>
                  handleUpdateReminder(reminder._tempId, 'offset_minutes', parseInt(e.target.value))
                }
                className="w-full rounded-md border border-border px-2 py-1 text-sm"
                disabled={isSubmitting}
              >
                {REMINDER_PRESETS.map((preset) => (
                  <option key={preset.value} value={preset.value}>
                    {preset.label}
                  </option>
                ))}
              </select>
            </div>

            <div className="flex-1">
              <label className="text-xs text-muted-foreground">
                {t('calendar.reminders.channel', 'Via')}
              </label>
              <select
                title={t('calendar.reminders.channelTitle', 'Selecciona el canal de recordatori')}
                value={reminder.channel}
                onChange={(e) =>
                  handleUpdateReminder(reminder._tempId, 'channel', e.target.value)
                }
                className="w-full rounded-md border border-border px-2 py-1 text-sm"
                disabled={isSubmitting}
              >
                <option value="email">{t('calendar.reminders.channelEmail', 'Email')}</option>
                <option value="push" disabled>{t('calendar.reminders.channelPush', 'Notificació (properament)')}</option>
                <option value="sms" disabled>{t('calendar.reminders.channelSms', 'SMS (properament)')}</option>
              </select>
            </div>

            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={() => handleRemoveReminder(reminder._tempId)}
              disabled={isSubmitting}
              className="text-red-500 hover:text-red-700"
            >
              ✕
            </Button>
          </div>
        ))}

        {errors.reminders && (
          <p className="text-xs text-red-500">{t(errors.reminders, errors.reminders)}</p>
        )}
      </div>}

      {/* General error */}
      {generalError && (
        <div className="rounded-md bg-red-50 p-2 text-xs text-red-600">
          {t(generalError, generalError)}
        </div>
      )}

      {/* Actions */}
      <div className="flex gap-2 justify-end border-t pt-4">
        <Button
          type="button"
          variant="outline"
          onClick={() => onOpenChange(false)}
          disabled={isSubmitting}
        >
          {t('calendar.form.cancel', 'Cancel·lar')}
        </Button>
        <Button
          type="button"
          onClick={handleSubmit}
          disabled={!canWrite || isSubmitting}
        >
          {isSubmitting
            ? t('calendar.loading', 'Carregant...')
            : isEditMode
              ? t('calendar.form.submitEdit', 'Desar canvis')
              : t('calendar.form.submit', 'Crear event')}
        </Button>
      </div>
    </div>
  )

  const dialogProps = { open, onOpenChange }

  const dialogTitle = isEditMode
    ? t('calendar.form.editTitle', 'Editar event')
    : t('calendar.form.title', 'Crear event')

  const siteContextBadge = siteName ? (
    <span className="flex items-center gap-1 text-xs text-muted-foreground font-normal mt-1">
      <MapPin className="h-3 w-3" />
      {siteName}
    </span>
  ) : null

  return isDesktop ? (
    <Dialog {...dialogProps}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{dialogTitle}</DialogTitle>
          {siteContextBadge}
          <DialogDescription className="sr-only">
            {t('calendar.form.descriptionPlaceholder', 'Afegir més detalls...')}
          </DialogDescription>
        </DialogHeader>
        {content}
      </DialogContent>
    </Dialog>
  ) : (
    <Drawer {...dialogProps}>
      <DrawerContent>
        <DrawerHeader>
          <DrawerTitle>{dialogTitle}</DrawerTitle>
          {siteContextBadge}
          <DrawerDescription className="sr-only">
            {t('calendar.form.descriptionPlaceholder', 'Afegir més detalls...')}
          </DrawerDescription>
        </DrawerHeader>
        <div className="px-4 pb-4">{content}</div>
      </DrawerContent>
    </Drawer>
  )
}
