import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useQuery } from '@tanstack/react-query'
import { FileText, Mail, Sparkles, UserPlus } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import {
  Dialog,
  DialogContent,
  DialogDescription,
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
import { usePermission } from '@/hooks/usePermission'
import { useTenant } from '@/contexts/TenantContext'
import { useJobPositions } from '@/features/employees/api/useJobPositions'
import { supabase } from '@/lib/supabase'
import {
  createCvSignedUrl,
  type CvStructuredPayload,
  type HireApplicationResult,
  type JobPostingApplicationRow,
  type PipelineStage,
} from '../api/recruitmentService'
import { recruitmentKeys } from '../api/useRecruitment'
import { ApplicationInterviewsSection } from './ApplicationInterviewsSection'
import { StructureCvDialog } from './StructureCvDialog'

const PUBLIC_PORTAL_BASE =
  (import.meta.env.VITE_PUBLIC_PORTAL_BASE_URL as string | undefined)?.replace(/\/$/, '') || ''

export type HireApplicationParams = {
  applicationId: string
  jobPositionId?: string | null
  startsOn?: string | null
  siteId?: string | null
  departmentId?: string | null
}

interface Props {
  app: JobPostingApplicationRow | null
  stages: PipelineStage[]
  open: boolean
  onOpenChange: (open: boolean) => void
  onMoveStage: (applicationId: string, stageId: string) => Promise<void> | void
  onCommunicateOutcome?: (applicationId: string) => Promise<void> | void
  onHire?: (params: HireApplicationParams) => Promise<HireApplicationResult>
  defaultJobPositionId?: string | null
  defaultSiteId?: string | null
  defaultDepartmentId?: string | null
  canManage: boolean
}

export function ApplicationDetailDrawer({
  app,
  stages,
  open,
  onOpenChange,
  onMoveStage,
  onCommunicateOutcome,
  onHire,
  defaultJobPositionId,
  defaultSiteId,
  defaultDepartmentId,
  canManage,
}: Props) {
  const { t } = useTranslation('recruitment')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const { data: jobPositions = [] } = useJobPositions(true)
  const canInterview = usePermission('recruitment.interview')
  // Mateix scope que api.hire_application: employees.manage al site de l'oferta (o global)
  const canEmployees = usePermission('employees.manage', defaultSiteId ?? null)
  const canEditInterviews = canInterview || canManage
  const [openingCv, setOpeningCv] = useState(false)
  const [confirmOpen, setConfirmOpen] = useState(false)
  const [communicating, setCommunicating] = useState(false)
  const [hireOpen, setHireOpen] = useState(false)
  const [hiring, setHiring] = useState(false)
  const [hireJobPositionId, setHireJobPositionId] = useState('')
  const [hireStartsOn, setHireStartsOn] = useState('')
  const [hiredEmployeeId, setHiredEmployeeId] = useState<string | null>(null)
  const [structureOpen, setStructureOpen] = useState(false)
  const [localStructured, setLocalStructured] = useState<CvStructuredPayload | null>(null)

  useEffect(() => {
    setLocalStructured(null)
  }, [app?.id])

  const { data: aiSettings } = useQuery({
    queryKey: [...recruitmentKeys.all, 'settings-ai', activeTenant?.id],
    enabled: Boolean(activeTenant?.id && canManage),
    queryFn: async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase as any)
        .from('recruitment_settings')
        .select('ai_assist_enabled')
        .eq('tenant_id', activeTenant!.id)
        .maybeSingle()
      if (error) throw error
      return data as { ai_assist_enabled: boolean } | null
    },
  })

  const currentStage = stages.find((s) => s.id === app?.stage_id)
  const isTerminal = Boolean(currentStage?.is_terminal_hire || currentStage?.is_terminal_reject)
  const isOpen = app?.candidate_visible_status === 'open' && !app?.outcome_communicated_at
  const canCommunicate = Boolean(canManage && isOpen && onCommunicateOutcome)
  const alreadyHired = Boolean(app?.hired_employee_id || hiredEmployeeId)
  const rejectedClosed =
    app?.outcome_kind === 'rejected' || app?.outcome_kind === 'withdrawn'
  const canHire = Boolean(
    canManage && canEmployees && onHire && !alreadyHired && !rejectedClosed,
  )
  const canStructureCv = Boolean(
    canManage &&
      aiSettings?.ai_assist_enabled &&
      app?.cv_storage_path &&
      activeTenant?.id,
  )
  const structured = localStructured ?? app?.cv_structured ?? null

  async function handleOpenCv() {
    if (!app?.cv_storage_path) {
      toast({ variant: 'destructive', description: t('drawer.no_cv') })
      return
    }
    setOpeningCv(true)
    try {
      const url = await createCvSignedUrl(app.cv_storage_path, 900)
      window.open(url, '_blank', 'noopener,noreferrer')
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('drawer.cv_error'),
      })
    } finally {
      setOpeningCv(false)
    }
  }

  async function handleConfirmCommunicate() {
    if (!app || !onCommunicateOutcome) return
    setCommunicating(true)
    try {
      await onCommunicateOutcome(app.id)
      setConfirmOpen(false)
      toast({ description: t('drawer.communicate_success') })
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('drawer.communicate_error'),
      })
    } finally {
      setCommunicating(false)
    }
  }

  function openHireDialog() {
    setHireJobPositionId(defaultJobPositionId ?? '')
    setHireStartsOn(new Date().toISOString().slice(0, 10))
    setHireOpen(true)
  }

  async function handleConfirmHire() {
    if (!app || !onHire) return
    setHiring(true)
    try {
      const result = await onHire({
        applicationId: app.id,
        jobPositionId: hireJobPositionId || null,
        startsOn: hireStartsOn || null,
        siteId: defaultSiteId ?? null,
        departmentId: defaultDepartmentId ?? null,
      })
      setHiredEmployeeId(result.employee_id)
      setHireOpen(false)
      toast({ description: t('drawer.hire_success') })
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('drawer.hire_error'),
      })
    } finally {
      setHiring(false)
    }
  }

  const employeeId = app?.hired_employee_id || hiredEmployeeId

  return (
    <>
      <Dialog open={open} onOpenChange={onOpenChange}>
        <DialogContent className="max-w-lg">
          <DialogHeader>
            <DialogTitle>{app?.applicant?.full_name ?? t('drawer.title')}</DialogTitle>
            <DialogDescription className="sr-only">{t('drawer.title')}</DialogDescription>
          </DialogHeader>
          {app && (
            <div className="space-y-4 text-sm">
              <div>
                <p className="text-muted-foreground">{t('drawer.email')}</p>
                <p>{app.applicant?.email}</p>
              </div>
              {app.applicant?.phone && (
                <div>
                  <p className="text-muted-foreground">{t('drawer.phone')}</p>
                  <p>{app.applicant.phone}</p>
                </div>
              )}
              <div className="grid grid-cols-2 gap-3">
                <div>
                  <p className="text-muted-foreground">{t('drawer.source')}</p>
                  <p>{app.source}</p>
                </div>
                <div>
                  <p className="text-muted-foreground">{t('drawer.visible_status')}</p>
                  <p>{app.candidate_visible_status}</p>
                </div>
                <div>
                  <p className="text-muted-foreground">{t('drawer.retention')}</p>
                  <p>
                    {app.retention_preference}
                    {app.retention_months != null ? ` (${app.retention_months}m)` : ''}
                  </p>
                </div>
                <div>
                  <p className="text-muted-foreground">{t('drawer.purge_at')}</p>
                  <p>{new Date(app.purge_at).toLocaleDateString()}</p>
                </div>
              </div>

              <div className="space-y-2">
                <Label>{t('drawer.stage')}</Label>
                <Select
                  value={app.stage_id ?? undefined}
                  disabled={!canManage}
                  onValueChange={(stageId) => void onMoveStage(app.id, stageId)}
                >
                  <SelectTrigger>
                    <SelectValue placeholder={t('drawer.select_stage')} />
                  </SelectTrigger>
                  <SelectContent>
                    {stages.map((s) => (
                      <SelectItem key={s.id} value={s.id}>
                        {s.name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                {isTerminal && isOpen && (
                  <p className="text-xs text-amber-700 dark:text-amber-400">
                    {t('drawer.terminal_note')}
                  </p>
                )}
                {!isOpen && (
                  <p className="text-xs text-muted-foreground">{t('drawer.outcome_done')}</p>
                )}
              </div>

              {employeeId && (
                <Button type="button" variant="outline" className="w-full" asChild>
                  <Link to={`/employees/${employeeId}`}>{t('drawer.open_employee')}</Link>
                </Button>
              )}

              {canHire && (
                <Button
                  type="button"
                  variant="default"
                  className="w-full"
                  onClick={openHireDialog}
                >
                  <UserPlus className="mr-2 h-4 w-4" />
                  {t('drawer.hire')}
                </Button>
              )}

              {canStructureCv && (
                <Button
                  type="button"
                  variant="outline"
                  className="w-full"
                  onClick={() => setStructureOpen(true)}
                >
                  <Sparkles className="mr-2 h-4 w-4" />
                  {structured ? t('drawer.structure_rerun') : t('drawer.structure_cv')}
                </Button>
              )}

              {structured && (
                <div className="rounded-md border p-3 space-y-2 text-xs">
                  <p className="font-medium text-sm">{t('drawer.structure_saved_title')}</p>
                  {structured.skills?.length > 0 && (
                    <div>
                      <p className="text-muted-foreground">{t('drawer.structure_skills')}</p>
                      <p>{structured.skills.join(', ')}</p>
                    </div>
                  )}
                  {structured.experience?.length > 0 && (
                    <div>
                      <p className="text-muted-foreground">{t('drawer.structure_experience')}</p>
                      <pre className="whitespace-pre-wrap font-sans">
                        {JSON.stringify(structured.experience, null, 2)}
                      </pre>
                    </div>
                  )}
                  {structured.education?.length > 0 && (
                    <div>
                      <p className="text-muted-foreground">{t('drawer.structure_education')}</p>
                      <pre className="whitespace-pre-wrap font-sans">
                        {JSON.stringify(structured.education, null, 2)}
                      </pre>
                    </div>
                  )}
                  {structured.languages?.length > 0 && (
                    <div>
                      <p className="text-muted-foreground">{t('drawer.structure_languages')}</p>
                      <pre className="whitespace-pre-wrap font-sans">
                        {JSON.stringify(structured.languages, null, 2)}
                      </pre>
                    </div>
                  )}
                </div>
              )}

              {canCommunicate && (
                <Button
                  type="button"
                  variant="secondary"
                  className="w-full"
                  onClick={() => setConfirmOpen(true)}
                >
                  <Mail className="mr-2 h-4 w-4" />
                  {t('drawer.communicate')}
                </Button>
              )}

              {activeTenant?.id && canEditInterviews && (
                <ApplicationInterviewsSection
                  applicationId={app.id}
                  tenantId={activeTenant.id}
                  canEdit={canEditInterviews}
                />
              )}
            </div>
          )}
          <DialogFooter className="gap-2 sm:justify-between">
            <Button
              type="button"
              variant="outline"
              disabled={!app?.cv_storage_path || openingCv}
              onClick={() => void handleOpenCv()}
            >
              <FileText className="mr-2 h-4 w-4" />
              {t('drawer.open_cv')}
            </Button>
            <Button type="button" variant="secondary" onClick={() => onOpenChange(false)}>
              {t('drawer.close')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={confirmOpen} onOpenChange={setConfirmOpen}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>{t('drawer.communicate_confirm_title')}</DialogTitle>
            <DialogDescription>
              {t('drawer.communicate_confirm_body')}
              {!PUBLIC_PORTAL_BASE ? (
                <span className="mt-2 block text-amber-700 dark:text-amber-400">
                  {t('drawer.communicate_no_portal_url')}
                </span>
              ) : null}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter className="gap-2">
            <Button
              type="button"
              variant="outline"
              disabled={communicating}
              onClick={() => setConfirmOpen(false)}
            >
              {t('drawer.communicate_cancel')}
            </Button>
            <Button
              type="button"
              disabled={communicating}
              onClick={() => void handleConfirmCommunicate()}
            >
              {communicating ? t('drawer.communicate_working') : t('drawer.communicate_confirm')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={hireOpen} onOpenChange={setHireOpen}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>{t('drawer.hire_confirm_title')}</DialogTitle>
            <DialogDescription>{t('drawer.hire_confirm_body')}</DialogDescription>
          </DialogHeader>
          <div className="space-y-3">
            <div className="space-y-2">
              <Label htmlFor="hire-job-position">{t('drawer.hire_job_position')}</Label>
              <Select
                value={hireJobPositionId || '__none__'}
                onValueChange={(v) => setHireJobPositionId(v === '__none__' ? '' : v)}
              >
                <SelectTrigger id="hire-job-position">
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
            <div className="space-y-2">
              <Label htmlFor="hire-starts">{t('drawer.hire_starts_on')}</Label>
              <Input
                id="hire-starts"
                type="date"
                value={hireStartsOn}
                onChange={(e) => setHireStartsOn(e.target.value)}
              />
            </div>
          </div>
          <DialogFooter className="gap-2">
            <Button
              type="button"
              variant="outline"
              disabled={hiring}
              onClick={() => setHireOpen(false)}
            >
              {t('drawer.hire_cancel')}
            </Button>
            <Button type="button" disabled={hiring} onClick={() => void handleConfirmHire()}>
              {hiring ? t('drawer.hire_working') : t('drawer.hire_confirm')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {activeTenant?.id && app && (
        <StructureCvDialog
          open={structureOpen}
          onOpenChange={setStructureOpen}
          tenantId={activeTenant.id}
          applicationId={app.id}
          existing={structured}
          onSaved={(payload) => setLocalStructured(payload)}
        />
      )}
    </>
  )
}
