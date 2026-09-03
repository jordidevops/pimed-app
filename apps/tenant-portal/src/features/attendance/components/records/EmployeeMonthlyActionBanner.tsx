import { useTranslation } from 'react-i18next'
import { AlertCircle, CheckCircle2, PenLine, ShieldCheck } from 'lucide-react'
import type { MonthlyReportStatus } from '../../api/monthlyReportService'
import { useMonthlyCloseSettings } from '../../api/useMonthlyCloseSettings'
import { formatMonthlyCloseIssue } from '../../api/monthlyCloseIssueLabels'
import type { MonthlyCloseIssue } from '../../api/monthlyCloseValidationService'

interface EmployeeMonthlyActionBannerProps {
  status: Exclude<MonthlyReportStatus, null>
  siteId?: string | null
  hasSigningSubmission: boolean
  employeeSignUrl?: string | null
  confirmable?: boolean
  confirmBlockers?: MonthlyCloseIssue[]
  confirmValidationLoading?: boolean
}

export function EmployeeMonthlyActionBanner({
  status,
  siteId,
  hasSigningSubmission,
  employeeSignUrl,
  confirmable = true,
  confirmBlockers = [],
  confirmValidationLoading = false,
}: EmployeeMonthlyActionBannerProps) {
  const { t } = useTranslation('attendance')
  const { settings } = useMonthlyCloseSettings(siteId)

  if (status === 'signed' || status === 'archived') {
    return (
      <div className="flex items-start gap-2 rounded-lg border border-violet-200 bg-violet-50/80 px-3 py-2.5 text-sm text-violet-900">
        <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0" />
        <p>{t('monthly_employee.status_signed', 'Registre mensual signat.')}</p>
      </div>
    )
  }

  if (hasSigningSubmission && employeeSignUrl) {
    return (
      <div className="flex items-start gap-2 rounded-lg border border-indigo-200 bg-indigo-50/80 px-3 py-2.5 text-sm text-indigo-900">
        <PenLine className="mt-0.5 h-4 w-4 shrink-0" />
        <p>
          {t(
            'monthly_employee.action_sign',
            'Tens una signatura digital pendent. Fes clic a «Signar el meu registre» a sota.',
          )}
        </p>
      </div>
    )
  }

  if (hasSigningSubmission) {
    return (
      <div className="flex items-start gap-2 rounded-lg border border-sky-200 bg-sky-50/80 px-3 py-2.5 text-sm text-sky-900">
        <PenLine className="mt-0.5 h-4 w-4 shrink-0" />
        <p>
          {t(
            'monthly_employee.signing_in_progress',
            'Signatura digital en curs. Revisa l’estat a la secció de signatura.',
          )}
        </p>
      </div>
    )
  }

  if (status === 'manager_approved') {
    return (
      <div className="flex items-start gap-2 rounded-lg border border-emerald-200 bg-emerald-50/80 px-3 py-2.5 text-sm text-emerald-900">
        <ShieldCheck className="mt-0.5 h-4 w-4 shrink-0" />
        <p>
          {settings.signatureIsEmployeeApproval && (settings.requireDigitalSignature || hasSigningSubmission)
            ? t(
                'monthly_employee.status_closed_sign_as_confirm',
                'El mes està tancat per nòmina. Signa el document per confirmar el registre.',
              )
            : settings.requireDigitalSignature
            ? t(
                'monthly_employee.status_closed_sign_pending',
                'El mes està tancat per nòmina. Pendent de signatura digital si el gestor l’ha iniciat.',
              )
            : t(
                'monthly_employee.status_closed',
                'El mes està tancat per nòmina. No cal cap acció addicional.',
              )}
        </p>
      </div>
    )
  }

  if (status === 'employee_confirmed') {
    return (
      <div className="flex items-start gap-2 rounded-lg border border-sky-200 bg-sky-50/80 px-3 py-2.5 text-sm text-sky-900">
        <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0" />
        <p>
          {t(
            'monthly_employee.status_confirmed',
            'Has confirmat el registre. El gestor el revisarà i tancarà per nòmina.',
          )}
        </p>
      </div>
    )
  }

  if (status === 'draft') {
    if (settings.signatureIsEmployeeApproval) {
      return (
        <div className="flex items-start gap-2 rounded-lg border border-indigo-200 bg-indigo-50/80 px-3 py-2.5 text-sm text-indigo-900">
          <PenLine className="mt-0.5 h-4 w-4 shrink-0" />
          <p>
            {settings.requireDigitalSignature
              ? t(
                  'monthly_employee.action_confirm_via_signature_required',
                  'No cal confirmar el registre manualment. El gestor tancarà el mes i la teva signatura digital comptarà com a confirmació.',
                )
              : t(
                  'monthly_employee.action_confirm_via_signature_optional',
                  'No cal confirmar el registre manualment. Quan el gestor tanqui el mes, la teva signatura del document comptarà com a confirmació.',
                )}
          </p>
        </div>
      )
    }

    if (!confirmValidationLoading && !confirmable && confirmBlockers.length > 0) {
      return (
        <div className="space-y-1.5 rounded-lg border border-amber-200 bg-amber-50/80 px-3 py-2.5 text-sm text-amber-900">
          <div className="flex items-start gap-2">
            <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />
            <p>
              {t(
                'monthly_employee.not_confirmable_banner',
                'Encara no pots confirmar el registre d’aquest mes.',
              )}
            </p>
          </div>
          <ul className="list-disc space-y-0.5 pl-9 text-xs">
            {confirmBlockers.map((issue, i) => (
              <li key={`${issue.code}-${i}`}>{formatMonthlyCloseIssue(issue, t)}</li>
            ))}
          </ul>
        </div>
      )
    }

    return (
      <div className="flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50/80 px-3 py-2.5 text-sm text-amber-900">
        <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />
        <p>
          {settings.employeeConfirmRequired
            ? t(
                'monthly_employee.action_confirm_required',
                'Revisa el registre del mes i confirma’l quan estigui correcte.',
              )
            : t(
                'monthly_employee.action_confirm_optional',
                'Pots confirmar el registre del mes per facilitar la revisió de nòmina.',
              )}
        </p>
      </div>
    )
  }

  return null
}
