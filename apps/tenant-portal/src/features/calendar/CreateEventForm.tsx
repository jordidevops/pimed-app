import { useState, useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { MapPin, Plus } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
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
import {
  validateCreateEventForm,
  mapFormToRpcPayload,
  REMINDER_PRESETS,
} from './calendar.form.validation'
import type { CalendarResolvedEvent } from './calendar.types'

/** Local datetime-local value without UTC shift. */
function toLocalDatetimeInput(date: Date): string {
  const y = date.getFullYear()
  const mo = String(date.getMonth() + 1).padStart(2, '0')
  const d = String(date.getDate()).padStart(2, '0')
  const h = String(date.getHours()).padStart(2, '0')
  const mi = String(date.getMinutes()).padStart(2, '0')
  return `${y}-${mo}-${d}T${h}:${mi}`
}

function toLocalDateInput(date: Date): string {
  const y = date.getFullYear()
  const mo = String(date.getMonth() + 1).padStart(2, '0')
  const d = String(date.getDate()).padStart(2, '0')
  return `${y}-${mo}-${d}`
}

function parseLocalDateInput(value: string): Date {
  const [y, m, d] = value.split('-').map(Number)
  return new Date(y, (m ?? 1) - 1, d ?? 1)
}

function startOfLocalDay(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate())
}

function exclusiveEndFromInclusiveDate(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate() + 1)
}

type ScopeValue = 'company' | string

interface CreateEventFormProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  initialDate?: Date
  /** When creating (not edit), preselect all-day. */
  initialAllDay?: boolean
  /** Prefill / filter site. null = company-wide context. */
  siteId?: string | null
  /**
   * When true, do not preselect Empresa/centre — user must choose
   * (e.g. company calendar with site=all).
   */
  requireScopeChoice?: boolean
  isDesktop?: boolean
  editEvent?: CalendarResolvedEvent | null
}

function defaultTimedEnd(start: Date): Date {
  return new Date(start.getTime() + 30 * 60_000)
}

