import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Loader2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { generateClientOpId } from '@/features/attendance/api/clientOpId'
import { callSignDocumentRouter } from '@/features/signing/api/signingService'
import { useSigningConfig } from '@/features/signing/api/useSigningConfig'
import { canSignWithDocuseal } from '@/features/signing/utils/signingCreditsGate'
import {
  createCommercialDecisionDelivery,
  createCommercialDecisionRequest,
  customerPortalPendingUrl,
  enqueueCommercialDecisionDeliveryEmail,
  getCommercialDocumentDetail,
  hasActiveCustomerPortalGrantForDocument,
  listQuoteAgreementStates,
  markAgreementSentForSignature,
  markCommercialDecisionDeliveryFailed,
  abortCommercialDecisionSigningPrepare,
  prepareCommercialDecisionSigningAttempt,
  registerCommercialSigningIntent,
  renderCommercialAgreementPdf,
  renderCommercialDocumentPdf,
  revertAgreementSentForSignature,
  revokeCommercialDecisionRequest,
  type OpenCommercialDecisionRequest,
} from '../api/commercialFlowService'
import {
  commercialDecisionActionForDocType,
  defaultDecisionExpiresAt,
} from '../utils/commercialDecisionSend'
import { commercialSignerRoleForAction } from '../utils/commercialNativeSign'
import { docTypeLabel, partyDisplayName } from '../utils/commercialDocumentModel'
import { buildWhatsAppTextUrl } from '../utils/commercialShare'

type SigningProviderChoice = 'native' | 'docuseal'

interface SendCommercialDecisionDialogProps {
  documentId: string
  open: boolean
  onClose: () => void
  onSent: () => void
  /** When set, reuses the open request and only creates a new delivery/session. */
  existingRequest?: OpenCommercialDecisionRequest | null
}

type Channel = 'email' | 'whatsapp_portal_nudge'

