import { useEffect, useState, useRef } from 'react'
import { useParams, useNavigate, Link } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import {
  RefreshCw, ExternalLink, FileText, Copy, Check, Mail,
  CheckCircle2, XCircle, Clock, AlertCircle, Loader2, Download, Eye, ShieldCheck, Info, ClipboardCheck, Trash2,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { useToast } from '@/hooks/use-toast'
import { useSigningSubmission } from '../api/useSigningSubmission'
import { useMarkReviewedMutation } from '../api/useMarkReviewedMutation'
import { SIGNING_EVENTS_PAGE_SIZE, useSigningEvents } from '../api/useSigningEvents'
import { signingKeys } from '../api/signingKeys'
import { SIGNING_STATUS_CLASSES } from '../signingStatusColors'
import { supabase } from '@/lib/supabase'
import {
  callSigningSessionManager,
  type SigningEvent,
  type SigningStatus,
  type SignerSnapshot,
  type NotificationMode,
  type SigningSessionAction,
  type SigningSessionManagerResult,
  getSigningProvider,
} from '../api/signingService'
import { DocumentIntegrityPanel, DocuSealIntegrityNote } from './DocumentIntegrityPanel'

// ─── Status badge ─────────────────────────────────────────────────────────────

function StatusBadge({ status, label }: { status: SigningStatus; label: string }) {
  return (
    <span className={`inline-flex items-center px-2.5 py-1 rounded-lg text-sm font-medium ${SIGNING_STATUS_CLASSES[status]}`}>
      {label}
    </span>
  )
}

// ─── Timeline event icon ──────────────────────────────────────────────────────

function EventIcon({ eventType, statusAfter }: { eventType: string | null; statusAfter: string | null }) {
  if (statusAfter === 'completed') return <CheckCircle2 className="h-4 w-4 text-green-600" />
  if (statusAfter === 'cancelled') return <Trash2 className="h-4 w-4 text-gray-500" />
  if (statusAfter === 'declined' || statusAfter === 'error' || statusAfter === 'expired')
    return <XCircle className="h-4 w-4 text-red-500" />
  if (eventType?.includes('created') || eventType?.includes('init')) return <FileText className="h-4 w-4 text-indigo-500" />
  if (eventType?.includes('error')) return <AlertCircle className="h-4 w-4 text-red-500" />
  if (statusAfter === 'in_progress') return <Loader2 className="h-4 w-4 text-blue-500" />
  return <Clock className="h-4 w-4 text-muted-foreground" />
}

function formatDateTime(iso: string | null): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleString('ca-ES', {
    day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  })
}

const UUID_RE =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/

function isUuid(value: string | null | undefined): value is string {
  return !!value && UUID_RE.test(value)
}

function formatSigningStatusReason(
  reason: string,
  t: (key: string, fallback: string) => string,
): string {
  switch (reason) {
    case 'cancelled_by_user':
      return t('detail.statusReason.cancelled_by_user', 'Cancel·lada per un usuari.')
    case 'cancelled_remote_deleted':
      return t(
        'detail.statusReason.cancelled_remote_deleted',
        'Cancel·lada i eliminada també a DocuSeal.',
      )
    case 'cancelled_remote_missing':
      return t(
        'detail.statusReason.cancelled_remote_missing',
        'Cancel·lada localment. No s\'ha trobat la submissió a DocuSeal.',
      )
    case 'generate_only_snapshot':
      return t(
        'detail.statusReason.generate_only_snapshot',
        'Còpia de només generació, sense flux de firma.',
      )
    default:
      return t('detail.statusReason.generic', "Motiu de l'estat no especificat")
  }
}

// ─── Signer status color ──────────────────────────────────────────────────────

function signerStatusClass(status: string | undefined): string {
  if (status === 'completed' || status === 'signed') return 'text-green-600'
  if (status === 'declined')                          return 'text-red-500'
  if (status === 'opened')                            return 'text-blue-500'
  return 'text-muted-foreground'
}

function signerEffectiveStatus(s: SignerSnapshot): string {
  if (s.completed_at || s.status === 'completed' || s.status === 'signed') return 'completed'
  if (s.status === 'declined') return 'declined'
  if (s.status === 'opened') return 'opened'
  return 'pending'
}

// ─── Main component ────────────────────────────────────────────────────────────

