import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Ban, FileText, Loader2, PenLine, Plus } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import { usePermission } from '@/hooks/usePermission'
import { useComplianceRequirementTypes } from '../api/useComplianceCatalog'
import {
  useEmployeeCertifications,
  useGenerateMedicalClearanceDocument,
  useRevokeEmployeeCertification,
  useStartMedicalClearanceSigning,
  useUpsertEmployeeCertification,
  type EmployeeCertification,
} from '../api/useEmployeeCertifications'

export function EmployeeCertificationsSection({ employeeId }: { employeeId: string }) {
  const { t } = useTranslation('employees')
  const { toast } = useToast()

  const canViewCerts = usePermission('compliance.certifications.view')
  const canManageCerts = usePermission('compliance.certifications.manage')
  const canViewMedical = usePermission('compliance.medical_clearance.view')
  const canManageMedical = usePermission('compliance.medical_clearance.manage')

  const canView = canViewCerts || canViewMedical
  const canManageAny = canManageCerts || canManageMedical

  const { data: certs = [], isLoading, error } = useEmployeeCertifications(employeeId, true)
  const { data: types = [] } = useComplianceRequirementTypes()
  const upsert = useUpsertEmployeeCertification()
  const revoke = useRevokeEmployeeCertification()
  const generateDoc = useGenerateMedicalClearanceDocument(employeeId)
  const startSigning = useStartMedicalClearanceSigning(employeeId)

  const [dialogOpen, setDialogOpen] = useState(false)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [typeId, setTypeId] = useState('')
  const [issuer, setIssuer] = useState('')
  const [validFrom, setValidFrom] = useState(() => new Date().toISOString().slice(0, 10))
  const [validUntil, setValidUntil] = useState('')
  const [indefinite, setIndefinite] = useState(false)

  const visibleCerts = useMemo(
    () =>
      certs.filter((c) =>
        c.requirement_category === 'medical' ? canViewMedical : canViewCerts,
      ),
    [certs, canViewCerts, canViewMedical],
  )

  const creatableTypes = useMemo(
    () =>
      types.filter((row) =>
        row.category === 'medical' ? canManageMedical : canManageCerts,
      ),
    [types, canManageCerts, canManageMedical],
  )

  if (!canView) {
    return (
      <p className="text-sm text-muted-foreground">
        {t('employees.certifications.no_permission', 'No tens permís per veure certificacions.')}
      </p>
    )
  }

  if (isLoading) {
    return (
      <div className="flex justify-center py-8">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary" />
      </div>
    )
  }

  if (error) {
    return (
      <p className="text-sm text-red-600">
        {t('employees.certifications.load_failed', "No s'han pogut carregar les certificacions")}
      </p>
    )
  }

  async function handleCreate() {
    if (!typeId) {
      toast({
        variant: 'destructive',
        title: t('employees.certifications.required', 'Selecciona un tipus'),
      })
      return
    }
    try {
      await upsert.mutateAsync({
        employee_id: employeeId,
        requirement_type_id: typeId,
        issuer: issuer || null,
        valid_from: validFrom || null,
        valid_until: indefinite ? null : validUntil || null,
      })
      toast({ title: t('employees.certifications.saved', 'Certificació registrada') })
      setDialogOpen(false)
      setTypeId('')
      setIssuer('')
      setValidUntil('')
      setIndefinite(false)
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('employees.certifications.save_failed', "No s'ha pogut desar"),
        description: err instanceof Error ? err.message : undefined,
      })
    }
  }

  async function handleRevoke(id: string) {
    try {
      await revoke.mutateAsync({ id, employee_id: employeeId, reason: 'revoked_from_ui' })
      toast({ title: t('employees.certifications.revoked', 'Certificació revocada') })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('employees.certifications.revoke_failed', "No s'ha pogut revocar"),
        description: err instanceof Error ? err.message : undefined,
      })
    }
  }

  async function onGenerateDocument(row: EmployeeCertification, force: boolean) {
    setBusyId(row.id)
    try {
      await generateDoc.mutateAsync({ certificationId: row.id, force })
      toast({
        title: t('employees.certifications.doc_generated', 'Document generat'),
        description: t(
          'employees.certifications.doc_generated_hint',
          'Reconeixement mèdic creat al DMS (només aptitud genèrica).',
        ),
      })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('employees.certifications.doc_failed', "No s'ha pogut generar el document"),
        description: err instanceof Error ? err.message : undefined,
      })
    } finally {
      setBusyId(null)
    }
  }

  async function onSendForSigning(row: EmployeeCertification) {
    setBusyId(row.id)
    try {
      await startSigning.mutateAsync(row.id)
      toast({
        title: t('employees.certifications.signing_started', 'Firma iniciada'),
        description: t(
          'employees.certifications.signing_started_hint',
          "S'ha enviat al servei de prevenció / metge.",
        ),
      })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('employees.certifications.signing_failed', "No s'ha pogut iniciar la firma"),
        description: err instanceof Error ? err.message : undefined,
      })
    } finally {
      setBusyId(null)
    }
  }

  function statusLabel(status: string, revoked: boolean) {
    if (revoked) return t('employees.certifications.status.revoked', 'Revocada')
    return t(`employees.certifications.status.${status}`, status)
  }

  return (
    <div className="space-y-4" data-testid="employee-certifications">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-base font-semibold">
            {t('employees.certifications.title', 'Certificacions')}
          </h2>
          <p className="text-sm text-muted-foreground">
            {t(
              'employees.certifications.hint',
              'Compliment legal, tècnic i reconeixements mèdics (segons permisos).',
            )}
          </p>
        </div>
        {canManageAny && creatableTypes.length > 0 ? (
          <Button
            className="gap-2"
            onClick={() => {
              setTypeId(creatableTypes[0]?.id ?? '')
              setDialogOpen(true)
            }}
          >
            <Plus className="h-4 w-4" />
            {t('employees.certifications.add', 'Afegir')}
          </Button>
        ) : null}
      </div>

      <div className="overflow-x-auto rounded-xl border">
        <table className="min-w-full text-sm">
          <thead className="bg-muted/50 text-left">
            <tr>
              <th className="px-3 py-2 font-medium">{t('employees.certifications.col_type', 'Tipus')}</th>
              <th className="px-3 py-2 font-medium">{t('employees.certifications.col_status', 'Estat')}</th>
              <th className="px-3 py-2 font-medium">{t('employees.certifications.col_from', 'Des de')}</th>
              <th className="px-3 py-2 font-medium">{t('employees.certifications.col_until', 'Fins')}</th>
              <th className="px-3 py-2 font-medium">{t('employees.certifications.col_issuer', 'Emissor')}</th>
              <th className="px-3 py-2 font-medium" />
            </tr>
          </thead>
          <tbody>
            {visibleCerts.length === 0 ? (
              <tr>
                <td colSpan={6} className="px-3 py-6 text-center text-muted-foreground">
                  {t('employees.certifications.empty', 'Cap certificació registrada')}
                </td>
              </tr>
            ) : (
              visibleCerts.map((row) => {
                const canRevoke =
                  !row.revoked_at &&
                  (row.requirement_category === 'medical' ? canManageMedical : canManageCerts)
                const isMedical = row.requirement_category === 'medical'
                const canMedicalActions = isMedical && canManageMedical && !row.revoked_at
                const isBusy = busyId === row.id
                return (
                  <tr key={row.id} className="border-t">
                    <td className="px-3 py-2">
                      <div className="font-medium">{row.requirement_name}</div>
                      <div className="text-xs text-muted-foreground font-mono">{row.requirement_code}</div>
                      {row.document_id ? (
                        <Link
                          to={`/documents/${row.document_id}`}
                          className="mt-1 text-xs text-primary hover:underline inline-flex items-center gap-1"
                        >
                          <FileText className="h-3 w-3" />
                          {t('employees.certifications.open_document', 'Obrir document')}
                        </Link>
                      ) : null}
                      {row.signing_submission_id ? (
                        <Link
                          to={`/documents/signing/${row.signing_submission_id}`}
                          className="mt-1 text-xs text-primary hover:underline inline-flex items-center gap-1"
                        >
                          <PenLine className="h-3 w-3" />
                          {t('employees.certifications.open_signing', 'Obrir firma')}
                        </Link>
                      ) : null}
                    </td>
                    <td className="px-3 py-2">
                      {statusLabel(row.computed_status, !!row.revoked_at)}
                    </td>
                    <td className="px-3 py-2">{row.valid_from}</td>
                    <td className="px-3 py-2">{row.valid_until ?? '—'}</td>
                    <td className="px-3 py-2">{row.issuer ?? '—'}</td>
                    <td className="px-3 py-2 text-right">
                      <div className="flex flex-wrap justify-end gap-1">
                        {canMedicalActions ? (
                          <>
                            <Button
                              variant="outline"
                              size="sm"
                              className="gap-1"
                              disabled={isBusy || generateDoc.isPending}
                              onClick={() => void onGenerateDocument(row, !!row.document_id)}
                            >
                              {isBusy && generateDoc.isPending ? (
                                <Loader2 className="h-3.5 w-3.5 animate-spin" />
                              ) : (
                                <FileText className="h-3.5 w-3.5" />
                              )}
                              {row.document_id
                                ? t('employees.certifications.regen_doc', 'Regenerar')
                                : t('employees.certifications.gen_doc', 'Generar doc')}
                            </Button>
                            <Button
                              variant="default"
                              size="sm"
                              className="gap-1"
                              disabled={isBusy || startSigning.isPending}
                              onClick={() => void onSendForSigning(row)}
                            >
                              {isBusy && startSigning.isPending ? (
                                <Loader2 className="h-3.5 w-3.5 animate-spin" />
                              ) : (
                                <PenLine className="h-3.5 w-3.5" />
                              )}
                              {row.signing_submission_id
                                ? t('employees.certifications.resign', 'Reenviar firma')
                                : t('employees.certifications.send_signing', 'Enviar a firmar')}
                            </Button>
                          </>
                        ) : null}
                        {canRevoke ? (
                          <Button
                            variant="ghost"
                            size="sm"
                            className="gap-1 text-red-600"
                            disabled={revoke.isPending}
                            onClick={() => void handleRevoke(row.id)}
                          >
                            <Ban className="h-3.5 w-3.5" />
                            {t('employees.certifications.revoke', 'Revocar')}
                          </Button>
                        ) : null}
                      </div>
                    </td>
                  </tr>
                )
              })
            )}
          </tbody>
        </table>
      </div>

      <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>{t('employees.certifications.add', 'Afegir')}</DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            <div>
              <label className="text-sm font-medium">{t('employees.certifications.col_type', 'Tipus')}</label>
              <select
                className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm"
                value={typeId}
                onChange={(e) => setTypeId(e.target.value)}
              >
                {creatableTypes.map((row) => (
                  <option key={row.id} value={row.id}>
                    {row.code} — {row.name}
                  </option>
                ))}
              </select>
            </div>
            <div>
              <label className="text-sm font-medium">{t('employees.certifications.col_issuer', 'Emissor')}</label>
              <Input value={issuer} onChange={(e) => setIssuer(e.target.value)} />
            </div>
            <div>
              <label className="text-sm font-medium">{t('employees.certifications.col_from', 'Des de')}</label>
              <Input type="date" value={validFrom} onChange={(e) => setValidFrom(e.target.value)} />
            </div>
            <div className="flex items-center gap-2">
              <input
                id="cert-indefinite"
                type="checkbox"
                checked={indefinite}
                onChange={(e) => setIndefinite(e.target.checked)}
              />
              <label htmlFor="cert-indefinite" className="text-sm">
                {t('employees.certifications.indefinite', 'Sense caducitat')}
              </label>
            </div>
            {!indefinite ? (
              <div>
                <label className="text-sm font-medium">{t('employees.certifications.col_until', 'Fins')}</label>
                <Input type="date" value={validUntil} onChange={(e) => setValidUntil(e.target.value)} />
              </div>
            ) : null}
            <Button className="w-full" disabled={upsert.isPending} onClick={() => void handleCreate()}>
              {upsert.isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : t('employees.certifications.save', 'Desar')}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  )
}