export function CreateEventForm({
  open,
  onOpenChange,
  initialDate = new Date(),
  initialAllDay = false,
  siteId,
  requireScopeChoice = false,
  isDesktop = true,
  editEvent,
}: CreateEventFormProps) {
  const { t } = useTranslation('calendar')
  const { user } = useAuth()
  const { selectedTenantId, sites, selectedSiteId, activeRole } = useTenant()
  const queryClient = useQueryClient()
  const isEditMode = !!editEvent

  const initialScope = (): ScopeValue | '' => {
    if (requireScopeChoice && !isEditMode) return ''
    if (isEditMode) {
      return editEvent?.site_id ? editEvent.site_id : 'company'
    }
    if (typeof siteId === 'string' && siteId.trim()) return siteId
    if (siteId === null) return 'company'
    if (selectedSiteId) return selectedSiteId
    return requireScopeChoice ? '' : 'company'
  }

  const [scope, setScope] = useState<ScopeValue | ''>(initialScope)

  const resolvedSiteId: string | null | undefined =
    scope === '' ? undefined : scope === 'company' ? null : scope

  const permissionSiteId = isEditMode
    ? (editEvent?.site_id ?? undefined)
    : resolvedSiteId === undefined
      ? undefined
      : (resolvedSiteId ?? undefined)

  const hasCalendarEditPermission = usePermission('calendar.edit', permissionSiteId)
  const hasCalendarManage = usePermission('calendar.manage', permissionSiteId)
  const canWrite = activeRole === 'owner' || hasCalendarEditPermission
  const canDelete =
    isEditMode &&
    editEvent?.entity_type === 'manual' &&
    (activeRole === 'owner' ||
      hasCalendarManage ||
      (editEvent.owner_id != null && editEvent.owner_id === user?.id))

  const siteName =
    resolvedSiteId != null
      ? (sites.find((s) => s.id === resolvedSiteId)?.name ?? null)
      : null

  const [formData, setFormData] = useState<CreateEventFormInput>(() => {
    const start = editEvent?.start_at ? new Date(editEvent.start_at) : initialDate
    const allDay = editEvent?.all_day ?? initialAllDay
    return {
      title: editEvent?.title ?? '',
      description: editEvent?.description ?? '',
      start_at: start,
      end_at: editEvent?.end_at
        ? new Date(editEvent.end_at)
        : allDay
          ? undefined
          : defaultTimedEnd(start),
      all_day: allDay,
      color: undefined,
      reminders: [],
    }
  })
  const [errors, setErrors] = useState<Record<string, string>>({})
  const [tempReminderId, setTempReminderId] = useState(0)

  useEffect(() => {
    if (!open) return
    setScope(initialScope())
    const start = editEvent?.start_at ? new Date(editEvent.start_at) : initialDate
    const allDay = editEvent?.all_day ?? initialAllDay
    setFormData({
      title: editEvent?.title ?? '',
      description: editEvent?.description ?? '',
      start_at: start,
      end_at: editEvent?.end_at
        ? new Date(editEvent.end_at)
        : allDay
          ? undefined
          : defaultTimedEnd(start),
      all_day: allDay,
      color: undefined,
      reminders: [],
    })
    setErrors({})
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, editEvent, initialDate, initialAllDay])

  const saveMutation = useMutation({
    mutationFn: async () => {
      if (!selectedTenantId) throw new Error('No tenant selected')
      if (scope === '') throw new Error('scope_required')

      const allDay = Boolean(formData.all_day)
      const startAt = allDay ? startOfLocalDay(formData.start_at) : formData.start_at
      let endAt: Date | undefined
      if (allDay) {
        const inclusiveEnd = formData.end_at
          ? startOfLocalDay(formData.end_at)
          : startOfLocalDay(formData.start_at)
        endAt = exclusiveEndFromInclusiveDate(inclusiveEnd)
      } else {
        endAt = formData.end_at ?? undefined
      }

      const normalized: CreateEventFormInput = {
        ...formData,
        start_at: startAt,
        end_at: endAt,
        all_day: allDay,
      }

      if (isEditMode && editEvent?.id) {
        const { error } = await supabase.rpc('update_calendar_event', {
          p_id: editEvent.id,
          p_title: normalized.title,
          p_description: normalized.description || undefined,
          p_start_at: normalized.start_at.toISOString(),
          p_end_at: normalized.end_at ? normalized.end_at.toISOString() : undefined,
          p_all_day: normalized.all_day ?? false,
        })
        if (error) throw error
        return null
      }

      const payload = mapFormToRpcPayload(normalized, selectedTenantId, resolvedSiteId ?? null)
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

  const deleteMutation = useMutation({
    mutationFn: async () => {
      if (!editEvent?.id) throw new Error('missing_event')
      const { error } = await supabase.rpc('delete_manual_calendar_event' as never, {
        p_id: editEvent.id,
      } as never)
      if (error) throw error
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['calendar_events'] })
      onOpenChange(false)
    },
    onError: (err) => {
      console.error('Failed to delete event:', err)
      setErrors({ general: 'calendar.error.deleteFailed' })
    },
  })

  function handleSubmit() {
    if (scope === '' && !isEditMode) {
      setErrors({ scope: 'calendar.validation.scopeRequired' })
      return
    }
    const validationErrors = validateCreateEventForm(formData)
    if (validationErrors.length > 0) {
      const errMap: Record<string, string> = {}
      for (const err of validationErrors) errMap[err.field] = err.message
      setErrors(errMap)
      return
    }
    setErrors({})
    saveMutation.mutate()
  }

  function handleDelete() {
    if (
      !window.confirm(
        t('calendar.form.deleteConfirm', 'Segur que vols eliminar aquest event?'),
      )
    ) {
      return
    }
    deleteMutation.mutate()
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

  const isSubmitting = saveMutation.isPending || deleteMutation.isPending
  const allDay = Boolean(formData.all_day)
  const inclusiveEndForInput = (() => {
    if (!formData.end_at) return formData.start_at
    if (allDay && formData.end_at.getHours() === 0 && formData.end_at.getMinutes() === 0) {
      return new Date(
        formData.end_at.getFullYear(),
        formData.end_at.getMonth(),
        formData.end_at.getDate() - 1,
      )
    }
    return formData.end_at
  })()

  const content = (
    <div className="space-y-4">
      {!isEditMode ? (
        <div>
          <label className="text-sm font-medium">
            {t('calendar.form.scopeLabel', 'Àmbit *')}
          </label>
          <select
            title={t('calendar.form.scopeLabel', 'Àmbit')}
            className={[
              'mt-1 w-full rounded-md border px-3 py-2 text-sm',
              errors.scope ? 'border-red-500' : 'border-border',
            ].join(' ')}
            value={scope}
            onChange={(e) => {
              setScope(e.target.value as ScopeValue | '')
              if (errors.scope) setErrors((prev) => ({ ...prev, scope: '' }))
            }}
            disabled={isSubmitting}
          >
            <option value="">
              {t('calendar.form.scopePlaceholder', 'Selecciona àmbit…')}
            </option>
            <option value="company">{t('calendar.form.scopeCompany', 'Tots els centres')}</option>
            {sites.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </select>
          {errors.scope ? (
            <p className="mt-1 text-xs text-red-500">{t(errors.scope, errors.scope)}</p>
          ) : null}
        </div>
      ) : null}

      <div>
        <label className="text-sm font-medium">{t('calendar.form.titleLabel', 'Títol *')}</label>
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
        {errors.title ? (
          <p className="mt-1 text-xs text-red-500">{t(errors.title, errors.title)}</p>
        ) : null}
      </div>

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

      <div className="flex items-center gap-2">
        <input
          type="checkbox"
          id="all-day"
          checked={allDay}
          onChange={(e) => setFormData((prev) => ({ ...prev, all_day: e.target.checked }))}
          disabled={isSubmitting}
        />
        <label htmlFor="all-day" className="text-sm">
          {t('calendar.form.allDayLabel', 'Event de tot el dia')}
        </label>
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div>
          <label className="text-sm font-medium">
            {allDay
              ? t('calendar.form.startDateOnlyLabel', 'Data inici *')
              : t('calendar.form.startDateLabel', 'Data i hora inici *')}
          </label>
          {allDay ? (
            <input
              type="date"
              title={t('calendar.form.startDateOnlyLabel', 'Data inici')}
              value={toLocalDateInput(formData.start_at)}
              onChange={(e) => {
                const date = parseLocalDateInput(e.target.value)
                setFormData((prev) => ({ ...prev, start_at: date }))
              }}
              className="mt-1 w-full rounded-md border border-border px-3 py-2 text-sm"
              disabled={isSubmitting}
            />
          ) : (
            <input
              type="datetime-local"
              title={t('calendar.form.startDateLabel', 'Data i hora inici')}
              value={toLocalDatetimeInput(formData.start_at)}
              onChange={(e) => {
                setFormData((prev) => ({ ...prev, start_at: new Date(e.target.value) }))
              }}
              className="mt-1 w-full rounded-md border border-border px-3 py-2 text-sm"
              disabled={isSubmitting}
            />
          )}
        </div>
        <div>
          <label className="text-sm font-medium">
            {allDay
              ? t('calendar.form.endDateOnlyLabel', 'Data fi')
              : t('calendar.form.endDateLabel', 'Data i hora fi')}
          </label>
          {allDay ? (
            <input
              type="date"
              title={t('calendar.form.endDateOnlyLabel', 'Data fi')}
              value={toLocalDateInput(inclusiveEndForInput)}
              onChange={(e) => {
                const date = parseLocalDateInput(e.target.value)
                setFormData((prev) => ({ ...prev, end_at: date }))
              }}
              className="mt-1 w-full rounded-md border border-border px-3 py-2 text-sm"
              disabled={isSubmitting}
            />
          ) : (
            <input
              type="datetime-local"
              title={t('calendar.form.endDateLabel', 'Data i hora fi')}
              value={formData.end_at ? toLocalDatetimeInput(formData.end_at) : ''}
              onChange={(e) => {
                setFormData((prev) => ({
                  ...prev,
                  end_at: e.target.value ? new Date(e.target.value) : undefined,
                }))
              }}
              className="mt-1 w-full rounded-md border border-border px-3 py-2 text-sm"
              disabled={isSubmitting}
            />
          )}
        </div>
      </div>

      {!isEditMode ? (
        <div className="space-y-2 border-t pt-4">
          <div className="flex items-center justify-between">
            <label className="text-sm font-medium">
              {t('calendar.reminders.title', 'Recordatoris')}
            </label>
            {formData.reminders.length < 5 ? (
              <Button
                type="button"
                variant="ghost"
                size="sm"
                onClick={handleAddReminder}
                disabled={isSubmitting}
              >
                <Plus className="mr-1 h-4 w-4" />
                {t('calendar.reminders.addReminder', 'Afegir recordatori')}
              </Button>
            ) : null}
          </div>
          {formData.reminders.map((reminder, idx) => (
            <div key={reminder._tempId || idx} className="flex items-end gap-2">
              <div className="flex-1">
                <label className="text-xs text-muted-foreground">
                  {t('calendar.reminders.offsetLabel', 'Recordar')}
                </label>
                <select
                  title={t('calendar.reminders.offsetTitle', 'Quan')}
                  value={reminder.offset_minutes}
                  onChange={(e) =>
                    setFormData((prev) => ({
                      ...prev,
                      reminders: prev.reminders.map((r) =>
                        r._tempId === reminder._tempId
                          ? { ...r, offset_minutes: parseInt(e.target.value, 10) }
                          : r,
                      ),
                    }))
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
                  title={t('calendar.reminders.channelTitle', 'Canal')}
                  value={reminder.channel}
                  onChange={(e) =>
                    setFormData((prev) => ({
                      ...prev,
                      reminders: prev.reminders.map((r) =>
                        r._tempId === reminder._tempId
                          ? { ...r, channel: e.target.value as ReminderInput['channel'] }
                          : r,
                      ),
                    }))
                  }
                  className="w-full rounded-md border border-border px-2 py-1 text-sm"
                  disabled={isSubmitting}
                >
                  <option value="email">{t('calendar.reminders.channelEmail', 'Email')}</option>
                </select>
              </div>
              <Button
                type="button"
                variant="ghost"
                size="sm"
                onClick={() =>
                  setFormData((prev) => ({
                    ...prev,
                    reminders: prev.reminders.filter((r) => r._tempId !== reminder._tempId),
                  }))
                }
                disabled={isSubmitting}
                className="text-red-500 hover:text-red-700"
              >
                ✕
              </Button>
            </div>
          ))}
        </div>
      ) : null}

      {errors.general ? (
        <div className="rounded-md bg-red-50 p-2 text-xs text-red-600">
          {t(errors.general, errors.general)}
        </div>
      ) : null}

      <div className="flex justify-end gap-2 border-t pt-4">
        {canDelete ? (
          <Button
            type="button"
            variant="destructive"
            onClick={handleDelete}
            disabled={isSubmitting}
            className="mr-auto"
          >
            {t('calendar.actions.delete', 'Eliminar event')}
          </Button>
        ) : null}
        <Button type="button" variant="outline" onClick={() => onOpenChange(false)} disabled={isSubmitting}>
          {t('calendar.form.cancel', 'Cancel·lar')}
        </Button>
        <Button type="button" onClick={handleSubmit} disabled={!canWrite || isSubmitting}>
          {isSubmitting
            ? t('calendar.loading', 'Carregant...')
            : isEditMode
              ? t('calendar.form.submitEdit', 'Desar canvis')
              : t('calendar.form.submit', 'Crear event')}
        </Button>
      </div>
    </div>
  )

  const dialogTitle = isEditMode
    ? t('calendar.form.editTitle', 'Editar event')
    : t('calendar.form.title', 'Crear event')

  const siteContextBadge = siteName ? (
    <span className="mt-1 flex items-center gap-1 text-xs font-normal text-muted-foreground">
      <MapPin className="h-3 w-3" />
      {siteName}
    </span>
  ) : scope === 'company' ? (
    <span className="mt-1 text-xs font-normal text-muted-foreground">
      {t('calendar.form.scopeCompany', 'Tots els centres')}
    </span>
  ) : null

  return isDesktop ? (
    <Dialog open={open} onOpenChange={onOpenChange}>
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
    <Drawer open={open} onOpenChange={onOpenChange}>
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
