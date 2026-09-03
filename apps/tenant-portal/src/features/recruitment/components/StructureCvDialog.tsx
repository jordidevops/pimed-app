import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useQueryClient } from '@tanstack/react-query'
import { Sparkles } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import {
  saveApplicationCvStructured,
  structureRecruitmentCv,
  type CvStructuredPayload,
} from '../api/recruitmentService'
import { recruitmentKeys } from '../api/useRecruitment'

type Props = {
  open: boolean
  onOpenChange: (open: boolean) => void
  tenantId: string
  applicationId: string
  existing: CvStructuredPayload | null
  onSaved: (payload: CvStructuredPayload) => void
}

function emptyPayload(): CvStructuredPayload {
  return { skills: [], experience: [], education: [], languages: [] }
}

function toEditableJson(payload: CvStructuredPayload): string {
  return JSON.stringify(payload, null, 2)
}

export function StructureCvDialog({
  open,
  onOpenChange,
  tenantId,
  applicationId,
  existing,
  onSaved,
}: Props) {
  const { t } = useTranslation('recruitment')
  const { toast } = useToast()
  const qc = useQueryClient()
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState(false)
  const [needsReview, setNeedsReview] = useState(false)
  const [reviewReason, setReviewReason] = useState<string | null>(null)
  const [jsonText, setJsonText] = useState('')
  const requestGen = useRef(0)

  useEffect(() => {
    if (!open) return
    const gen = ++requestGen.current
    setNeedsReview(false)
    setReviewReason(null)
    setJsonText(existing ? toEditableJson(existing) : '')
    void runStructure(gen)
    // eslint-disable-next-line react-hooks/exhaustive-deps -- run once per open/application
  }, [open, applicationId])

  async function runStructure(gen: number) {
    setLoading(true)
    setNeedsReview(false)
    setReviewReason(null)
    try {
      const result = await structureRecruitmentCv(tenantId, applicationId)
      if (gen !== requestGen.current) return
      if (result.status === 'needs_human_review') {
        setNeedsReview(true)
        setReviewReason(result.reason)
        if (existing) setJsonText(toEditableJson(existing))
        return
      }
      setJsonText(toEditableJson(result.proposal ?? emptyPayload()))
    } catch (err) {
      if (gen !== requestGen.current) return
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('drawer.structure_cv_error'),
      })
      onOpenChange(false)
    } finally {
      if (gen === requestGen.current) setLoading(false)
    }
  }

  async function handleConfirm() {
    let payload: CvStructuredPayload
    try {
      const parsed = JSON.parse(jsonText) as CvStructuredPayload
      payload = {
        skills: Array.isArray(parsed.skills) ? parsed.skills.map(String) : [],
        experience: Array.isArray(parsed.experience) ? parsed.experience : [],
        education: Array.isArray(parsed.education) ? parsed.education : [],
        languages: Array.isArray(parsed.languages) ? parsed.languages : [],
      }
    } catch {
      toast({ variant: 'destructive', description: t('drawer.structure_cv_error') })
      return
    }
    setSaving(true)
    try {
      const res = await saveApplicationCvStructured(applicationId, payload)
      onSaved(res.cv_structured)
      void qc.invalidateQueries({ queryKey: recruitmentKeys.all })
      toast({ description: t('drawer.structure_cv_saved') })
      onOpenChange(false)
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('drawer.structure_cv_error'),
      })
    } finally {
      setSaving(false)
    }
  }

  const reviewMessage =
    reviewReason === 'not_pdf'
      ? t('drawer.structure_cv_not_pdf')
      : t('drawer.structure_cv_needs_review')

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        if (!next) requestGen.current += 1
        onOpenChange(next)
      }}
    >
      <DialogContent className="max-w-lg max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{t('drawer.structure_cv_title')}</DialogTitle>
          <DialogDescription>{t('drawer.structure_cv_art22')}</DialogDescription>
        </DialogHeader>

        {loading && (
          <p className="text-sm text-muted-foreground">{t('drawer.structure_cv_working')}</p>
        )}

        {!loading && needsReview && (
          <p className="text-sm text-amber-700 dark:text-amber-400">{reviewMessage}</p>
        )}

        {!loading && !needsReview && (
          <div className="space-y-2">
            <Label>{t('drawer.structure_json_hint')}</Label>
            <Textarea
              rows={16}
              className="font-mono text-xs"
              value={jsonText}
              onChange={(e) => setJsonText(e.target.value)}
            />
          </div>
        )}

        <DialogFooter className="gap-2">
          <Button type="button" variant="secondary" onClick={() => onOpenChange(false)}>
            {t('drawer.structure_cv_cancel')}
          </Button>
          {!needsReview && (
            <Button
              type="button"
              disabled={loading || saving || !jsonText.trim()}
              onClick={() => void handleConfirm()}
            >
              <Sparkles className="mr-2 h-4 w-4" />
              {t('drawer.structure_cv_confirm')}
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
