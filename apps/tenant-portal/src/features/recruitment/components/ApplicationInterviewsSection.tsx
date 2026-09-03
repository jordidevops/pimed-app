import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { Pencil, Plus } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import { useToast } from '@/hooks/use-toast'
import {
  createInterview,
  updateInterview,
  type Interview,
  type InterviewStatus,
  type InterviewType,
} from '../api/recruitmentService'
import { recruitmentKeys, useApplicationInterviews } from '../api/useRecruitment'

function toLocalInputValue(iso: string | null): string {
  if (!iso) return ''
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`
}

function fromLocalInputValue(local: string): string | null {
  if (!local.trim()) return null
  const d = new Date(local)
  if (Number.isNaN(d.getTime())) return null
  return d.toISOString()
}

interface Props {
  applicationId: string
  tenantId: string
  canEdit: boolean
}

export function ApplicationInterviewsSection({ applicationId, tenantId, canEdit }: Props) {
  const { t } = useTranslation('recruitment')
  const { toast } = useToast()
  const qc = useQueryClient()
  const { data: interviews = [], isLoading } = useApplicationInterviews(applicationId)

  const [formOpen, setFormOpen] = useState(false)
  const [editing, setEditing] = useState<Interview | null>(null)
  const [type, setType] = useState<InterviewType>('online')
  const [scheduledAt, setScheduledAt] = useState('')
  const [duration, setDuration] = useState('60')
  const [locationOrLink, setLocationOrLink] = useState('')
  const [notes, setNotes] = useState('')
  const [status, setStatus] = useState<InterviewStatus>('scheduled')

  useEffect(() => {
    if (!formOpen) return
    if (editing) {
      setType(editing.type)
      setScheduledAt(toLocalInputValue(editing.scheduled_at))
      setDuration(String(editing.duration_minutes ?? 60))
      setLocationOrLink(editing.location_or_link ?? '')
      setNotes(editing.notes ?? '')
      setStatus(editing.status)
    } else {
      setType('online')
      setScheduledAt('')
      setDuration('60')
      setLocationOrLink('')
      setNotes('')
      setStatus('scheduled')
    }
  }, [formOpen, editing])

  const saveMutation = useMutation({
    mutationFn: async () => {
      const payload = {
        type,
        scheduled_at: fromLocalInputValue(scheduledAt),
        duration_minutes: Number(duration) || 60,
        location_or_link: locationOrLink.trim() || null,
        notes: notes.trim() || null,
        status,
      }
      if (editing) {
        return updateInterview(editing.id, payload)
      }
      return createInterview({
        tenant_id: tenantId,
        application_id: applicationId,
        ...payload,
      })
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: recruitmentKeys.interviews(applicationId) })
      setFormOpen(false)
      setEditing(null)
      toast({ description: t('interviews.saved') })
    },
    onError: (err: Error) => toast({ variant: 'destructive', description: err.message }),
  })

  function openCreate() {
    setEditing(null)
    setFormOpen(true)
  }

  function openEdit(row: Interview) {
    setEditing(row)
    setFormOpen(true)
  }

  return (
    <div className="space-y-3 border-t pt-4">
      <div className="flex items-center justify-between gap-2">
        <h3 className="font-semibold">{t('interviews.title')}</h3>
        {canEdit && (
          <Button type="button" size="sm" variant="outline" onClick={openCreate}>
            <Plus className="mr-1 h-4 w-4" />
            {t('interviews.new')}
          </Button>
        )}
      </div>

      {isLoading ? (
        <p className="text-xs text-muted-foreground">…</p>
      ) : interviews.length === 0 ? (
        <p className="text-xs text-muted-foreground">{t('interviews.empty')}</p>
      ) : (
        <ul className="space-y-2">
          {interviews.map((iv) => (
            <li
              key={iv.id}
              className="flex items-start justify-between gap-2 rounded border px-2 py-1.5 text-xs"
            >
              <div>
                <p className="font-medium">
                  {t(`interviews.type.${iv.type}`)} · {t(`interviews.status.${iv.status}`)}
                </p>
                <p className="text-muted-foreground">
                  {iv.scheduled_at
                    ? new Date(iv.scheduled_at).toLocaleString()
                    : t('interviews.no_schedule')}
                  {iv.duration_minutes ? ` · ${iv.duration_minutes} min` : ''}
                </p>
                {iv.location_or_link && (
                  <p className="truncate text-muted-foreground">{iv.location_or_link}</p>
                )}
                {iv.notes && <p className="mt-1 whitespace-pre-wrap">{iv.notes}</p>}
              </div>
              {canEdit && (
                <Button type="button" size="icon" variant="ghost" onClick={() => openEdit(iv)}>
                  <Pencil className="h-3.5 w-3.5" />
                </Button>
              )}
            </li>
          ))}
        </ul>
      )}

      <Dialog
        open={formOpen}
        onOpenChange={(v) => {
          setFormOpen(v)
          if (!v) setEditing(null)
        }}
      >
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>
              {editing ? t('interviews.edit') : t('interviews.new')}
            </DialogTitle>
          </DialogHeader>
          <div className="space-y-3 text-sm">
            <div className="space-y-1">
              <Label>{t('interviews.field_type')}</Label>
              <Select value={type} onValueChange={(v) => setType(v as InterviewType)}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {(['phone', 'online', 'onsite'] as const).map((k) => (
                    <SelectItem key={k} value={k}>
                      {t(`interviews.type.${k}`)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-1">
              <Label>{t('interviews.field_when')}</Label>
              <Input
                type="datetime-local"
                value={scheduledAt}
                onChange={(e) => setScheduledAt(e.target.value)}
              />
            </div>
            <div className="space-y-1">
              <Label>{t('interviews.field_duration')}</Label>
              <Input
                type="number"
                min={5}
                value={duration}
                onChange={(e) => setDuration(e.target.value)}
              />
            </div>
            <div className="space-y-1">
              <Label>{t('interviews.field_location')}</Label>
              <Input
                value={locationOrLink}
                onChange={(e) => setLocationOrLink(e.target.value)}
                placeholder={t('interviews.location_placeholder')}
              />
            </div>
            <div className="space-y-1">
              <Label>{t('interviews.field_status')}</Label>
              <Select value={status} onValueChange={(v) => setStatus(v as InterviewStatus)}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {(['scheduled', 'completed', 'cancelled', 'no_show'] as const).map((k) => (
                    <SelectItem key={k} value={k}>
                      {t(`interviews.status.${k}`)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-1">
              <Label>{t('interviews.field_notes')}</Label>
              <Textarea rows={3} value={notes} onChange={(e) => setNotes(e.target.value)} />
            </div>
          </div>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => setFormOpen(false)}>
              {t('drawer.close')}
            </Button>
            <Button
              type="button"
              disabled={saveMutation.isPending}
              onClick={() => saveMutation.mutate()}
            >
              {t('interviews.save')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