export function SendCommercialDecisionDialog({
  documentId,
  open,
  onClose,
  onSent,
  existingRequest = null,
}: SendCommercialDecisionDialogProps) {
  const { t } = useTranslation('projects')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const signingConfig = useSigningConfig(activeTenant?.id)
  const [channel, setChannel] = useState<Channel>('email')
  const [provider, setProvider] = useState<SigningProviderChoice>('native')
  const [creditAck, setCreditAck] = useState(false)
  const [signerName, setSignerName] = useState('')
  const [signerEmail, setSignerEmail] = useState('')
  const [busy, setBusy] = useState(false)
  const [deliveryStatus, setDeliveryStatus] = useState<string | null>(null)
  const [isAgreementTarget, setIsAgreementTarget] = useState(false)
  const [hasPortalGrant, setHasPortalGrant] = useState(false)

  const isResend = !!existingRequest?.id
  const portalPending = customerPortalPendingUrl()
  const whatsappEnabled = !!portalPending && hasPortalGrant
  const cfg = signingConfig.data
  const docusealAvailable = canSignWithDocuseal({
    featureEnabled: cfg?.feature_enabled === true,
    effectivelyActive: cfg?.effective_is_active === true,
    mode: cfg?.mode,
    credits: cfg?.signing_credits ?? 0,
    nativeSigningEnabled: true,
  })
  const showProviderSelector = docusealAvailable
  const usesPlatformCredit =
    provider === 'docuseal' && cfg?.mode === 'platform'

  useEffect(() => {
    if (!open) return
    setChannel('email')
    setProvider('native')
    setCreditAck(false)
    setDeliveryStatus(null)
    setBusy(false)
    setHasPortalGrant(false)
    setIsAgreementTarget(!!existingRequest?.agreement_version_id)
    void (async () => {
      try {
        const [doc, grantOk] = await Promise.all([
          getCommercialDocumentDetail(documentId),
          hasActiveCustomerPortalGrantForDocument(documentId).catch(() => false),
        ])
        setSignerName(partyDisplayName(doc.buyer_snapshot) || '')
        setSignerEmail(doc.buyer_snapshot?.email?.trim() || '')
        setHasPortalGrant(grantOk)
        if (!existingRequest?.agreement_version_id) {
          setIsAgreementTarget(doc.formalization_mode === 'separate_agreement')
        }
      } catch {
        /* ignore prefill errors */
      }
    })()
  }, [open, documentId, existingRequest?.agreement_version_id])

  useEffect(() => {
    if (!docusealAvailable && provider === 'docuseal') {
      setProvider('native')
      setCreditAck(false)
    }
  }, [docusealAvailable, provider])

  async function handleSend() {
    setBusy(true)
    setDeliveryStatus(null)
    let createdRequestId: string | null = null
    let markedAgreementVersionId: string | null = null
    try {
      const doc = await getCommercialDocumentDetail(documentId)
      const separate = doc.formalization_mode === 'separate_agreement'
      setIsAgreementTarget(separate)

      if (channel === 'whatsapp_portal_nudge') {
        if (!portalPending) {
          throw new Error(
            t(
              'projects.commercial.decision_whatsapp_no_portal_origin',
              'Falta la URL del portal del client. Configura VITE_CUSTOMER_PORTAL_ORIGIN o usa el correu.',
            ),
          )
        }
        if (!hasPortalGrant) {
          throw new Error(
            t(
              'projects.commercial.decision_whatsapp_no_grant',
              'Activa el portal del client per a aquest compte abans d’enviar per WhatsApp.',
            ),
          )
        }
      }

      if (channel === 'email' && !signerEmail.trim()) {
        throw new Error(
          t('projects.commercial.sign_email_required', 'Cal un correu del client per enviar.'),
        )
      }

      if (provider === 'docuseal' && !docusealAvailable) {
        throw new Error(
          t(
            'projects.commercial.decision_docuseal_unavailable',
            'DocuSeal no disponible: cal signing actiu i crèdits (si el mode és platform).',
          ),
        )
      }
      if (usesPlatformCredit && !creditAck) {
        throw new Error(
          t(
            'projects.commercial.decision_docuseal_credit_ack',
            'Confirma que s’usarà 1 crèdit de signatura DocuSeal.',
          ),
        )
      }

      let sourceVersionId = doc.rendered_document_version_id
      let agreementVersionId: string | null = existingRequest?.agreement_version_id ?? null
      let targetKind: 'commercial_document' | 'agreement_version' = 'commercial_document'
      let targetId = documentId

      if (separate) {
        const states = await listQuoteAgreementStates([documentId])
        const st = states[0]
        agreementVersionId = agreementVersionId ?? st?.active_or_draft_version_id ?? null
        if (!agreementVersionId) {
          throw new Error(
            t(
              'projects.commercial.decision_prepare_agreement_first',
              'Cal preparar l’acord abans d’enviar-lo a signar.',
            ),
          )
        }
        const rendered = await renderCommercialAgreementPdf({ versionId: agreementVersionId })
        sourceVersionId = rendered.document_version_id
        targetKind = 'agreement_version'
        targetId = agreementVersionId
        await markAgreementSentForSignature({ versionId: agreementVersionId })
        markedAgreementVersionId = agreementVersionId
      } else if (!sourceVersionId) {
        const rendered = await renderCommercialDocumentPdf({ documentId })
        sourceVersionId = rendered.document_version_id
      }

      const action = commercialDecisionActionForDocType(doc.doc_type)
      const role = commercialSignerRoleForAction(action === 'reject' ? 'accept' : action)
      const documentTitle =
        targetKind === 'agreement_version'
          ? t('projects.commercial.agreement_pdf_title', 'Contracte de serveis')
          : docTypeLabel(doc.doc_type)
      const opId = generateClientOpId()

      if (!activeTenant?.id) {
        throw new Error(t('projects.commercial.error', 'Error comercial'))
      }

      let requestId = existingRequest?.id ?? null
      if (!requestId) {
        requestId = await createCommercialDecisionRequest({
          targetKind,
          targetId,
          expiresAt: defaultDecisionExpiresAt(14),
          clientOpId: opId,
        })
        createdRequestId = requestId
      }

      // CS-D13/D58: WhatsApp = portal nudge only (no native session, no /sign token)
      if (channel === 'whatsapp_portal_nudge') {
        await createCommercialDecisionDelivery({
          requestId,
          channel: 'whatsapp_portal_nudge',
          locale: doc.locale || 'ca',
          clientOpId: generateClientOpId(),
        })
        markedAgreementVersionId = null
        createdRequestId = null

        const tenantLabel = activeTenant.name?.trim() || 'PiMed'
        const docLabel = doc.doc_number
          ? `${docTypeLabel(doc.doc_type)} ${doc.doc_number}`
          : docTypeLabel(doc.doc_type)
        const shareText = t(
          'projects.commercial.decision_whatsapp_portal_text',
          '{{tenant}}: tens uns documents pendents de resposta ({{doc}}). Entra al portal del client: {{url}}',
          { tenant: tenantLabel, doc: docLabel, url: portalPending },
        )
        window.open(buildWhatsAppTextUrl(shareText), '_blank', 'noopener,noreferrer')
        setDeliveryStatus('prepared')
        toast({
          title: t('projects.commercial.decision_whatsapp_opened', 'WhatsApp obert'),
          description: t(
            'projects.commercial.decision_whatsapp_portal_help',
            'El missatge enllaça al portal del client (cal identificació). No inclou l’enllaç de firma.',
          ),
        })
        onSent()
        return
      }

      // F8: rotate attempt / switch provider — revoke prior tokens & bridge.
      let prepareClientOpId: string | null = null
      if (existingRequest?.id) {
        const prepared = await prepareCommercialDecisionSigningAttempt({
          requestId,
          provider,
          clientOpId: opId,
        })
        prepareClientOpId = prepared.clientOpId
      }

      const signerPayload = {
        email: signerEmail.trim() || 'noreply@invalid.local',
        name: signerName.trim() || partyDisplayName(doc.buyer_snapshot),
        role,
        order: 0,
      }

      const abortPrepareIfNeeded = async () => {
        if (!prepareClientOpId || !requestId) return
        try {
          await abortCommercialDecisionSigningPrepare({
            requestId,
            clientOpId: prepareClientOpId,
          })
        } catch {
          /* best-effort compensate */
        }
      }

      if (provider === 'docuseal') {
        let signResult
        try {
          signResult = await callSignDocumentRouter({
            tenant_id: activeTenant.id,
            action: 'sign',
            source_type: 'document_existing',
            source_document_version_id: sourceVersionId!,
            document_title: documentTitle,
            output_format: 'pdf',
            output_profile: 'pdfa2b',
            signer_name: signerPayload.name,
            signer_email: signerPayload.email,
            signer_role: role,
            signers: [signerPayload],
            notification_mode: 'app_manual',
            client_request_id: opId,
            commercial_decision_request_id: requestId,
          })
        } catch (err) {
          await abortPrepareIfNeeded()
          throw err
        }
        if (!signResult.submission_id) {
          await abortPrepareIfNeeded()
          throw new Error(
            t(
              'projects.commercial.decision_docuseal_submission_missing',
              "No s'ha creat la submission DocuSeal",
            ),
          )
        }
        // CS-D58: never surface signing_url / signer_links even if present.
        markedAgreementVersionId = null
        createdRequestId = null
      } else {
        let sessionResult
        try {
          sessionResult = await callSignDocumentRouter({
            tenant_id: activeTenant.id,
            action: 'sign_native',
            source_type: 'document_existing',
            source_document_version_id: sourceVersionId!,
            document_title: documentTitle,
            native_sign_type: 'remote',
            output_format: 'pdf',
            output_profile: 'pdfa2b',
            signer_name: signerPayload.name,
            signer_email: signerPayload.email,
            signer_role: role,
            signers: [signerPayload],
            client_request_id: opId,
            commercial_decision_request_id: requestId,
          })
        } catch (err) {
          await abortPrepareIfNeeded()
          throw err
        }
        if (!sessionResult.session_id) {
          await abortPrepareIfNeeded()
          throw new Error(
            t('projects.commercial.sign_session_missing', "No s'ha creat la sessió de firma"),
          )
        }
        markedAgreementVersionId = null
        createdRequestId = null

        await registerCommercialSigningIntent({
          documentId,
          sessionId: sessionResult.session_id,
          action,
          clientOpId: opId,
          submissionId: sessionResult.submission_id ?? null,
          decisionRequestId: requestId,
        })
      }

      const delivery = await createCommercialDecisionDelivery({
        requestId,
        channel: 'email',
        locale: doc.locale || 'ca',
        clientOpId: generateClientOpId(),
      })

      // CS-D58: rawToken is never returned; email builds /sign URL server-side from token_once.
      try {
        const origin =
          typeof window !== 'undefined' ? window.location.origin : 'http://localhost:5173'
        await enqueueCommercialDecisionDeliveryEmail({
          deliveryId: delivery.deliveryId,
          toEmail: signerEmail.trim(),
          decisionUrl: origin,
          recipientName: signerName.trim() || partyDisplayName(doc.buyer_snapshot),
          locale: doc.locale || 'ca',
          portalUrl: portalPending,
        })
        setDeliveryStatus('queued')
        toast({
          title: t('projects.commercial.decision_email_queued', 'Correu en cua'),
          description: t(
            'projects.commercial.decision_email_queued_help',
            'S’ha enqueuejat l’enviament. L’estat passarà a enviat quan el proveïdor el confirmi.',
          ),
        })
      } catch (err) {
        try {
          await markCommercialDecisionDeliveryFailed({
            deliveryId: delivery.deliveryId,
            errorCode: 'enqueue_failed',
          })
        } catch {
          /* keep primary error */
        }
        throw err
      }

      onSent()
    } catch (err) {
      if (createdRequestId) {
        try {
          await revokeCommercialDecisionRequest({ requestId: createdRequestId })
        } catch {
          /* surface original error */
        }
      }
      if (markedAgreementVersionId) {
        try {
          await revertAgreementSentForSignature({
            versionId: markedAgreementVersionId,
          })
        } catch {
          /* surface original error */
        }
      }
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
    <Dialog open={open} onOpenChange={(next) => (!next && !busy ? onClose() : undefined)}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>
            {isResend
              ? t('projects.commercial.decision_resend_title', 'Reenviar sol·licitud')
              : t('projects.commercial.decision_send_title', 'Enviar per acceptar')}
          </DialogTitle>
          <DialogDescription>
            {isAgreementTarget
              ? t(
                  'projects.commercial.decision_send_agreement_help',
                  'El client firmarà l’acord (no el pressupost). Rebrà el correu de la plataforma i/o podrà respondre al portal; no es mostra l’enllaç de resposta a l’equip.',
                )
              : t(
                  'projects.commercial.decision_send_help',
                  'El client rebrà un correu de la plataforma i/o podrà respondre al portal. L’equip no veu l’enllaç de resposta.',
                )}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-3">
          <div className="space-y-1">
            <label className="text-sm font-medium">
              {t('projects.commercial.sign_client_name', 'Nom del client')}
            </label>
            <Input
              value={signerName}
              onChange={(e) => setSignerName(e.target.value)}
              disabled={busy}
            />
          </div>
          <div className="space-y-1">
            <label className="text-sm font-medium">
              {t('projects.commercial.sign_client_email', 'Correu (firma remota)')}
            </label>
            <Input
              type="email"
              value={signerEmail}
              onChange={(e) => setSignerEmail(e.target.value)}
              disabled={busy}
            />
          </div>
          {showProviderSelector ? (
            <div className="space-y-2 rounded-md border border-border p-3">
              <p className="text-sm font-medium">
                {t('projects.commercial.decision_provider_label', 'Proveïdor de firma')}
              </p>
              <div className="flex flex-wrap gap-2">
                <Button
                  type="button"
                  size="sm"
                  variant={provider === 'native' ? 'default' : 'outline'}
                  disabled={busy}
                  onClick={() => {
                    setProvider('native')
                    setCreditAck(false)
                  }}
                >
                  {t('projects.commercial.decision_provider_native', 'Firma pròpia')}
                </Button>
                <Button
                  type="button"
                  size="sm"
                  variant={provider === 'docuseal' ? 'default' : 'outline'}
                  disabled={busy}
                  onClick={() => setProvider('docuseal')}
                >
                  DocuSeal
                </Button>
              </div>
              {provider === 'docuseal' ? (
                <p className="text-xs text-muted-foreground">
                  {t(
                    'projects.commercial.decision_provider_docuseal_help',
                    'Servei extern amb consum de crèdit. El client firmarà a DocuSeal; l’equip no veu l’URL.',
                  )}
                </p>
              ) : null}
              {usesPlatformCredit ? (
                <label className="flex items-start gap-2 text-xs text-muted-foreground">
                  <input
                    type="checkbox"
                    className="mt-0.5"
                    checked={creditAck}
                    disabled={busy}
                    onChange={(e) => setCreditAck(e.target.checked)}
                  />
                  <span>
                    {t(
                      'projects.commercial.decision_docuseal_credit_confirm',
                      'Confirmo que s’usarà 1 crèdit de signatura (saldo: {{credits}}).',
                      { credits: cfg?.signing_credits ?? 0 },
                    )}
                  </span>
                </label>
              ) : null}
            </div>
          ) : null}

          <div className="flex flex-wrap gap-2">
            {(
              [
                ['email', t('projects.commercial.decision_channel_email', 'Correu')],
                [
                  'whatsapp_portal_nudge',
                  t('projects.commercial.decision_channel_whatsapp', 'WhatsApp'),
                ],
              ] as const
            ).map(([id, label]) => (
              <Button
                key={id}
                type="button"
                size="sm"
                variant={channel === id ? 'default' : 'outline'}
                disabled={busy || (id === 'whatsapp_portal_nudge' && !whatsappEnabled)}
                title={
                  id === 'whatsapp_portal_nudge' && !portalPending
                    ? t(
                        'projects.commercial.decision_whatsapp_needs_portal',
                        'Cal configurar el portal del client',
                      )
                    : id === 'whatsapp_portal_nudge' && !hasPortalGrant
                      ? t(
                          'projects.commercial.decision_whatsapp_no_grant',
                          'Activa el portal del client per a aquest compte abans d’enviar per WhatsApp.',
                        )
                      : undefined
                }
                onClick={() => setChannel(id)}
              >
                {label}
              </Button>
            ))}
          </div>
          {channel === 'whatsapp_portal_nudge' && whatsappEnabled ? (
            <p className="text-xs text-muted-foreground">
              {t(
                'projects.commercial.decision_whatsapp_portal_hint',
                'WhatsApp només envia un enllaç al portal del client (sense URL de firma).',
              )}
            </p>
          ) : null}
          {deliveryStatus ? (
            <p className="text-xs text-muted-foreground">
              {t('projects.commercial.decision_delivery_status', 'Estat del lliurament: {{status}}', {
                status: deliveryStatus,
              })}
            </p>
          ) : null}
        </div>

        <DialogFooter className="gap-2 sm:gap-0">
          <Button type="button" variant="outline" disabled={busy} onClick={onClose}>
            {t('projects.commercial.share_close', 'Tancar')}
          </Button>
          <Button
            type="button"
            disabled={busy || (usesPlatformCredit && !creditAck)}
            onClick={() => void handleSend()}
          >
            {busy ? (
              <>
                <Loader2 className="mr-2 h-4 w-4 animate-spin" aria-hidden />
                {t('projects.commercial.share_loading', 'Carregant…')}
              </>
            ) : isResend ? (
              t('projects.commercial.decision_resend_confirm', 'Reenviar')
            ) : (
              t('projects.commercial.decision_send_confirm', 'Enviar per acceptar')
            )}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