export function SigningSubmissionDetail() {
  const { id }   = useParams<{ id: string }>()
  const navigate = useNavigate()
  const { t }    = useTranslation('signing')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const [eventsPage, setEventsPage] = useState(0)
  const [allEvents, setAllEvents] = useState<SigningEvent[]>([])

  const { data: submission, isLoading, refetch } = useSigningSubmission(id)
  const { data: events = [] }                     = useSigningEvents(id, eventsPage, SIGNING_EVENTS_PAGE_SIZE)
  const markReviewed = useMarkReviewedMutation()

  const [copiedSigningUrl, setCopiedSigningUrl] = useState(false)
  const [selectedSigner, setSelectedSigner] = useState<SignerSnapshot | null>(null)
  const [sendingNotifIdx, setSendingNotifIdx] = useState<number | null>(null)
  const [copiedSignerUrlIdx, setCopiedSignerUrlIdx] = useState<number | null>(null)
  const [sessionActionLoading, setSessionActionLoading] = useState<SigningSessionAction | null>(null)
  const [docusealCheckResult, setDocusealCheckResult] = useState<SigningSessionManagerResult | null>(null)
  const [confirmDeleteSessionOpen, setConfirmDeleteSessionOpen] = useState(false)
  const auditEnsureAttemptedRef = useRef(false)

  useEffect(() => {
    setEventsPage(0)
    setAllEvents([])
    auditEnsureAttemptedRef.current = false
  }, [id])

  useEffect(() => {
    if (eventsPage === 0) {
      setAllEvents(events)
      return
    }

    setAllEvents((prev) => {
      if (events.length === 0) return prev
      const seen = new Set(prev.map(e => e.id))
      const merged = [...prev]
      for (const ev of events) {
        if (!seen.has(ev.id)) merged.push(ev)
      }
      return merged
    })
  }, [events, eventsPage])

  const status   = (submission?.status ?? 'pending') as SigningStatus
  const signers  = (Array.isArray(submission?.signers) ? submission!.signers : []) as unknown as SignerSnapshot[]
  const isNative = submission ? getSigningProvider(submission) === 'native' : false
  const isDocuSeal = !isNative
  const auditTrailPath = submission?.audit_trail_storage_path ?? null

  // Auto-encua el certificat si falta (async, no espera la generació)
  useEffect(() => {
    if (!submission?.id || !submission.tenant_id) return
    if (!isNative || status !== 'completed') return
    if (auditTrailPath || auditEnsureAttemptedRef.current) return

    auditEnsureAttemptedRef.current = true
    void callSigningSessionManager({
      action: 'generate_native_audit',
      submission_id: submission.id,
      tenant_id: submission.tenant_id,
    }).catch(() => {/* silent – worker picks it up */})
  }, [submission?.id, submission?.tenant_id, isNative, status, auditTrailPath])

  if (isLoading) {
    return (
      <div className="p-8 flex items-center justify-center text-muted-foreground gap-2">
        <Loader2 className="h-5 w-5 animate-spin" />
        {t('center.loading', 'Carregant...')}
      </div>
    )
  }

  if (!submission) {
    return (
      <div className="p-8 text-center text-muted-foreground">
        <p>{t('detail.notFound', 'Submissió no trobada.')}</p>
        <Button variant="link" onClick={() => navigate('/documents/signing')}>{t('detail.back', 'Tornar')}</Button>
      </div>
    )
  }

  const TERMINAL_STATUSES: SigningStatus[] = ['completed', 'declined', 'expired', 'cancelled', 'error']
  const isTerminal = TERMINAL_STATUSES.includes(status)
  const notificationMode = (submission as Record<string, unknown>).notification_mode as NotificationMode | null
  const timelineEvents = [...allEvents].reverse()
  const canLoadMoreEvents = events.length === SIGNING_EVENTS_PAGE_SIZE
  const showIntegrityTab = (isNative && status === 'completed') || isDocuSeal
  const showDetailTabs = signers.length > 0 || showIntegrityTab

  async function handleResendNotification(signerOrder: number) {
    if (!submission || !submission.id) return
    setSendingNotifIdx(signerOrder)
    try {
      const { error } = await supabase.rpc('enqueue_signing_notification' as never, {
        p_submission_id: submission.id,
        p_signer_order:  signerOrder,
        p_reason:        'manual',
      } as never)
      if (error) throw new Error(error.message)
      toast({ title: t('detail.notifSent', 'Notificació enviada') })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('detail.notifSentError', 'Error en enviar la notificació'),
        description: err instanceof Error ? err.message : undefined,
      })
    } finally {
      setSendingNotifIdx(null)
    }
  }

  async function handleOpenAuditTrail(storagePath: string) {
    try {
      const { data, error } = await supabase.storage
        .from('documents')
        .createSignedUrl(storagePath, 3600)
      if (error || !data?.signedUrl) throw new Error(error?.message ?? 'Error generant URL')
      window.open(data.signedUrl, '_blank', 'noopener,noreferrer')
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('detail.auditDownloadErrorTitle', 'Error en descarregar PDF d\'auditoria'),
        description: err instanceof Error ? err.message : undefined,
      })
    }
  }

  async function handleOpenResultDoc(filePathOrUrl: string, storageType: string) {
    try {
      let url: string
      if (storageType === 'external_link') {
        url = filePathOrUrl
      } else {
        const { data, error } = await supabase.storage
          .from('documents')
          .createSignedUrl(filePathOrUrl, 3600)
        if (error || !data?.signedUrl) throw new Error(error?.message ?? 'Error generant URL')
        url = data.signedUrl
      }
      window.open(url, '_blank', 'noopener,noreferrer')
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('detail.signedDocErrorTitle', 'Error en obrir el document firmat'),
        description: err instanceof Error ? err.message : undefined,
      })
    }
  }

  async function runSessionAction(action: SigningSessionAction) {
    if (!submission?.id || !submission.tenant_id) return
    setSessionActionLoading(action)
    try {
      const result = await callSigningSessionManager({
        action,
        submission_id: submission.id,
        tenant_id: submission.tenant_id,
      })

      if (action === 'check') {
        setDocusealCheckResult(result)
      }

      toast({
        title: t('detail.sessionActionOk', 'Operació completada'),
        description: result.message,
      })

      if (action !== 'check') {
        void refetch()
        void queryClient.invalidateQueries({ queryKey: signingKeys.events(submission.id) })
        void queryClient.invalidateQueries({ queryKey: ['signing', 'submissions'] })
      }
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('detail.sessionActionError', 'No s\'ha pogut completar l\'operació'),
        description: err instanceof Error ? err.message : undefined,
      })
    } finally {
      setSessionActionLoading(null)
    }
  }

  return (
    <div className="p-6 max-w-4xl mx-auto space-y-6">

      {/* Top bar */}
      <div className="flex items-center justify-between flex-wrap gap-4">
        <div className="space-y-2">
          <div className="flex items-center gap-2 text-xs text-muted-foreground">
            <button
              onClick={() => navigate('/documents/signing')}
              className="text-indigo-600 hover:text-indigo-700 font-medium transition-colors"
            >
              {t('detail.breadcrumbCenter', 'Centre de firmes')}
            </button>
            {isUuid(submission.source_document_id) && (
              <>
                <span>/</span>
                <button
                  onClick={() => navigate(`/documents/${submission.source_document_id}`)}
                  className="text-indigo-600 hover:text-indigo-700 font-medium transition-colors"
                >
                  {t('detail.breadcrumbDocument', 'Document')}
                </button>
              </>
            )}
          </div>
          <div>
            <h1 className="text-lg font-semibold">{t('detail.title', 'Detall de signatura')}</h1>
            <p className="text-xs text-muted-foreground font-mono mt-0.5">{submission.id}</p>
          </div>
        </div>
        <div className="flex items-center gap-2">
          {isDocuSeal && submission.docuseal_signing_url && (
            <>
              <Button variant="outline" size="sm" asChild>
                <a href={submission.docuseal_signing_url} target="_blank" rel="noopener noreferrer">
                  <ExternalLink className="h-3.5 w-3.5 mr-1.5" />
                  {t('detail.openSigningUrl', 'URL de signatura')}
                </a>
              </Button>
              <Button
                variant="outline"
                size="sm"
                onClick={() => {
                  void navigator.clipboard.writeText(submission.docuseal_signing_url!)
                  setCopiedSigningUrl(true)
                  setTimeout(() => setCopiedSigningUrl(false), 2000)
                }}
                title={t('detail.copySigningUrl', 'Copiar URL de signatura')}
              >
                {copiedSigningUrl
                  ? <Check className="h-3.5 w-3.5 text-green-500" />
                  : <Copy className="h-3.5 w-3.5" />}
              </Button>
            </>
          )}
          {status === 'completed' && !submission.reviewed_at && (
            <Button
              variant="outline"
              size="sm"
              disabled={markReviewed.isPending}
              onClick={() =>
                markReviewed.mutate(
                  { submissionId: submission.id!, tenantId: submission.tenant_id! },
                  {
                    onSuccess: () => toast({ title: t('detail.markedReviewed', 'Submissió marcada com a revisada') }),
                    onError: (err) => toast({
                      variant: 'destructive',
                      title: t('detail.markReviewedError', 'Error en marcar com a revisada'),
                      description: err.message,
                    }),
                  }
                )
              }
            >
              {markReviewed.isPending
                ? <Loader2 className="h-3.5 w-3.5 mr-1.5 animate-spin" />
                : <ClipboardCheck className="h-3.5 w-3.5 mr-1.5" />}
              {markReviewed.isPending
                ? t('detail.markingReviewed', 'Marcant...')
                : t('detail.markReviewed', 'Marcar com a revisada')}
            </Button>
          )}
          <Button
            variant="outline"
            size="sm"
            onClick={() => {
              void refetch()
              void queryClient.invalidateQueries({ queryKey: signingKeys.events(submission.id) })
            }}
          >
            <RefreshCw className="h-3.5 w-3.5 mr-1.5" />
            {t('center.refresh', 'Actualitzar')}
          </Button>
          {isDocuSeal && (
            <Button
              variant="outline"
              size="sm"
              disabled={sessionActionLoading !== null}
              onClick={() => void runSessionAction('check')}
            >
              {sessionActionLoading === 'check'
                ? <Loader2 className="h-3.5 w-3.5 mr-1.5 animate-spin" />
                : <Eye className="h-3.5 w-3.5 mr-1.5" />}
              {t('detail.checkDocuseal', 'Comprovar DocuSeal')}
            </Button>
          )}
          {isDocuSeal && (
            <Button
              variant="outline"
              size="sm"
              disabled={sessionActionLoading !== null || isTerminal}
              onClick={() => setConfirmDeleteSessionOpen(true)}
            >
              {sessionActionLoading === 'cancel_and_delete_remote'
                ? <Loader2 className="h-3.5 w-3.5 mr-1.5 animate-spin" />
                : <Trash2 className="h-3.5 w-3.5 mr-1.5" />}
              {t('detail.deleteSession', 'Eliminar sessió de firma')}
            </Button>
          )}
        </div>
      </div>

      {/* Status card */}
      <div className="rounded-xl border p-4 space-y-3">
        <div className="flex items-center gap-3">
          <StatusBadge status={status} label={t(`center.status.${status}`, status)} />
          {isNative ? (
            <span className="inline-flex items-center px-2 py-0.5 rounded-md text-xs font-medium bg-violet-100 text-violet-800">
              {t('detail.providerNative', 'Firma pròpia')}
            </span>
          ) : (
            <span className="inline-flex items-center px-2 py-0.5 rounded-md text-xs font-medium bg-sky-100 text-sky-800">
              {t('detail.providerDocuseal', 'DocuSeal')}
            </span>
          )}
          {submission.reviewed_at && (
            <span className="inline-flex items-center px-2 py-0.5 rounded-md text-xs font-medium bg-green-100 text-green-800">
              <ClipboardCheck className="h-3 w-3 mr-1" />
              {t('detail.reviewedBadge', 'Revisada')}
            </span>
          )}
          {notificationMode && (
            <span className="inline-flex items-center px-2 py-0.5 rounded-md text-xs font-medium bg-indigo-50 text-indigo-700">
              <Mail className="h-3 w-3 mr-1" />
              {t(`detail.notifMode.${notificationMode}`, notificationMode)}
            </span>
          )}
          {submission.status_reason && (
            <span className="text-sm text-muted-foreground">
              {formatSigningStatusReason(submission.status_reason, t)}
            </span>
          )}
        </div>

        <div className="grid grid-cols-2 gap-x-8 gap-y-1.5 text-sm">
          <div className="text-muted-foreground">{t('detail.sourceType', 'Origen')}</div>
          <div>
            {submission.source_type === 'document_existing'
              ? t('center.sourceDocument', 'Document existent')
              : t('center.sourceTemplate', 'Plantilla')}
          </div>

          {submission.source_document_id && submission.document_title && (
            <>
              <div className="text-muted-foreground">{t('detail.sourceDocument', 'Document')}</div>
              <div>
                <Link
                  to={`/documents/${submission.source_document_id}`}
                  className="text-indigo-600 hover:underline text-sm"
                >
                  {submission.document_title}
                </Link>
              </div>
            </>
          )}

          <div className="text-muted-foreground">{t('detail.created', 'Creat')}</div>
          <div className="tabular-nums">{formatDateTime(submission.created_at)}</div>

          <div className="text-muted-foreground">{t('detail.submitted', 'Enviat')}</div>
          <div className="tabular-nums">{formatDateTime(submission.submitted_at)}</div>

          <div className="text-muted-foreground">{t('detail.completed', 'Completat')}</div>
          <div className="tabular-nums">{formatDateTime(submission.completed_at)}</div>

          {submission.reviewed_at && (
            <>
              <div className="text-muted-foreground flex items-center gap-1">
                <ClipboardCheck className="h-3.5 w-3.5 text-green-600" />
                {t('detail.reviewedAt', 'Revisada el')}
              </div>
              <div className="tabular-nums text-green-700 font-medium">{formatDateTime(submission.reviewed_at)}</div>
            </>
          )}

          {submission.docuseal_submission_id && (
            <>
              <div className="text-muted-foreground">{t('detail.docusealId', 'ID DocuSeal')}</div>
              <div className="font-mono text-xs">{submission.docuseal_submission_id}</div>
            </>
          )}
        </div>

        {submission.error_message && (
          <div className="rounded-lg bg-red-50 border border-red-200 px-3 py-2 text-sm text-red-700">
            <span className="font-medium">{t('detail.errorMessage', 'Error')}: </span>
            {submission.error_message}
          </div>
        )}

        {docusealCheckResult && isDocuSeal && (
          <div className={`rounded-lg border px-3 py-2 text-sm ${docusealCheckResult.remote_found ? 'bg-blue-50 border-blue-200 text-blue-900' : 'bg-amber-50 border-amber-200 text-amber-900'}`}>
            <p className="font-medium">{t('detail.docusealCheckResultTitle', 'Resultat comprovació DocuSeal')}</p>
            <p className="mt-1">{docusealCheckResult.message}</p>
            <p className="mt-1 text-xs">
              {t('detail.docusealFound', 'Existeix a DocuSeal')}: {docusealCheckResult.remote_found ? t('detail.yes', 'Sí') : t('detail.no', 'No')}
            </p>
            {docusealCheckResult.remote_submission && (
              <pre className="mt-2 max-h-48 overflow-auto rounded bg-background/80 p-2 text-[11px] text-foreground/90 border">
                {JSON.stringify(docusealCheckResult.remote_submission, null, 2)}
              </pre>
            )}
          </div>
        )}
      </div>

      {isNative && (
        <div className="rounded-lg border border-violet-200 bg-violet-50 px-3 py-2 text-sm text-violet-900 flex gap-2">
          <Info className="h-4 w-4 shrink-0 mt-0.5" />
          <p>
            {t(
              'detail.nativeEvidenceNote',
              'Amb el mode «separat» (per defecte), la signatura apareix a l\'etiqueta de la plantilla i les evidències completes (hash, IP, timeline) al certificat d\'auditoria.',
            )}
          </p>
        </div>
      )}

      {/* Evidència de signatura */}
      {(submission.result_file_path_or_url || status === 'completed') && (
        <div className="space-y-2">
          <h2 className="text-sm font-semibold uppercase tracking-wide text-muted-foreground flex items-center gap-1.5">
            <ShieldCheck className="h-4 w-4 text-green-600" />
            {t('detail.evidenceSection', 'Evidència de signatura')}
          </h2>
          <div className="rounded-xl border px-4 py-3">
            <div className="flex items-center justify-between gap-4">
              <div>
                <p className="text-sm font-medium">{t('detail.signedDoc', 'Document firmat')}</p>
                <p className="text-xs text-muted-foreground mt-0.5">
                  {status === 'completed'
                    ? t('detail.signedDocDesc', 'PDF amb les firmes digitals aplicades')
                    : t('detail.signedDocPartialDesc', 'PDF amb les firmes registrades fins ara (procés en curs)')}
                </p>
              </div>
              <div className="flex items-center gap-2 shrink-0 flex-wrap justify-end">
                {/* Certificat auditoria native */}
                {status === 'completed' && isNative && auditTrailPath && (
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => void handleOpenAuditTrail(auditTrailPath)}
                  >
                    <Download className="h-3.5 w-3.5 mr-1.5" />
                    {t('detail.downloadAuditPdf', 'Certificat d\'auditoria')}
                  </Button>
                )}
                {status === 'completed' && isNative && !auditTrailPath && (
                  <Button variant="outline" size="sm" onClick={() => void refetch()}>
                    <RefreshCw className="h-3.5 w-3.5 mr-1.5" />
                    {t('detail.auditPending', 'Cert. auditoria (pendent)')}
                  </Button>
                )}
                {/* Certificat auditoria DocuSeal */}
                {status === 'completed' && isDocuSeal && submission.audit_log_url && (
                  <Button variant="outline" size="sm" asChild>
                    <a href={submission.audit_log_url} target="_blank" rel="noopener noreferrer">
                      <ExternalLink className="h-3.5 w-3.5 mr-1.5" />
                      {t('detail.openAuditExternal', 'Certificat d\'auditoria')}
                    </a>
                  </Button>
                )}
                {submission.result_file_path_or_url && (
                  <Button
                    variant="outline"
                    size="sm"
                    className="border-green-300 text-green-700 hover:bg-green-50"
                    onClick={() => void handleOpenResultDoc(
                      submission.result_file_path_or_url!,
                      submission.result_storage_type ?? 'native',
                    )}
                  >
                    <Eye className="h-3.5 w-3.5 mr-1.5" />
                    {t('detail.viewSignedDoc', 'Veure PDF firmat')}
                  </Button>
                )}
              </div>
            </div>
          </div>
        </div>
      )}

      {showDetailTabs && (
        <Tabs defaultValue={signers.length > 0 ? 'signers' : 'integrity'} className="space-y-3">
          <TabsList>
            {signers.length > 0 && (
              <TabsTrigger value="signers">{t('detail.signers', 'Signants')}</TabsTrigger>
            )}
            {showIntegrityTab && (
              <TabsTrigger value="integrity">{t('integrity.title', 'Integritat del document')}</TabsTrigger>
            )}
          </TabsList>

          {signers.length > 0 && (
            <TabsContent value="signers" className="mt-0">
              <div className="rounded-xl border divide-y">
                {signers.map((s, i) => (
                  <div key={i} className="flex items-start justify-between px-4 py-2.5 text-sm gap-3">
                    <div className="min-w-0 flex-1">
                      <span className="font-medium">{s.name || s.email}</span>
                      {s.name && <span className="text-muted-foreground ml-2">{s.email}</span>}
                      {s.role && <span className="ml-2 text-xs text-muted-foreground">({s.role})</span>}
                      {s.completed_at && (
                        <p className="text-xs text-muted-foreground mt-0.5 tabular-nums">
                          {t('detail.signerSignedAt', 'Firmat')}: {formatDateTime(s.completed_at)}
                        </p>
                      )}
                    </div>
                    <div className="flex items-center gap-1.5 shrink-0 flex-wrap justify-end">
                      {s.status && (
                        <span className={`text-xs font-medium ${signerStatusClass(signerEffectiveStatus(s))}`}>
                          {t(`detail.signerStatus.${signerEffectiveStatus(s)}`, s.status)}
                        </span>
                      )}
                      {s.signing_url && (
                        <Button
                          type="button"
                          variant="ghost"
                          size="icon"
                          className="h-7 w-7"
                          title={t('detail.openSignerUrl', 'Obrir URL de signatura')}
                          asChild
                        >
                          <a href={s.signing_url} target="_blank" rel="noopener noreferrer">
                            <ExternalLink className="h-3.5 w-3.5" />
                          </a>
                        </Button>
                      )}
                      {s.signing_url && (
                        <Button
                          type="button"
                          variant="ghost"
                          size="icon"
                          className="h-7 w-7"
                          title={t('detail.copySignerUrl', 'Copiar URL de signatura')}
                          onClick={() => {
                            void navigator.clipboard.writeText(s.signing_url!)
                            setCopiedSignerUrlIdx(i)
                            setTimeout(() => setCopiedSignerUrlIdx(null), 2000)
                          }}
                        >
                          {copiedSignerUrlIdx === i
                            ? <Check className="h-3.5 w-3.5 text-green-500" />
                            : <Copy className="h-3.5 w-3.5" />}
                        </Button>
                      )}
                      {notificationMode && notificationMode !== 'docuseal_auto' && !isTerminal && submission.docuseal_submission_id && (
                        <Button
                          type="button"
                          variant="ghost"
                          size="icon"
                          className="h-7 w-7"
                          title={t('detail.resendNotif', 'Reenviar notificació')}
                          disabled={sendingNotifIdx === (s.order ?? i)}
                          onClick={() => void handleResendNotification(s.order ?? i)}
                        >
                          {sendingNotifIdx === (s.order ?? i)
                            ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                            : <Mail className="h-3.5 w-3.5" />}
                        </Button>
                      )}
                      <Button
                        type="button"
                        variant="ghost"
                        size="icon"
                        className="h-7 w-7"
                        title={t('detail.signerInfo', 'Més informació del signant')}
                        onClick={() => setSelectedSigner(s)}
                      >
                        <Info className="h-3.5 w-3.5" />
                      </Button>
                    </div>
                  </div>
                ))}
              </div>
            </TabsContent>
          )}

          {showIntegrityTab && (
            <TabsContent value="integrity" className="mt-0">
              {isNative && submission.id && (
                <DocumentIntegrityPanel
                  embedded
                  submissionId={submission.id}
                  submissionStatus={status}
                  resultFilePath={submission.result_file_path_or_url}
                  resultStorageType={submission.result_storage_type}
                />
              )}
              {isDocuSeal && <DocuSealIntegrityNote />}
            </TabsContent>
          )}
        </Tabs>
      )}

      {/* Timeline */}
      <div className="space-y-2">
        <h2 className="text-sm font-semibold uppercase tracking-wide text-muted-foreground">
          {t('detail.timeline', 'Cronologia d\'esdeveniments')}
        </h2>
        {timelineEvents.length === 0 ? (
          <p className="text-sm text-muted-foreground">{t('detail.noEvents', 'Sense esdeveniments registrats.')}</p>
        ) : (
          <div className="relative">
            <div className="absolute left-4 top-0 bottom-0 w-px bg-border" />
            <div className="space-y-0">
              {timelineEvents.map((ev: SigningEvent, idx) => (
                <div key={ev.id ?? idx} className="flex items-start gap-3 pl-2">
                  <div className="relative z-10 flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-background border">
                    <EventIcon eventType={ev.event_type} statusAfter={ev.status_after} />
                  </div>
                  <div className="flex-1 pb-4 pt-1.5">
                    <div className="flex items-baseline justify-between gap-2 flex-wrap">
                      <span className="text-sm font-medium">
                        {ev.event_type
                          ? t(`detail.eventType.${ev.event_type}`, ev.event_type)
                          : t('detail.unknownEvent', 'Esdeveniment desconegut')}
                      </span>
                      <span className="text-xs text-muted-foreground tabular-nums">
                        {formatDateTime(ev.created_at)}
                      </span>
                    </div>
                    {(ev.status_before || ev.status_after) && (
                      <p className="text-xs text-muted-foreground mt-0.5">
                        {ev.status_before && <span>{t(`center.status.${ev.status_before}`, ev.status_before)}</span>}
                        {ev.status_before && ev.status_after && <span className="mx-1">→</span>}
                        {ev.status_after  && <span className="font-medium">{t(`center.status.${ev.status_after}`, ev.status_after)}</span>}
                      </p>
                    )}
                    {(ev.signer_email || ev.signer_name) && (
                      <p className="text-xs text-muted-foreground mt-0.5">
                        {ev.signer_name && <span>{ev.signer_name} </span>}
                        {ev.signer_email && <span className="font-mono">&lt;{ev.signer_email}&gt;</span>}
                      </p>
                    )}
                    {ev.event_source === 'webhook' && (
                      <span className="inline-block mt-1 text-[10px] bg-purple-100 text-purple-700 px-1.5 py-0.5 rounded font-medium">
                        {t('detail.webhook', 'webhook')}
                      </span>
                    )}
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}
        {canLoadMoreEvents && (
          <div className="pt-1">
            <Button variant="outline" size="sm" onClick={() => setEventsPage(p => p + 1)}>
              {t('detail.loadMoreEvents', 'Carregar més esdeveniments')}
            </Button>
          </div>
        )}
      </div>

      <Dialog open={!!selectedSigner} onOpenChange={(open) => { if (!open) setSelectedSigner(null) }}>
        <DialogContent className="sm:max-w-md left-auto top-0 right-0 translate-x-0 translate-y-0 h-screen rounded-none border-l border-border sm:rounded-none overflow-y-auto">
          <DialogHeader>
            <DialogTitle>{t('detail.signerDetailTitle', 'Detall del signant')}</DialogTitle>
            <DialogDescription>
              {t('detail.signerDetailDesc', 'Informació de seguiment de la firma d\'aquest signant')}
            </DialogDescription>
          </DialogHeader>

          {selectedSigner && (
            <div className="space-y-3 text-sm">
              <div>
                <p className="text-xs text-muted-foreground">{t('detail.signerName', 'Nom')}</p>
                <p className="font-medium">{selectedSigner.name || t('detail.emptyValue', '—')}</p>
              </div>

              <div>
                <p className="text-xs text-muted-foreground">{t('detail.signerEmail', 'Email')}</p>
                <p className="font-mono text-xs break-all">{selectedSigner.email || t('detail.emptyValue', '—')}</p>
              </div>

              <div>
                <p className="text-xs text-muted-foreground">{t('detail.signerRole', 'Rol')}</p>
                <p>{selectedSigner.role || t('detail.emptyValue', '—')}</p>
              </div>

              <div>
                <p className="text-xs text-muted-foreground">{t('detail.signerStatusLabel', 'Estat')}</p>
                <p className={signerStatusClass(signerEffectiveStatus(selectedSigner))}>
                  {t(`detail.signerStatus.${signerEffectiveStatus(selectedSigner)}`, selectedSigner.status ?? 'pending')}
                </p>
              </div>

              <div>
                <p className="text-xs text-muted-foreground">{t('detail.signerSignedAt', 'Firmat')}</p>
                <p className="tabular-nums">{formatDateTime(selectedSigner.completed_at ?? null)}</p>
              </div>

              {selectedSigner.signing_url && (
                <div className="pt-1">
                  <Button variant="outline" size="sm" asChild>
                    <a href={selectedSigner.signing_url} target="_blank" rel="noopener noreferrer">
                      <ExternalLink className="h-3.5 w-3.5 mr-1.5" />
                      {t('detail.openSignerSigningUrl', 'Obrir URL del signant')}
                    </a>
                  </Button>
                </div>
              )}
            </div>
          )}
        </DialogContent>
      </Dialog>

      <Dialog open={confirmDeleteSessionOpen} onOpenChange={setConfirmDeleteSessionOpen}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>{t('detail.deleteSessionConfirmTitle', 'Eliminar sessió de firma')}</DialogTitle>
            <DialogDescription>
              {t('detail.deleteSessionConfirmDesc', 'Aquesta acció cancel·larà la sessió local i intentarà eliminar-la de DocuSeal si existeix. Vols continuar?')}
            </DialogDescription>
          </DialogHeader>
          <div className="flex justify-end gap-2 pt-2">
            <Button
              variant="outline"
              onClick={() => setConfirmDeleteSessionOpen(false)}
              disabled={sessionActionLoading === 'cancel_and_delete_remote'}
            >
              {t('common.cancel', 'Cancel·lar')}
            </Button>
            <Button
              variant="destructive"
              onClick={() => {
                setConfirmDeleteSessionOpen(false)
                void runSessionAction('cancel_and_delete_remote')
              }}
              disabled={sessionActionLoading === 'cancel_and_delete_remote'}
            >
              {sessionActionLoading === 'cancel_and_delete_remote'
                ? t('detail.deletingSession', 'Eliminant...')
                : t('detail.deleteSessionAction', 'Eliminar sessió')}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  )
}
