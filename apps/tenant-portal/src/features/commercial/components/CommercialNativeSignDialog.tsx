import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Loader2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { generateClientOpId } from '@/features/attendance/api/clientOpId'
import { SignaturePad } from '@/features/signing/components/SignaturePad'
import {
  callSignDocumentRouter,
  callStampPdfSignatures,
} from '@/features/signing/api/signingService'
import { usePdfConverterConfig } from '@/features/signing/api/usePdfConverterConfig'
import { nativeSignerRoleLabel } from '@/features/signing/utils/signerRoleLabel'
import {
  acceptCommercialDocument,
  createCommercialDecisionRequest,
  getCommercialDocumentDetail,
  registerCommercialSigningIntent,
  rejectCommercialDocument,
  renderCommercialDocumentPdf,
  signCommercialDeliveryNote,
} from '../api/commercialFlowService'
import { defaultDecisionExpiresAt } from '../utils/commercialDecisionSend'
import {
  buildCommercialNativeSignaturePayload,
  commercialSignerRoleForAction,
  isAlreadyAppliedCommercialSigningError,
  type CommercialNativeSignAction,
} from '../utils/commercialNativeSign'
import { docTypeLabel, partyDisplayName } from '../utils/commercialDocumentModel'

interface CommercialNativeSignDialogProps {
  documentId: string
  action: CommercialNativeSignAction
  open: boolean
  onClose: () => void
  onCompleted: (kind: 'signed' | 'remote_sent') => void
}

type Step = 'choose' | 'preparing' | 'pad' | 'remote' | 'error'

