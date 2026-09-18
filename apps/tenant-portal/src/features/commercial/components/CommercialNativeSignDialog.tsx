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
  getCommercialDocumentDetail,
  recordCommercialDocumentSent,
  registerCommercialSigningIntent,
  rejectCommercialDocument,
  renderCommercialDocumentPdf,
  signCommercialDeliveryNote,
} from '../api/commercialFlowService'
import {
  buildCommercialNativeSignaturePayload,
  buildCommercialSigningLinkShareText,
  commercialNativeSignLink,
  commercialSignerRoleForAction,
  type CommercialNativeSignAction,
} from '../utils/commercialNativeSign'
import { docTypeLabel, partyDisplayName } from '../utils/commercialDocumentModel'
import { buildMailtoTextUrl, buildWhatsAppTextUrl } from '../utils/commercialShare'

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
  const [signUrl, setSignUrl] = useState<string | null>(null)
  const [clientOpId, setClientOpId] = useState<string | null>(null)
  const [pdfPreviewUrl, setPdfPreviewUrl] = useState<string | null>(null)

  useEffect(() => {
    if (!open) return
    setStep('choose')
    setError(null)
    setBusy(false)
    setSessionId(null)
    setSubmissionId(null)
    setSignUrl(null)
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

  const role = commercialSignerRoleForAction(action)
  const title =
    action === 'reject'
      ? t('projects.commercial.sign_reject_title', 'Refusar amb signatura')
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

  async function startNative(mode: 'presential' | 'remote') {
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
        signer_role: role,
        ...(mode === 'remote'
          ? {
              signers: [
                {
                  email: signerEmail.trim(),
                  name: signerName.trim() || partyDisplayName(doc.buyer_snapshot),
                  role,
                  order: 0,
                },
              ],
            }
          : {}),
        client_request_id: opId,
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
      })
      setClientOpId(opId)
      setSessionId(result.session_id)
      setSubmissionId(result.submission_id ?? null)
      const remoteUrl =
        result.signing_url
        ?? result.signer_links?.[0]?.signing_url
        ?? null
      setSignUrl(remoteUrl ? commercialNativeSignLink(remoteUrl) : null)
      if (mode === 'presential') {
        setStep('pad')
      } else if (remoteUrl) {
        setStep('remote')
      } else {
        throw new Error(
          t(
            'projects.commercial.sign_remote_link_missing',
            "S'ha creat la sessió però no s'ha obtingut l'enllaç /sign",
          ),
        )
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
      setStep('error')
    } finally {
      setBusy(false)
    }
  }

  async function confirmPresential(signatureBase64: string) {
    if (!sessionId || !submissionId || !clientOpId) return
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
        submissionId,
        sessionId,
        reason: rejectReason || null,
      })
      await applyCommercialOutcome(signature, clientOpId)
      toast({
        title:
          action === 'reject'
            ? t('projects.commercial.rejected', 'Refusat')
            : action === 'delivery'
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

  async function shareRemote(channel: 'whatsapp' | 'email' | 'copy') {
    if (!signUrl) return
    const doc = await getCommercialDocumentDetail(documentId)
    const text = buildCommercialSigningLinkShareText({
      title: docTypeLabel(doc.doc_type),
      docNumber: doc.doc_number,
      signUrl,
    })
    if (channel === 'whatsapp') {
      window.open(
        buildWhatsAppTextUrl(text, doc.buyer_snapshot.phone),
        '_blank',
        'noopener,noreferrer',
      )
    } else if (channel === 'email') {
      window.location.href = buildMailtoTextUrl(
        `${docTypeLabel(doc.doc_type)} ${doc.doc_number ?? ''}`.trim(),
        text,
        signerEmail || doc.buyer_snapshot.email,
      )
    } else {
      await navigator.clipboard.writeText(text)
    }
    try {
      await recordCommercialDocumentSent({
        documentId,
        channel: channel === 'copy' ? 'copy' : channel,
        payload: { kind: 'signing_link', signing_session_id: sessionId },
      })
    } catch {
      /* share already succeeded */
    }
    toast({
      title: t('projects.commercial.share_ok', 'Document preparat per enviar'),
    })
  }

  return (
    <div className="fixed inset-0 z-[60] flex items-end sm:items-center justify-center bg-black/40 p-0 sm:p-4">
      <div className="w-full max-w-lg rounded-t-2xl sm:rounded-xl border border-border bg-background p-4 sm:p-6 shadow-lg max-h-[92vh] overflow-y-auto space-y-4">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h3 className="text-lg font-semibold text-foreground">{title}</h3>
            <p className="text-sm text-muted-foreground">
              {t(
                'projects.commercial.sign_help',
                'El client signa al dispositiu o amb un enllaç. No es desa com a clic intern.',
              )}
            </p>
          </div>
          <Button type="button" variant="ghost" size="sm" onClick={onClose} disabled={busy}>
            {t('projects.commercial.share_close', 'Tancar')}
          </Button>
        </div>

        {step === 'choose' || step === 'preparing' ? (
          <div className="space-y-3">
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
            {action === 'reject' ? (
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
            ) : null}
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
          </div>
        ) : null}

        {step === 'pad' && sessionId ? (
          <div className="space-y-3">
            {pdfPreviewUrl ? (
              <object
                data={pdfPreviewUrl}
                type="application/pdf"
                className="h-48 w-full rounded-md border border-border"
              >
                <a href={pdfPreviewUrl} target="_blank" rel="noopener noreferrer" className="text-sm underline">
                  {t('projects.commercial.share_pdf', 'Descarregar PDF')}
                </a>
              </object>
            ) : null}
            <SignaturePad
              title={nativeSignerRoleLabel(role, signerName)}
              subtitle={t(
                'projects.commercial.sign_pad_help',
                'La signatura s’estampa a la casella del document',
              )}
              width={360}
              disabled={busy}
              onConfirm={(sig) => void confirmPresential(sig)}
              onCancel={onClose}
            />
          </div>
        ) : null}

        {step === 'remote' && signUrl ? (
          <div className="space-y-3">
            <p className="text-sm text-foreground break-all">{signUrl}</p>
            <p className="text-xs text-muted-foreground">
              {t(
                'projects.commercial.sign_remote_help',
                'Envia aquest enllaç al client. WhatsApp i correu del document no canvien: aquest enllaç és només la firma.',
              )}
            </p>
            <div className="grid grid-cols-1 sm:grid-cols-3 gap-2">
              <Button type="button" onClick={() => void shareRemote('whatsapp')}>
                {t('projects.commercial.share_whatsapp', 'WhatsApp')}
              </Button>
              <Button type="button" variant="outline" onClick={() => void shareRemote('email')}>
                {t('projects.commercial.share_email', 'Correu')}
              </Button>
              <Button type="button" variant="outline" onClick={() => void shareRemote('copy')}>
                {t('projects.commercial.share_copy', 'Copiar text')}
              </Button>
            </div>
            <Button
              type="button"
              className="w-full"
              onClick={() => {
                onCompleted('remote_sent')
                onClose()
              }}
            >
              {t('projects.commercial.sign_remote_done', 'Enllaç enviat')}
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
