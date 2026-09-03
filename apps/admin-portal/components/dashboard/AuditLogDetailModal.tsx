'use client'

import { useState, useEffect, useTransition, useRef } from 'react'
import { useTranslation } from 'react-i18next'
import type { AuditLogDetail } from '@/app/admin/actions/audit-logs'
import { getAuditLogDetail } from '@/app/admin/actions/audit-logs'

// ---------------------------------------------------------------------------
// Action badge configuration
// ---------------------------------------------------------------------------

type BadgeVariant =
  | 'red' | 'green' | 'blue' | 'indigo' | 'purple' | 'orange' | 'yellow' | 'gray'

const ACTION_VARIANT: Record<string, BadgeVariant> = {
  TENANT_DEACTIVATED:         'red',
  TENANT_ACTIVATED:           'green',
  TENANT_PLAN_CHANGED:        'blue',
  TENANT_STORAGE_BLOCKED:     'orange',
  TENANT_STORAGE_UNBLOCKED:   'green',
  SITE_CREATED:               'green',
  SITE_ACTIVATED:             'green',
  SITE_DEACTIVATED:           'red',
  SITE_RENAMED:                'blue',
  MEMBER_INVITED:              'indigo',
  MEMBER_INVITE_EMAIL_SENT:    'indigo',
  MEMBER_ROLE_CHANGED:         'purple',
  MEMBER_ACTIVATED:            'green',
  MEMBER_DEACTIVATED:          'red',
  MEMBER_REMOVED:              'red',
  EMAIL_BODY_VIEWED:           'yellow',
  FILE_DELETED:                'red',
  FILE_UPLOADED:               'green',
  TENANT_MEMBER_DEACTIVATED:   'red',
  TENANT_MEMBER_ACTIVATED:     'green',
}

// Actions that get the "critical" severity marker
const CRITICAL_ACTIONS = new Set([
  'TENANT_DEACTIVATED',
  'TENANT_PLAN_CHANGED',
  'TENANT_STORAGE_BLOCKED',
  'MEMBER_ROLE_CHANGED',
  'MEMBER_REMOVED',
  'SITE_DEACTIVATED',
  'FILE_DELETED',
])

const BADGE_CLASSES: Record<BadgeVariant, string> = {
  red:    'bg-red-50 text-red-700 ring-1 ring-red-200',
  green:  'bg-emerald-50 text-emerald-700 ring-1 ring-emerald-200',
  blue:   'bg-blue-50 text-blue-700 ring-1 ring-blue-200',
  indigo: 'bg-indigo-50 text-indigo-700 ring-1 ring-indigo-200',
  purple: 'bg-purple-50 text-purple-700 ring-1 ring-purple-200',
  orange: 'bg-orange-50 text-orange-700 ring-1 ring-orange-200',
  yellow: 'bg-yellow-50 text-yellow-700 ring-1 ring-yellow-200',
  gray:   'bg-gray-100 text-gray-600 ring-1 ring-gray-200',
}

// ---------------------------------------------------------------------------
// ActionDetailsRegistry — per-action custom renderers (extensible)
// Add entries here to override the default JSON display for specific actions.
// Falls back to GenericPayloadRenderer for any unregistered action.
// ---------------------------------------------------------------------------

type ActionRenderer = (log: AuditLogDetail) => React.ReactNode

// Stub: ready for per-action renderers. Example:
// const ACTION_DETAILS_REGISTRY: Record<string, ActionRenderer> = {
//   TENANT_PLAN_CHANGED: (log) => (
//     <div className="grid grid-cols-2 gap-3 text-sm">
//       <div><span className="text-gray-500">Pla anterior:</span> {log.payload?.old_plan_name}</div>
//       <div><span className="text-gray-500">Pla nou:</span> {log.payload?.new_plan_name}</div>
//     </div>
//   ),
// }
const ACTION_DETAILS_REGISTRY: Record<string, ActionRenderer> = {}

// ---------------------------------------------------------------------------
// Helper components
// ---------------------------------------------------------------------------

function formatDate(iso: string | null | undefined): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleString('ca-ES', {
    day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  })
}

function Field({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div>
      <dt className="text-xs font-semibold text-gray-500 uppercase tracking-wide mb-0.5">
        {label}
      </dt>
      <dd className="text-sm text-gray-800 break-all">
        {value ?? <span className="text-gray-300">—</span>}
      </dd>
    </div>
  )
}

function ActionBadge({ action }: { action: string }) {
  const variant = ACTION_VARIANT[action] ?? 'gray'
  return (
    <span
      className={`inline-flex items-center rounded-full px-2.5 py-1 text-xs font-semibold font-mono ${BADGE_CLASSES[variant]}`}
    >
      {action}
    </span>
  )
}