export function CommercialNativeSignDialog({
  documentId,
  action,
  open,
  onClose,
  onCompleted,
}: CommercialNativeSignDialogProps) {
  const { t } = useTranslation('projects')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const { data: pdfConfig } = usePdfConverterConfig()
  const nativeEnabled = pdfConfig?.native_signing_enabled === true

  const [step, setStep] = useState<Step>('choose')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [signerName, setSignerName] = useState('')
  const [signerEmail, setSignerEmail] = useState('')
  const [rejectReason, setRejectReason] = useState('')
  const [sessionId, setSessionId] = useState<string | null>(null)
  const [submissionId, setSubmissionId] = useState<string | null>(null)
  const [clientOpId, setClientOpId] = useState<string | null>(null)
  const [pdfPreviewUrl, setPdfPreviewUrl] = useState<string | null>(null)

  useEffect(() => {
    if (!open) return
    setStep('choose')
    setError(null)
    setBusy(false)
    setSessionId(null)
    setSubmissionId(null)
    setClientOpId(null)
    setPdfPreviewUrl(null)
    setRejectReason('')
    let cancelled = false
    void getCommercialDocumentDetail(documentId)
      .then((doc) => {
        if (cancelled) return
        setSignerName(partyDisplayName(doc.buyer_snapshot).replace('—', '').trim())
        setSignerEmail(doc.buyer_snapshot.email?.trim() ?? '')
      })
      .catch(() => {
        /* fields stay empty; user can type them */
      })
    return () => {
      cancelled = true
    }
  }, [documentId, open])

  if (!open) return null

  const role =
    action === 'reject' ? null : commercialSignerRoleForAction(action)
  const title =
    action === 'reject'
      ? t('projects.commercial.decision_register_reject', 'Registrar refús')
      : action === 'delivery'
        ? t('projects.commercial.sign_delivery_title', 'Signar conformitat')
        : t('projects.commercial.sign_accept_title', 'Acceptar amb signatura')

  async function applyCommercialOutcome(signature: Record<string, unknown>, opId: string) {
    if (action === 'reject') {
      await rejectCommercialDocument({
        documentId,
        signature,
        reason: rejectReason || null,
        clientOpId: opId,
      })
      return
    }
    if (action === 'delivery') {
      await signCommercialDeliveryNote({
        documentId,
        signature,
        clientOpId: opId,
      })
      return
    }
    await acceptCommercialDocument({
      documentId,
      signature,
      clientOpId: opId,
    })
  }

  /** F5: refús d'oficina sense pad ni stamp. */
  async function confirmOfficeReject() {
    setBusy(true)
    setError(null)
    try {
      const opId = generateClientOpId()
      await rejectCommercialDocument({
        documentId,
        signature: {
          method: 'office',
          ...(rejectReason.trim() ? { reason: rejectReason.trim() } : {}),
        },
        reason: rejectReason || null,
        clientOpId: opId,
      })
      toast({ title: t('projects.commercial.rejected', 'Refusat') })
      onCompleted('signed')
      onClose()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
      setStep('error')
    } finally {
      setBusy(false)
    }
  }

  async function startNative(mode: 'presential' | 'remote') {
    if (action === 'reject') {
      setError(
        t(
          'projects.commercial.reject_no_stamp',
          'El refús no usa pad de firma; registra’l sense estampar el PDF.',
        ),
      )
      setStep('error')
      return
    }
    const tenantId = activeTenant?.id
    if (!tenantId) {
      setError(t('projects.commercial.sign_missing_tenant', 'Cal un tenant actiu'))
      setStep('error')
      return
    }
    if (!nativeEnabled) {
      setError(
        t(
          'projects.commercial.sign_native_disabled',
          'La firma nativa no està activada. Activeu-la a l’administració.',
        ),
      )
      setStep('error')
      return
    }
    if (mode === 'remote' && !signerEmail.trim()) {
      toast({
        variant: 'destructive',
        title: t(
          'projects.commercial.sign_email_required',
          'Cal un correu del client per a la firma remota',
        ),
      })
      return
    }
    setBusy(true)
    setStep('preparing')
    setError(null)
    try {
      const doc = await getCommercialDocumentDetail(documentId)
      const rendered = await renderCommercialDocumentPdf({
        documentId,
        tenantId,
      })
      if (rendered.status !== 'ready' || !rendered.version_id) {
        throw new Error(
          t(
            'projects.commercial.sign_pdf_not_ready',
            'El PDF encara no està llest. Torna-ho a provar.',
          ),
        )
      }
      setPdfPreviewUrl(rendered.download_url ?? null)
      const opId = generateClientOpId()
      let decisionRequestId: string | null = null
      try {
        decisionRequestId = await createCommercialDecisionRequest({
          targetKind: 'commercial_document',
          targetId: documentId,
          expiresAt: defaultDecisionExpiresAt(14),
          clientOpId: opId,
        })
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err)
        if (!msg.includes('decision_requests_disabled')) throw err
      }
      const result = await callSignDocumentRouter({
        tenant_id: tenantId,
        action: 'sign_native',
        source_type: 'document_existing',
        source_document_version_id: rendered.version_id,
        document_title: `${docTypeLabel(doc.doc_type)} ${doc.doc_number ?? ''}`.trim(),
        native_sign_type: mode,
        output_format: 'pdf',
        output_profile: 'pdfa2b',
        signer_name: signerName.trim() || partyDisplayName(doc.buyer_snapshot),
        signer_email: signerEmail.trim() || undefined,
        signer_role: role ?? undefined,
        ...(mode === 'remote'
          ? {
              signers: [
                {
                  email: signerEmail.trim(),
                  name: signerName.trim() || partyDisplayName(doc.buyer_snapshot),
                  role: role ?? undefined,
                  order: 0,
                },
              ],
            }
          : {}),
        client_request_id: opId,
        ...(decisionRequestId
          ? { commercial_decision_request_id: decisionRequestId }
          : {}),
      })
      if (!result.session_id) {
        throw new Error(
          t('projects.commercial.sign_session_missing', "No s'ha creat la sessió de firma"),
        )
      }
      await registerCommercialSigningIntent({
        documentId,
        sessionId: result.session_id,
        action,
        clientOpId: opId,
        submissionId: result.submission_id ?? null,
        decisionRequestId,
      })
      setClientOpId(opId)
      setSessionId(result.session_id)
      setSubmissionId(result.submission_id ?? null)
      if (mode === 'presential') {
        setStep('pad')
      } else if (result.email_queued === true) {
        setStep('remote')
      } else if (result.email_queued === false) {
        throw new Error(
          result.email_error ||
            t(
              'projects.commercial.sign_remote_email_failed',
              "No s'ha pogut encuar el correu de firma. Reintenta o contacta amb el suport.",
            ),
        )
      } else {
        // Remote without email payload: still ok — use «Enviar per acceptar» for delivery
        setStep('remote')
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
      setStep('error')
    } finally {
      setBusy(false)
    }
  }

  async function confirmPresential(signatureBase64: string) {
    if (!sessionId || !clientOpId || action === 'reject') return
    setBusy(true)
    try {
      await callStampPdfSignatures(
        {
          session_id: sessionId,
          client_signature_base64: signatureBase64,
        },
        activeTenant?.id,
      )
      const signature = buildCommercialNativeSignaturePayload({
        action,
        sessionId,
        submissionId,
      })
      try {
        await applyCommercialOutcome(signature, clientOpId)
      } catch (err) {
        if (!isAlreadyAppliedCommercialSigningError(err)) throw err
      }
      toast({
        title:
          action === 'delivery'
            ? t('projects.commercial.delivery_signed', 'Albarà signat')
            : t('projects.commercial.accepted', 'Acceptat'),
      })
      onCompleted('signed')
      onClose()
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('projects.commercial.error', 'Error comercial'),
        description: err instanceof Error ? err.message : undefined,
      })
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="fixed inset-0 z-[60] flex items-end sm:items-center justify-center bg-black/40 p-0 sm:p-4">
      <div className="w-full max-w-lg rounded-t-2xl sm:rounded-xl border border-border bg-background p-4 sm:p-6 shadow-lg max-h-[92vh] overflow-y-auto overscroll-contain space-y-4">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h3 className="text-lg font-semibold text-foreground">{title}</h3>
            <p className="text-sm text-muted-foreground">
              {action === 'reject'
                ? t(
                    'projects.commercial.reject_no_stamp_help',
                    'El refús es registra sense firmar ni estampar el PDF.',
                  )
                : t(
                    'projects.commercial.sign_help',
                    'El client signa amb el dit al dispositiu o via correu/portal de la plataforma. No es desa com a clic intern.',
                  )}
            </p>
          </div>
          <Button type="button" variant="ghost" size="sm" onClick={onClose} disabled={busy}>
            {t('projects.commercial.share_close', 'Tancar')}
          </Button>
        </div>

        {step === 'choose' || step === 'preparing' ? (
          <div className="space-y-3">
            {action === 'reject' ? (
              <>
                <label className="block space-y-1">
                  <span className="text-sm font-medium">
                    {t('projects.commercial.sign_reject_reason', 'Motiu (opcional)')}
                  </span>
                  <Input
                    value={rejectReason}
                    onChange={(e) => setRejectReason(e.target.value)}
                    disabled={busy}
                  />
                </label>
                <Button
                  type="button"
                  variant="destructive"
                  disabled={busy}
                  onClick={() => void confirmOfficeReject()}
                >
                  {busy ? (
                    <Loader2 className="h-4 w-4 animate-spin" />
                  ) : (
                    t('projects.commercial.decision_register_reject', 'Registrar refús')
                  )}
                </Button>
              </>
            ) : (
              <>
                <label className="block space-y-1">
                  <span className="text-sm font-medium">
                    {t('projects.commercial.sign_client_name', 'Nom del client')}
                  </span>
                  <Input
                    value={signerName}
                    onChange={(e) => setSignerName(e.target.value)}
                    disabled={busy}
                  />
                </label>
                <label className="block space-y-1">
                  <span className="text-sm font-medium">
                    {t('projects.commercial.sign_client_email', 'Correu (firma remota)')}
                  </span>
                  <Input
                    type="email"
                    value={signerEmail}
                    onChange={(e) => setSignerEmail(e.target.value)}
                    disabled={busy}
                  />
                </label>
                <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
                  <Button
                    type="button"
                    disabled={busy}
                    onClick={() => void startNative('presential')}
                  >
                    {t('projects.commercial.sign_presential', 'Presencial')}
                  </Button>
                  <Button
                    type="button"
                    variant="outline"
                    disabled={busy}
                    onClick={() => void startNative('remote')}
                  >
                    {t('projects.commercial.sign_remote', 'Remota (/sign)')}
                  </Button>
                </div>
                {step === 'preparing' ? (
                  <p className="flex items-center gap-2 text-sm text-muted-foreground">
                    <Loader2 className="h-4 w-4 animate-spin" />
                    {t('projects.commercial.sign_preparing', 'Preparant el PDF i la sessió de firma…')}
                  </p>
                ) : null}
              </>
            )}
          </div>
        ) : null}

        {step === 'pad' && sessionId ? (
          <div className="space-y-3 overflow-x-hidden">
            {pdfPreviewUrl ? (
              <details className="rounded-md border border-border px-3 py-2">
                <summary className="cursor-pointer text-sm text-muted-foreground">
                  {t('projects.commercial.sign_preview_pdf', 'Veure el PDF abans de signar')}
                </summary>
                <object
                  data={pdfPreviewUrl}
                  type="application/pdf"
                  className="mt-2 h-40 w-full rounded-md border border-border"
                >
                  <a href={pdfPreviewUrl} target="_blank" rel="noopener noreferrer" className="text-sm underline">
                    {t('projects.commercial.share_pdf', 'Descarregar PDF')}
                  </a>
                </object>
              </details>
            ) : null}
            <SignaturePad
              title={nativeSignerRoleLabel(role, signerName)}
              subtitle={t(
                'projects.commercial.sign_pad_help',
                'Dibuixa amb el dit. La signatura s’estampa a la casella del document.',
              )}
              width={560}
              height={240}
              disabled={busy}
              onConfirm={(sig) => void confirmPresential(sig)}
              onCancel={onClose}
            />
          </div>
        ) : null}

        {step === 'remote' ? (
          <div className="space-y-3">
            <p className="text-sm text-foreground">
              {t(
                'projects.commercial.sign_remote_platform_help',
                'La sessió remota està creada. El client ha de rebre el correu de la plataforma o respondre des del portal. L’equip no veu ni copia l’enllaç de firma.',
              )}
            </p>
            <Button
              type="button"
              className="w-full"
              onClick={() => {
                onCompleted('remote_sent')
                onClose()
              }}
            >
              {t('projects.commercial.sign_remote_done', 'Fet')}
            </Button>
          </div>
        ) : null}

        {step === 'error' ? (
          <div className="space-y-3">
            <p className="text-sm text-destructive">{error}</p>
            <Button type="button" variant="outline" onClick={() => setStep('choose')}>
              {t('projects.commercial.sign_retry', 'Tornar')}
            </Button>
          </div>
        ) : null}
      </div>
    </div>
  )
}
