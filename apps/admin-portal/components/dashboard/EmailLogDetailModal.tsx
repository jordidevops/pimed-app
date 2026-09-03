'use client'

import { useState, useEffect, useTransition } from 'react'
import {
  type EmailLogDetail,
  type ResendSyncResult,
  getEmailLogDetail,
  syncResendStatus,
  logEmailBodyViewed,
} from '@/app/admin/actions/email-logs'
import { EmailBodyViewerModal } from './EmailBodyViewerModal'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function formatDate(iso: string | null | undefined): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleString('ca-ES', {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  })
}

function formatDuration(ms: number | null): string {
  if (ms == null || ms < 0) return '—'
  if (ms < 1000) return `${Math.round(ms)} ms`
  const totalSecs = Math.round(ms / 1000)
  if (totalSecs < 60) return `${totalSecs}s`
  const h = Math.floor(totalSecs / 3600)
  const m = Math.floor((totalSecs % 3600) / 60)
  const s = totalSecs % 60
  if (h > 0) return `${h}h ${m}m ${s}s`
  return `${m}m ${s}s`
}

function JsonBlock({ value }: { value: unknown }) {
  if (value == null) return <span className="text-gray-400 text-xs italic">null</span>
  return (
    <pre className="bg-gray-50 border border-gray-200 rounded-lg p-3 text-xs text-gray-700 overflow-x-auto overflow-y-auto max-h-48 whitespace-pre-wrap break-all">
      {JSON.stringify(value, null, 2)}
    </pre>
  )
}

function Field({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div>
      <dt className="text-xs font-semibold text-gray-500 uppercase tracking-wide mb-0.5">
        {label}
      </dt>
      <dd className="text-sm text-gray-800 break-all">{value ?? '—'}</dd>
    </div>
  )
}

function getManualSyncAt(metadata: unknown): string | null {
  if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata)) {
    return null
  }

  const resendSync = (metadata as { resend_sync?: unknown }).resend_sync
  if (!resendSync || typeof resendSync !== 'object' || Array.isArray(resendSync)) {
    return null
  }

  const syncedAt = (resendSync as { synced_at?: unknown }).synced_at
  return typeof syncedAt === 'string' && syncedAt ? syncedAt : null
}

function getWebhookSyncAt(metadata: unknown): string | null {
  if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata)) {
    return null
  }
  const receivedAt = (metadata as { received_at?: unknown }).received_at
  return typeof receivedAt === 'string' && receivedAt ? receivedAt : null
}

// ---------------------------------------------------------------------------
// Status badge
// ---------------------------------------------------------------------------

const STATUS_COLORS: Record<string, string> = {
  queued: 'bg-gray-100 text-gray-700',
  processing: 'bg-blue-100 text-blue-700',
  sent: 'bg-green-100 text-green-700',
  delivered: 'bg-emerald-600 text-white',
  bounced: 'bg-orange-100 text-orange-700',
  failed: 'bg-red-100 text-red-700',
  complained: 'bg-purple-100 text-purple-700',
  suppressed: 'bg-gray-700 text-white',
}

// ---------------------------------------------------------------------------
// Props
// ---------------------------------------------------------------------------

interface EmailLogDetailModalProps {
  logId: string
  onClose: () => void
  onLogUpdated?: (updatedLog: EmailLogDetail) => void
}

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------