function GenericPayloadRenderer({
  payload,
  tCopy,
  tCopied,
  tEmpty,
}: {
  payload: Record<string, unknown> | null
  tCopy: string
  tCopied: string
  tEmpty: string
}) {
  const [copied, setCopied] = useState(false)
  const jsonStr = payload != null ? JSON.stringify(payload, null, 2) : null

  if (jsonStr == null) {
    return <p className="text-xs text-gray-400 italic">{tEmpty}</p>
  }

  function handleCopy() {
    navigator.clipboard.writeText(jsonStr!).then(() => {
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    })
  }

  return (
    <div className="relative">
      <button
        onClick={handleCopy}
        className="absolute top-2 right-2 z-10 text-xs px-2 py-1 rounded bg-white border border-gray-200 text-gray-500 hover:text-gray-800 hover:border-gray-400 transition"
        aria-label={tCopy}
      >
        {copied ? tCopied : tCopy}
      </button>
      <pre className="bg-gray-50 border border-gray-200 rounded-lg p-3 pr-16 text-xs text-gray-700 overflow-x-auto overflow-y-auto max-h-72 whitespace-pre-wrap break-all">
        {jsonStr}
      </pre>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Skeleton loader
// ---------------------------------------------------------------------------

function ModalSkeleton() {
  return (
    <div className="space-y-3 animate-pulse">
      <div className="h-8 w-48 bg-gray-200 rounded-full" />
      <div className="h-4 w-32 bg-gray-100 rounded" />
      <div className="mt-4 grid grid-cols-2 gap-3">
        {[1, 2, 3, 4, 5, 6].map((i) => (
          <div key={i} className="h-10 bg-gray-100 rounded" />
        ))}
      </div>
      <div className="h-32 bg-gray-100 rounded-lg mt-4" />
    </div>
  )
}

// ---------------------------------------------------------------------------
// AuditLogDetailModal
// ---------------------------------------------------------------------------

interface Props {
  logId: string | null
  onClose: () => void
}

export function AuditLogDetailModal({ logId, onClose }: Props) {
  const { t } = useTranslation('activity')
  const [log, setLog] = useState<AuditLogDetail | null>(null)
  const [isPending, startTransition] = useTransition()
  const [error, setError] = useState<string | null>(null)
  const panelRef = useRef<HTMLDivElement>(null)

  // Load detail when logId changes
  useEffect(() => {
    if (!logId) {
      setLog(null)
      setError(null)
      return
    }
    setError(null)
    setLog(null)
    startTransition(async () => {
      try {
        const detail = await getAuditLogDetail(logId)
        setLog(detail)
        if (!detail) setError('Registre no trobat.')
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Error desconegut')
      }
    })
  }, [logId])

  // ESC to close + focus trap
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [onClose])

  // Focus panel on open for accessibility
  useEffect(() => {
    if (logId) {
      setTimeout(() => panelRef.current?.focus(), 50)
    }
  }, [logId])

  if (!logId) return null

  const isCritical = log ? CRITICAL_ACTIONS.has(log.action) : false
  const customRenderer = log ? ACTION_DETAILS_REGISTRY[log.action] : undefined

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center p-4 sm:p-6"
      role="dialog"
      aria-modal="true"
      aria-label={t('activity.modal.aria_label', 'Detall del registre d\'auditoria')}
    >
      {/* Backdrop */}
      <div
        className="absolute inset-0 bg-black/40 backdrop-blur-sm"
        onClick={onClose}
        aria-hidden="true"
      />

      {/* Panel */}
      <div
        ref={panelRef}
        tabIndex={-1}
        className="relative bg-white rounded-2xl shadow-2xl w-full max-w-2xl max-h-[92vh] flex flex-col outline-none"
      >
        {/* Sticky header */}
        <div className="flex items-start justify-between gap-3 px-6 py-4 border-b border-gray-100 rounded-t-2xl shrink-0">
          <div className="flex flex-wrap items-center gap-2 min-w-0">
            {log ? (
              <>
                <ActionBadge action={log.action} />
                {isCritical && (
                  <span className="inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium bg-red-100 text-red-800 ring-1 ring-red-300">
                    ⚠ {t('activity.modal.critical', 'Crític')}
                  </span>
                )}
                <span className="text-xs text-gray-400 whitespace-nowrap">
                  {formatDate(log.created_at)}
                </span>
              </>
            ) : (
              <div className="h-7 w-40 bg-gray-200 rounded-full animate-pulse" />
            )}
          </div>
          <button
            onClick={onClose}
            className="shrink-0 p-1 rounded-lg text-gray-400 hover:text-gray-700 hover:bg-gray-100 transition"
            aria-label={t('activity.modal.close', 'Tancar')}
          >
            <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" aria-hidden="true">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        {/* Scrollable body */}
        <div className="overflow-y-auto flex-1 px-6 py-5 space-y-6">
          {error && (
            <div className="rounded-lg bg-red-50 border border-red-200 p-4 text-sm text-red-700">
              {error}
            </div>
          )}

          {isPending && !log && <ModalSkeleton />}

          {log && (
            <>
              {/* Common fields */}
              <section>
                <h3 className="text-xs font-semibold uppercase tracking-wide text-gray-500 mb-3 pb-1 border-b border-gray-100">
                  {t('activity.modal.section_common', 'Dades comunes')}
                </h3>
                <dl className="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-3">
                  <Field
                    label={t('activity.modal.field_id', 'ID')}
                    value={<span className="font-mono text-xs">{log.id}</span>}
                  />
                  <Field
                    label={t('activity.modal.field_date', 'Data')}
                    value={formatDate(log.created_at)}
                  />
                  <Field
                    label={t('activity.modal.field_tenant', 'Tenant')}
                    value={
                      log.tenant_name ? (
                        <>
                          <span className="font-semibold">{log.tenant_name}</span>{' '}
                          <span className="text-gray-400 text-xs font-mono">({log.tenant_id})</span>
                        </>
                      ) : (
                        log.tenant_id && (
                          <span className="font-mono text-xs">{log.tenant_id}</span>
                        )
                      )
                    }
                  />
                  {log.site_id && (
                    <Field
                      label={t('activity.modal.field_site', 'Site')}
                      value={
                        log.site_name ? (
                          <>
                            <span className="font-semibold">{log.site_name}</span>{' '}
                            <span className="text-gray-400 text-xs font-mono">({log.site_id})</span>
                          </>
                        ) : (
                          <span className="font-mono text-xs">{log.site_id}</span>
                        )
                      }
                    />
                  )}
                  <Field
                    label={t('activity.modal.field_actor', 'Actor')}
                    value={
                      log.user_name || log.user_email ? (
                        <div>
                          {log.user_name && (
                            <span className="font-semibold block">{log.user_name}</span>
                          )}
                          {log.user_email && (
                            <span className="text-gray-500 text-xs">{log.user_email}</span>
                          )}
                          {log.user_id && (
                            <span className="text-gray-300 text-xs block font-mono">{log.user_id}</span>
                          )}
                        </div>
                      ) : (
                        <span className="italic text-gray-400">
                          {t('activity.modal.system', 'Sistema')}
                        </span>
                      )
                    }
                  />
                  <Field
                    label={t('activity.modal.field_entity_type', 'Tipus entitat')}
                    value={
                      log.entity_type && (
                        <span className="font-mono text-xs bg-gray-100 px-1.5 py-0.5 rounded">
                          {log.entity_type}
                        </span>
                      )
                    }
                  />
                  {log.entity_id && (
                    <Field
                      label={t('activity.modal.field_entity_id', 'ID entitat')}
                      value={<span className="font-mono text-xs">{log.entity_id}</span>}
                    />
                  )}
                  {log.ip_address && (
                    <Field
                      label={t('activity.modal.field_ip', 'Adreça IP')}
                      value={<span className="font-mono text-xs">{log.ip_address}</span>}
                    />
                  )}
                </dl>
              </section>

              {/* Payload */}
              <section>
                <h3 className="text-xs font-semibold uppercase tracking-wide text-gray-500 mb-3 pb-1 border-b border-gray-100">
                  {t('activity.modal.section_payload', 'Payload')}
                </h3>
                {customRenderer ? (
                  customRenderer(log)
                ) : (
                  <GenericPayloadRenderer
                    payload={log.payload}
                    tCopy={t('activity.modal.copy_payload', 'Copiar')}
                    tCopied={t('activity.modal.copied', '✓ Copiat')}
                    tEmpty={t('activity.modal.payload_empty', 'No hi ha payload per a aquest registre.')}
                  />
                )}
              </section>

              {/* Related logs link */}
              {log.entity_type && log.entity_id && (
                <section className="pt-1">
                  <a
                    href={`/dashboard/activity?entityType=${encodeURIComponent(log.entity_type)}&search=${encodeURIComponent(log.entity_id)}`}
                    className="inline-flex items-center gap-1.5 text-xs font-medium text-indigo-600 hover:text-indigo-800 transition"
                    onClick={onClose}
                  >
                    <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" aria-hidden="true">
                      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2}
                        d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14" />
                    </svg>
                    {t('activity.modal.see_related', 'Veure logs relacionats (mateixa entitat)')}
                  </a>
                </section>
              )}
            </>
          )}
        </div>
      </div>
    </div>
  )
}
