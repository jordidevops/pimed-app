import { useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { ChevronRight, Plus, X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Badge } from '@/components/ui/badge'
import { RichTextEditor } from '@/components/ui/RichTextEditor'
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
import { useTenant } from '@/contexts/TenantContext'
import { useToast } from '@/hooks/use-toast'
import { useJobPositions } from '@/features/employees/api/useJobPositions'
import { createJobPosting, slugifyTitle, type JobPostingSummary } from '../api/recruitmentService'
import { recruitmentKeys, useJobPostingSummaries } from '../api/useRecruitment'
import { captureStatusBadgeClass, getCaptureStatus } from '../utils/captureStatus'

const CHECKLIST_KEY = 'recruitment-postings-checklist-dismissed'

export function JobPostingsPage() {
  const { t } = useTranslation('recruitment')
  const navigate = useNavigate()
  const { activeTenant, tenantsLoading } = useTenant()
  const { data: postings = [], isLoading } = useJobPostingSummaries()
  const { data: jobPositions = [] } = useJobPositions(true)
  const { toast } = useToast()
  const qc = useQueryClient()
  const [open, setOpen] = useState(false)
  const [title, setTitle] = useState('')
  const [description, setDescription] = useState('')
  const [jobPositionId, setJobPositionId] = useState('')
  const [checklistDismissed, setChecklistDismissed] = useState(true)

  useEffect(() => {
    try {
      setChecklistDismissed(localStorage.getItem(CHECKLIST_KEY) === '1')
    } catch {
      setChecklistDismissed(false)
    }
  }, [])

  const createMutation = useMutation({
    mutationFn: createJobPosting,
    onSuccess: (posting) => {
      void qc.invalidateQueries({ queryKey: recruitmentKeys.all })
      setOpen(false)
      setTitle('')
      setDescription('')
      setJobPositionId('')
      navigate(`/recruitment/postings/${posting.id}?tab=publish`)
    },
    onError: (err: Error) => {
      toast({ variant: 'destructive', description: err.message })
    },
  })

  const liveCount = postings.filter((p) => getCaptureStatus(p, p.public_site_count) === 'live').length
  const showHowBanner = postings.length > 0 && liveCount === 0
  const showChecklist = !checklistDismissed && postings.length === 0

  function dismissChecklist() {
    try {
      localStorage.setItem(CHECKLIST_KEY, '1')
    } catch {
      /* ignore */
    }
    setChecklistDismissed(true)
  }

  function captureLabel(p: JobPostingSummary) {
    const status = getCaptureStatus(p, p.public_site_count)
    return t(`capture.${status}`)
  }

  if (tenantsLoading || isLoading) {
    return <div className="flex h-48 items-center justify-center text-muted-foreground">…</div>
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-lg font-semibold">{t('hub.tab_postings')}</h2>
          <p className="text-sm text-muted-foreground">{t('postings.subtitle')}</p>
        </div>
        <Button onClick={() => setOpen(true)}>
          <Plus className="mr-2 h-4 w-4" />
          {t('postings.create')}
        </Button>
      </div>

      {showHowBanner && (
        <div className="rounded-xl border border-amber-200/80 bg-amber-50/80 px-4 py-3 text-sm dark:border-amber-900 dark:bg-amber-950/30">
          <p className="font-medium">{t('postings.how_title')}</p>
          <p className="mt-1 text-muted-foreground">{t('postings.how_body')}</p>
        </div>
      )}

      {showChecklist && (
        <div className="relative rounded-2xl border border-dashed px-5 py-5">
          <Button
            type="button"
            variant="ghost"
            size="icon"
            className="absolute right-2 top-2 h-8 w-8"
            onClick={dismissChecklist}
            aria-label={t('postings.dismiss_checklist')}
          >
            <X className="h-4 w-4" />
          </Button>
          <p className="font-medium">{t('postings.checklist_title')}</p>
          <ol className="mt-3 list-decimal space-y-1.5 pl-5 text-sm text-muted-foreground">
            <li>{t('postings.checklist_1')}</li>
            <li>{t('postings.checklist_2')}</li>
            <li>{t('postings.checklist_3')}</li>
            <li>{t('postings.checklist_4')}</li>
          </ol>
        </div>
      )}

      {postings.length === 0 ? (
        <div className="flex flex-col items-center rounded-2xl border border-dashed px-6 py-14 text-center">
          <p className="font-medium">{t('postings.empty_title')}</p>
          <p className="mt-1 max-w-md text-sm text-muted-foreground">{t('postings.empty')}</p>
          <Button className="mt-4" onClick={() => setOpen(true)}>
            <Plus className="mr-2 h-4 w-4" />
            {t('postings.create')}
          </Button>
        </div>
      ) : (
        <div className="overflow-hidden rounded-xl border">
          <ul className="divide-y">
            {postings.map((p) => {
              const capture = getCaptureStatus(p, p.public_site_count)
              const positionName = jobPositions.find((jp) => jp.id === p.job_position_id)?.name
              return (
                <li key={p.id}>
                  <Link
                    to={`/recruitment/postings/${p.id}`}
                    className="flex cursor-pointer items-center gap-3 px-4 py-3 transition-colors hover:bg-muted/40"
                  >
                    <div className="min-w-0 flex-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <span className="font-medium">{p.title}</span>
                        <Badge
                          variant="outline"
                          className={`font-normal ${captureStatusBadgeClass(capture)}`}
                        >
                          {captureLabel(p)}
                        </Badge>
                      </div>
                      <p className="mt-0.5 text-xs text-muted-foreground">
                        {t('postings.meta', {
                          applications: p.application_count,
                          sites: p.public_site_count,
                          position: positionName || t('form.no_job_position'),
                        })}
                      </p>
                    </div>
                    <span className="inline-flex items-center gap-1 text-sm text-primary">
                      {t('postings.open')}
                      <ChevronRight className="h-4 w-4" />
                    </span>
                  </Link>
                </li>
              )
            })}
          </ul>
        </div>
      )}

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t('postings.create')}</DialogTitle>
          </DialogHeader>
          <div className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="rec-title">{t('form.title')}</Label>
              <Input id="rec-title" value={title} onChange={(e) => setTitle(e.target.value)} />
            </div>
            <div className="space-y-2">
              <Label>{t('form.description')}</Label>
              <RichTextEditor
                value={description}
                onChange={setDescription}
                placeholder={t('form.description_placeholder')}
              />
              <p className="text-xs text-muted-foreground">{t('form.description_hint')}</p>
            </div>
            <div className="space-y-2">
              <Label>{t('form.job_position')}</Label>
              <Select
                value={jobPositionId || '__none__'}
                onValueChange={(v) => setJobPositionId(v === '__none__' ? '' : v)}
              >
                <SelectTrigger>
                  <SelectValue placeholder={t('form.no_job_position')} />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="__none__">{t('form.no_job_position')}</SelectItem>
                  {jobPositions.map((p) => (
                    <SelectItem key={p.id!} value={p.id!}>
                      {p.name}
                      {p.code ? ` (${p.code})` : ''}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <p className="text-xs text-muted-foreground">
              {t('form.slug')}: {slugifyTitle(title || 'oferta')}
            </p>
          </div>
          <DialogFooter>
            <Button
              disabled={!title.trim() || !activeTenant?.id || createMutation.isPending}
              onClick={() =>
                createMutation.mutate({
                  tenant_id: activeTenant!.id,
                  title,
                  description:
                    description.trim() && description !== '<p></p>' ? description : null,
                  job_position_id: jobPositionId || null,
                })
              }
            >
              {t('form.save')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
