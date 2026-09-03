import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { AlertCircle, ExternalLink, Loader2, PenLine } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { useAuth } from '@/contexts/AuthContext'
import { useTenant } from '@/contexts/TenantContext'
import { useSigningConfig } from '@/features/signing/api/useSigningConfig'
import { useSigningSubmission } from '@/features/signing/api/useSigningSubmission'
import { SIGNING_STATUS_CLASSES } from '@/features/signing/signingStatusColors'
import type { MonthlyReportExport, MonthlyReportRow } from '../../api/monthlyReportService'
import { useMonthlyReportSigning } from '../../api/useMonthlyReportSigning'
import { useMonthlyCloseSettings } from '../../api/useMonthlyCloseSettings'
import { useMonthlyCloseValidation } from '../../api/useMonthlyCloseValidation'
import { formatMonthlyCloseIssue } from '../../api/monthlyCloseIssueLabels'
import { resolveEmployeeSignerLink } from '../../api/monthlyReportSigningUtils'

interface MonthlyReportSigningSectionProps {
  employeeId: string
  year: number
  month: number
  siteId?: string | null
  reportStatus: MonthlyReportRow | null
  exportData: MonthlyReportExport
  variant: 'employee' | 'manager'
  employeeEmail?: string | null
}

export function MonthlyReportSigningSection({
  employeeId,
  year,
  month,
  siteId,
  reportStatus,
  exportData,
  variant,
  employeeEmail,
}: MonthlyReportSigningSectionProps) {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const { user } = useAuth()
  const { selectedTenantId, activeRole } = useTenant()
  const isManager = activeRole === 'owner' || activeRole === 'manager'
  const { settings: closeSettings } = useMonthlyCloseSettings(siteId)

  const { data: signingConfig } = useSigningConfig(selectedTenantId ?? undefined)
  const signingMutation = useMonthlyReportSigning(employeeId, year, month)

  const storedStatus = reportStatus?.status ?? 'draft'
  const submissionId = reportStatus?.signing_submission_id ?? null
  const { data: submission } = useSigningSubmission(submissionId ?? undefined)

  const signingEnabled = signingConfig?.feature_enabled && signingConfig?.effective_is_active

  const needsCloseValidation =
    variant === 'manager' &&
    isManager &&
    storedStatus === 'manager_approved' &&
    !submissionId

  const { data: closeValidation, isLoading: closeValidationLoading } = useMonthlyCloseValidation(
    employeeId,
    year,
    month,
    needsCloseValidation,
  )

  const closable = closeValidation?.closable ?? false

  const canStartSigning =
    variant === 'manager' &&
    isManager &&
    storedStatus === 'manager_approved' &&
    !submissionId &&
    signingEnabled &&
    !!user?.id &&
    !!selectedTenantId &&
    closable &&
    !closeValidationLoading

  const signingStatus = submission?.status ?? null
  const employeeSignUrl = resolveEmployeeSignerLink(submission, user?.email)

  function renderSigningBlockers() {
    if (!needsCloseValidation || closeValidationLoading) {
      return closeValidationLoading ? (
        <div className="flex items-center gap-2 text-xs text-amber-800">
          <Loader2 className="h-3.5 w-3.5 animate-spin" />
          {t('monthly_close.loading', 'Comprovant si el mes es pot tancar…')}
        </div>
      ) : null
    }

    if (!closeValidation || closeValidation.blockers.length === 0) return null

    return (
      <div className="space-y-1">
        <p className="flex items-center gap-1.5 text-xs font-semibold text-destructive">
          <AlertCircle className="h-3.5 w-3.5 shrink-0" />
          {t('monthly_report.signing_blockers_title', 'Resol els bloquejos abans d’iniciar la signatura')}
        </p>
        <ul className="list-disc space-y-0.5 pl-5 text-xs text-destructive/90">
          {closeValidation.blockers.map((issue, i) => (
            <li key={`${issue.code}-${i}`}>{formatMonthlyCloseIssue(issue, t)}</li>
          ))}
        </ul>
      </div>
    )
  }

  async function handleStartSigning() {
    if (!selectedTenantId || !user?.id) return

    if (needsCloseValidation && !closable) {
      toast({
        variant: 'destructive',
        title: t('monthly_report.signing_error', 'No s’ha pogut iniciar la signatura'),
        description: t('monthly_close.not_closable', 'Resol els bloquejos abans de tancar el mes.'),
      })
      return
    }

    try {
      const result = await signingMutation.mutateAsync({
        tenantId: selectedTenantId,
        userId: user.id,
        exportData,
        contentHash: reportStatus?.content_hash,
        employeeEmail,
        managerEmail: user.email,
        managerName:
          (user.user_metadata?.full_name as string | undefined) ??
          (user.user_metadata?.name as string | undefined) ??
          null,
      })

      const firstLink = result.signer_links?.[0]?.signing_url ?? result.signing_url
      toast({
        title: t('monthly_report.signing_started', 'Signatura iniciada'),
        description: t('monthly_report.signing_started_desc', {
          defaultValue: "S'han enviat les sol·licituds de signatura a l'empleat i el responsable.",
        }),
      })
      if (firstLink) {
        window.open(firstLink, '_blank', 'noopener,noreferrer')
      }
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('monthly_report.signing_error', 'No s’ha pogut iniciar la signatura'),
        description: err instanceof Error ? err.message : String(err),
      })
    }
  }

  function openEmployeeSignUrl() {
    if (!employeeSignUrl) return
    window.open(employeeSignUrl, '_blank', 'noopener,noreferrer')
  }

  if (variant === 'employee') {
    if (storedStatus === 'signed') {
      return (
        <div className="rounded-lg border border-violet-200 bg-violet-50/50 px-3 py-2 text-sm text-violet-900">
          {t('monthly_report.signing_done', 'Registre mensual signat digitalment.')}
          {reportStatus?.document_id && (
            <Link
              to={`/documents/${reportStatus.document_id}`}
              className="ml-2 inline-flex items-center gap-1 underline"
            >
              {t('monthly_report.view_document', 'Veure document')}
              <ExternalLink className="h-3.5 w-3.5" />
            </Link>
          )}
        </div>
      )
    }

    if (submissionId) {
      return (
        <div className="space-y-2 rounded-lg border bg-muted/20 px-3 py-3">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div className="space-y-0.5">
              <p className="text-sm font-medium">
                {t('monthly_report.signing_in_progress', 'Signatura en curs')}
              </p>
              {signingStatus && (
                <span
                  className={`inline-flex rounded-md px-2 py-0.5 text-xs font-medium ${SIGNING_STATUS_CLASSES[signingStatus as keyof typeof SIGNING_STATUS_CLASSES] ?? ''}`}
                >
                  {signingStatus}
                </span>
              )}
            </div>
            <Button type="button" variant="outline" size="sm" asChild>
              <Link to={`/signing/submissions/${submissionId}`}>
                <ExternalLink className="mr-1.5 h-4 w-4" />
                {t('monthly_report.signing_track', 'Seguiment signatura')}
              </Link>
            </Button>
          </div>
          {employeeSignUrl ? (
            <Button type="button" size="sm" onClick={openEmployeeSignUrl}>
              <PenLine className="mr-1.5 h-4 w-4" />
              {t('monthly_employee.sign_my_record', 'Signar el meu registre')}
            </Button>
          ) : (
            <p className="text-xs text-muted-foreground">
              {t(
                'monthly_employee.sign_waiting_turn',
                'Quan sigui el teu torn, apareixerà l’enllaç de signatura aquí.',
              )}
            </p>
          )}
        </div>
      )
    }

    if (storedStatus === 'manager_approved' && closeSettings.requireDigitalSignature) {
      return (
        <p className="text-xs text-muted-foreground">
          {t(
            'monthly_employee.signing_waiting_manager_start',
            'El mes està tancat per nòmina. El gestor iniciarà la signatura digital si cal.',
          )}
        </p>
      )
    }

    return null
  }

  if (!signingEnabled && storedStatus !== 'signed' && !submissionId) {
    if (storedStatus === 'manager_approved' && closeSettings.requireDigitalSignature) {
      return (
        <div className="rounded-lg border border-amber-200 bg-amber-50/80 px-3 py-2 text-sm text-amber-900">
          {t(
            'monthly_report.signing_required_disabled',
            'Activa el mòdul de signatures a la configuració de l’organització.',
          )}
        </div>
      )
    }
    return (
      <p className="text-xs text-muted-foreground">
        {t(
          'monthly_report.signing_disabled',
          'La signatura digital no està activa per a aquesta organització.',
        )}
      </p>
    )
  }

  if (storedStatus === 'signed') {
    return (
      <div className="rounded-lg border border-violet-200 bg-violet-50/50 px-3 py-2 text-sm text-violet-900">
        {t('monthly_report.signing_done', 'Registre mensual signat digitalment.')}
        {reportStatus?.document_id && (
          <Link
            to={`/documents/${reportStatus.document_id}`}
            className="ml-2 inline-flex items-center gap-1 underline"
          >
            {t('monthly_report.view_document', 'Veure document')}
            <ExternalLink className="h-3.5 w-3.5" />
          </Link>
        )}
      </div>
    )
  }

  if (submissionId) {
    return (
      <div className="flex flex-wrap items-center justify-between gap-3 rounded-lg border bg-muted/20 px-3 py-2">
        <div className="space-y-0.5">
          <p className="text-sm font-medium">
            {t('monthly_report.signing_in_progress', 'Signatura en curs')}
          </p>
          {signingStatus && (
            <span
              className={`inline-flex rounded-md px-2 py-0.5 text-xs font-medium ${SIGNING_STATUS_CLASSES[signingStatus as keyof typeof SIGNING_STATUS_CLASSES] ?? ''}`}
            >
              {signingStatus}
            </span>
          )}
        </div>
        <Button type="button" variant="outline" size="sm" asChild>
          <Link to={`/signing/submissions/${submissionId}`}>
            <ExternalLink className="mr-1.5 h-4 w-4" />
            {t('monthly_report.signing_track', 'Seguiment signatura')}
          </Link>
        </Button>
      </div>
    )
  }

  if (storedStatus === 'manager_approved' && closeSettings.requireDigitalSignature && !submissionId) {
    return (
      <div className="space-y-2 rounded-lg border border-amber-200 bg-amber-50/80 px-3 py-2">
        <p className="text-sm font-medium text-amber-900">
          {t(
            'monthly_report.signing_required',
            'Signatura digital obligatòria per completar el tancament mensual.',
          )}
        </p>
        {renderSigningBlockers()}
        {canStartSigning ? (
          <Button
            type="button"
            size="sm"
            disabled={signingMutation.isPending}
            onClick={() => void handleStartSigning()}
          >
            {signingMutation.isPending ? (
              <Loader2 className="mr-1.5 h-4 w-4 animate-spin" />
            ) : (
              <PenLine className="mr-1.5 h-4 w-4" />
            )}
            {t('monthly_report.signing_start', 'Iniciar signatura digital')}
          </Button>
        ) : signingEnabled ? (
          <p className="text-xs text-amber-800">
            {needsCloseValidation && !closable && !closeValidationLoading
              ? t('monthly_close.not_closable', 'Resol els bloquejos abans de tancar el mes.')
              : t(
                  'monthly_report.signing_required_disabled',
                  'Activa el mòdul de signatures a la configuració de l’organització.',
                )}
          </p>
        ) : (
          <p className="text-xs text-amber-800">
            {t(
              'monthly_report.signing_required_disabled',
              'Activa el mòdul de signatures a la configuració de l’organització.',
            )}
          </p>
        )}
      </div>
    )
  }

  if (!canStartSigning) {
    if (variant === 'manager' && storedStatus === 'manager_approved') {
      return (
        <div className="space-y-2">
          {renderSigningBlockers()}
          <p className="text-xs text-muted-foreground">
            {t(
              'monthly_report.signing_waiting_manager',
              'Activa la signatura digital després d’aprovar el mes.',
            )}
          </p>
        </div>
      )
    }
    return null
  }

  return (
    <div className="space-y-2 rounded-lg border border-dashed px-3 py-2">
      {renderSigningBlockers()}
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="text-sm text-muted-foreground">
          {t(
            'monthly_report.signing_hint',
            'Genera el document oficial i envia la signatura a l’empleat i el responsable (seqüencial).',
          )}
        </p>
        <Button
          type="button"
          size="sm"
          disabled={signingMutation.isPending}
          onClick={() => void handleStartSigning()}
        >
          {signingMutation.isPending ? (
            <Loader2 className="mr-1.5 h-4 w-4 animate-spin" />
          ) : (
            <PenLine className="mr-1.5 h-4 w-4" />
          )}
          {t('monthly_report.signing_start', 'Iniciar signatura digital')}
        </Button>
      </div>
    </div>
  )
}