export function EmailLogDetailModal({
  logId,
  onClose,
  onLogUpdated,
}: EmailLogDetailModalProps) {
  const [log, setLog] = useState<EmailLogDetail | null>(null)
  const [isLoading, setIsLoading] = useState(true)
  const [loadError, setLoadError] = useState<string | null>(null)

  const [syncResult, setSyncResult] = useState<ResendSyncResult | null>(null)
  const [syncError, setSyncError] = useState<string | null>(null)
  const [isSyncing, startSyncTransition] = useTransition()
  const manualSyncAt  = log ? getManualSyncAt(log.metadata) : null
  const webhookSyncAt = log ? getWebhookSyncAt(log.metadata) : null
  const canManualSync = !!log?.provider_message_id

  // Body viewer state
  const [showBodyConfirm, setShowBodyConfirm] = useState(false)
  const [showBody, setShowBody] = useState(false)
  const [isLoggingBodyView, startBodyLogTransition] = useTransition()

  function handleBodyViewConfirm() {
    if (!log) return
    startBodyLogTransition(async () => {
      try {
        await logEmailBodyViewed(log.id, {
          tenant_id: log.tenant_id,
          subject: log.subject,
          sent_at: log.sent_at,
          to_emails: log.to_emails,
        })
      } catch (err) {
        console.warn('[audit] logEmailBodyViewed error:', err)
      }
      setShowBodyConfirm(false)
      setShowBody(true)
    })
  }

  // Load log detail on mount
  useEffect(() => {
    setIsLoading(true)
    setLoadError(null)
    getEmailLogDetail(logId)
      .then((result) => {
        setLog(result)
        setIsLoading(false)
      })
      .catch((err: unknown) => {
        setLoadError(err instanceof Error ? err.message : 'Error desconegut')
        setIsLoading(false)
      })
  }, [logId])

  // Close on Escape key
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  function handleSync() {
    setSyncError(null)
    setSyncResult(null)
    startSyncTransition(async () => {
      try {
        const result = await syncResendStatus(logId)
        setSyncResult(result)
        // Refresh log detail after sync
        const updated = await getEmailLogDetail(logId)
        setLog(updated)
        if (updated) onLogUpdated?.(updated)
      } catch (err: unknown) {
        setSyncError(err instanceof Error ? err.message : 'Error en sincronitzar')
      }
    })
  }

  // ---------------------------------------------------------------------------
  // Render
  // ---------------------------------------------------------------------------

  return (
    // Overlay
    <div
      className="fixed inset-0 z-50 flex items-center justify-center p-4"
      aria-modal="true"
      role="dialog"
    >
      {/* Backdrop */}
      <div
        className="absolute inset-0 bg-black/50"
        onClick={onClose}
        aria-hidden="true"
      />

      {/* Panel */}
      <div className="relative z-10 w-full max-w-3xl bg-white rounded-2xl shadow-2xl flex flex-col max-h-[90vh]">
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-gray-100 shrink-0">
          <h2 className="text-base font-semibold text-gray-900">
            Detall del registre d&apos;email
          </h2>
          <button
            type="button"
            onClick={onClose}
            className="rounded-full p-1.5 text-gray-400 hover:text-gray-600 hover:bg-gray-100 transition-colors"
            aria-label="Tancar"
          >
            <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        {/* Body (scrollable) */}
        <div className="overflow-y-auto flex-1 px-6 py-5 space-y-6">
          {isLoading && (
            <div className="flex justify-center py-12">
              <div className="w-8 h-8 border-2 border-indigo-600 border-t-transparent rounded-full animate-spin" />
            </div>
          )}

          {loadError && (
            <div className="rounded-lg bg-red-50 border border-red-200 p-4 text-sm text-red-700">
              Error en carregar: {loadError}
            </div>
          )}

          {log && !isLoading && (
            <>
              {/* Basic info */}
              <section>
                <h3 className="text-xs font-bold text-gray-500 uppercase tracking-wider mb-3">
                  Informació general
                </h3>
                <dl className="grid grid-cols-2 gap-x-6 gap-y-3">
                  <Field label="ID" value={<code className="text-xs">{log.id}</code>} />
                  <Field
                    label="Estat"
                    value={
                      <span className="inline-flex items-center gap-1.5">
                        <span
                          className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${STATUS_COLORS[log.status] ?? 'bg-gray-100 text-gray-600'}`}
                        >
                          {log.status}
                        </span>
                        {webhookSyncAt && (
                          <span
                            className="text-blue-500 text-xs"
                            title={`Actualitzat per Webhook: ${formatDate(webhookSyncAt)}`}
                          >
                            ⚡
                          </span>
                        )}
                        {manualSyncAt && (
                          <span
                            className="text-gray-400 text-xs"
                            title={`Sincronitzat manualment: ${formatDate(manualSyncAt)}`}
                          >
                            🔄
                          </span>
                        )}
                      </span>
                    }
                  />
                  <Field label="Tenant" value={log.tenant_name ?? log.tenant_id} />
                  <Field label="Site" value={log.site_name ?? log.site_id ?? '—'} />
                  <Field label="Tipus" value={log.email_type} />
                  <Field label="Creat el" value={formatDate(log.created_at)} />
                  <Field label="Enviat el" value={formatDate(log.sent_at)} />
                  <Field label="Entregat el" value={formatDate(log.delivered_at)} />
                  <Field label="Provider Message ID" value={
                    log.provider_message_id
                      ? <code className="text-xs">{log.provider_message_id}</code>
                      : null
                  } />
                  <Field
                    label="Intents"
                    value={`${log.attempt_count} / ${log.max_retries}${log.is_dead_letter ? ' 💀 Dead letter' : ''}`}
                  />
                </dl>
              </section>

              {/* Performance */}
{(() => {
                const isTerminalError = log.status === 'bounced' || log.status === 'failed'
                const errorTimeMs =
                  isTerminalError && log.sent_at && log.delivered_at == null
                    ? null
                    : isTerminalError && log.sent_at
                      ? new Date(log.delivered_at ?? '').getTime() - new Date(log.sent_at).getTime()
                      : null
                const showSection =
                  log.processing_time_ms != null ||
                  log.delivery_time_ms != null ||
                  errorTimeMs != null
                if (!showSection) return null
                return (
                  <section>
                    <h3 className="text-xs font-bold text-indigo-500 uppercase tracking-wider mb-3">
                      Rendiment
                    </h3>
                    <dl className="grid grid-cols-2 gap-x-6 gap-y-3">
                      {log.processing_time_ms != null && (
                        <Field
                          label="Temps a la nostra cua"
                          value={
                            <span className="font-mono text-sm">{formatDuration(log.processing_time_ms)}</span>
                          }
                        />
                      )}
                      {log.delivery_time_ms != null && (
                        <Field
                          label="Temps del proveïdor fins l'entrega"
                          value={
                            <span className="font-mono text-sm">{formatDuration(log.delivery_time_ms)}</span>
                          }
                        />
                      )}
                      {errorTimeMs != null && (
                        <Field
                          label="Temps fins a l'error"
                          value={
                            <span className="font-mono text-sm text-orange-600">{formatDuration(errorTimeMs)}</span>
                          }
                        />
                      )}
                    </dl>
                  </section>
                )
              })()}

              {/* Recipients */}
              <section>
                <h3 className="text-xs font-bold text-gray-500 uppercase tracking-wider mb-3">
                  Destinataris
                </h3>
                <dl className="grid grid-cols-1 gap-y-3">
                  <Field
                    label="De"
                    value={log.from_name ? `${log.from_name} <${log.from_email}>` : log.from_email}
                  />
                  {log.reply_to && <Field label="Reply-To" value={log.reply_to} />}
                  <Field
                    label="Per a (To)"
                    value={log.to_emails.join(', ')}
                  />
                  {log.cc_emails && log.cc_emails.length > 0 && (
                    <Field label="CC" value={log.cc_emails.join(', ')} />
                  )}
                  {log.bcc_emails && log.bcc_emails.length > 0 && (
                    <Field label="BCC" value={log.bcc_emails.join(', ')} />
                  )}
                  <Field
                    label="Assumpte"
                    value={log.subject ?? <span className="italic text-gray-400">(sense assumpte)</span>}
                  />
                </dl>
              </section>

              {/* Error info */}
              {(log.last_error || log.is_dead_letter) && (
                <section>
                  <h3 className="text-xs font-bold text-red-500 uppercase tracking-wider mb-3">
                    Informació d&apos;error
                  </h3>
                  {log.last_error && (
                    <div className="mb-3">
                      <p className="text-xs font-semibold text-gray-500 mb-1">Últim error</p>
                      <p className="text-sm text-red-700 bg-red-50 rounded-lg p-3 break-all">
                        {log.last_error}
                      </p>
                    </div>
                  )}
                  {!!log.error_history && (
                    <div>
                      <p className="text-xs font-semibold text-gray-500 mb-1">Historial d&apos;errors</p>
                      <JsonBlock value={log.error_history} />
                    </div>
                  )}
                </section>
              )}

              {/* Metadata */}
              {log.metadata && (
                <section>
                  <h3 className="text-xs font-bold text-gray-500 uppercase tracking-wider mb-3">
                    Metadata
                  </h3>
                  <JsonBlock value={log.metadata} />
                </section>
              )}

              {/* Resend sync section */}
              <section>
                <h3 className="text-xs font-bold text-gray-500 uppercase tracking-wider mb-3">
                  Sincronització amb Resend
                </h3>

                {webhookSyncAt && (
                  <p className="text-xs text-blue-600 mb-2 flex items-center gap-1">
                    <span aria-hidden="true">⚡</span>
                    Darrera actualització per webhook: {formatDate(webhookSyncAt)}
                  </p>
                )}

                {manualSyncAt && (
                  <p className="text-xs text-gray-500 mb-2">
                    Darrera comprovació manual: {formatDate(manualSyncAt)}
                  </p>
                )}

                {!log.provider_message_id && (
                  <p className="text-sm text-gray-400 italic">
                    Sense provider_message_id — no es pot sincronitzar.
                  </p>
                )}

                {canManualSync && (
                  <div className="space-y-3">
                    <button
                      type="button"
                      onClick={handleSync}
                      disabled={isSyncing}
                      className="flex items-center gap-2 px-4 py-2 rounded-lg bg-indigo-600 text-white text-sm font-medium hover:bg-indigo-700 disabled:opacity-60 transition-colors"
                    >
                      {isSyncing ? (
                        <>
                          <span className="w-4 h-4 border-2 border-white border-t-transparent rounded-full animate-spin" />
                          Sincronitzant…
                        </>
                      ) : (
                        <>
                          <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2}
                              d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
                          </svg>
                          Sincronitzar amb Resend
                        </>
                      )}
                    </button>

                    {syncError && (
                      <div className="rounded-lg bg-red-50 border border-red-200 p-3 text-sm text-red-700">
                        {syncError}
                      </div>
                    )}

                    {!!syncResult && (
                      <div className="space-y-2">
                        <p className="text-xs font-semibold text-gray-500 uppercase tracking-wide">
                          Resposta de Resend
                          <span className="ml-2 text-gray-400 normal-case">
                            (sincronitzat el {formatDate(syncResult.updated_at)})
                          </span>
                        </p>
                        {syncResult.resend_data.error != null
                          ? (
                            <div className="rounded-lg bg-red-50 border border-red-300 p-3 text-sm text-red-700 font-medium flex gap-2 items-start">
                              <span aria-hidden="true">⚠</span>
                              <span className="break-all">{String(syncResult.resend_data.error)}</span>
                            </div>
                          )
                          : null}
                        <JsonBlock value={syncResult.resend_data} />
                      </div>
                    )}
                  </div>
                )}
              </section>
            </>
          )}
        </div>

        {/* Footer */}
        <div className="px-6 py-4 border-t border-gray-100 flex items-center justify-between shrink-0">
          <div>
            {log && (log.html_body || log.text_body) && (
              <button
                type="button"
                onClick={() => setShowBodyConfirm(true)}
                className="flex items-center gap-2 px-4 py-2 rounded-lg bg-indigo-50 border border-indigo-200 text-sm text-indigo-700 font-medium hover:bg-indigo-100 transition-colors"
              >
                <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2}
                    d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2}
                    d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z" />
                </svg>
                Veure cos del correu
              </button>
            )}
          </div>
          <button
            type="button"
            onClick={onClose}
            className="px-4 py-2 rounded-lg border border-gray-300 text-sm text-gray-700 hover:bg-gray-50 transition-colors"
          >
            Tancar
          </button>
        </div>
      </div>

      {/* Diàleg de confirmació: avís d'auditoria */}
      {showBodyConfirm && (
        <div className="fixed inset-0 z-[60] flex items-center justify-center p-4" aria-modal="true" role="dialog">
          <div className="absolute inset-0 bg-black/50" onClick={() => setShowBodyConfirm(false)} aria-hidden="true" />
          <div className="relative z-10 w-full max-w-md bg-white rounded-2xl shadow-2xl p-6">
            <h3 className="text-base font-semibold text-gray-900 mb-3">
              Consulta del cos del correu
            </h3>
            <div className="rounded-lg bg-amber-50 border border-amber-200 p-4 text-sm text-amber-800 mb-5">
              <p className="font-medium mb-1">⚠ Avís d&apos;auditoria</p>
              <p>
                Accedir al contingut d&apos;aquest correu deixarà un registre permanent a l&apos;historial
                d&apos;auditoria amb el vostre nom d&apos;usuari, el vostre rol i la data i hora actuals.
              </p>
            </div>
            <div className="flex items-center justify-end gap-3">
              <button
                type="button"
                onClick={() => setShowBodyConfirm(false)}
                className="px-4 py-2 rounded-lg border border-gray-300 text-sm text-gray-700 hover:bg-gray-50 transition-colors"
              >
                Cancel·lar
              </button>
              <button
                type="button"
                onClick={handleBodyViewConfirm}
                disabled={isLoggingBodyView}
                className="px-4 py-2 rounded-lg bg-indigo-600 text-white text-sm font-medium hover:bg-indigo-700 disabled:opacity-60 transition-colors"
              >
                {isLoggingBodyView ? 'Registrant...' : 'Continuar'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Modal del cos del correu */}
      {showBody && log && (
        <EmailBodyViewerModal
          subject={log.subject}
          fromName={log.from_name}
          fromEmail={log.from_email}
          toEmails={log.to_emails}
          ccEmails={log.cc_emails}
          bccEmails={log.bcc_emails}
          replyTo={log.reply_to}
          htmlBody={log.html_body}
          textBody={log.text_body}
          onClose={() => setShowBody(false)}
        />
      )}
    </div>
  )
}
