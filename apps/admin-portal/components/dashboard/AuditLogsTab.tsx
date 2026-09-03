'use client'

import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { AuditLogRow } from '@/app/admin/actions/tenants'
import { AuditLogDetailModal } from './AuditLogDetailModal'

interface Props {
  logs: AuditLogRow[]
}

// ---------------------------------------------------------------------------
// Color-coding per acció
// ---------------------------------------------------------------------------
type BadgeVariant = 'red' | 'green' | 'blue' | 'indigo' | 'purple' | 'orange' | 'gray'

const ACTION_VARIANT: Record<string, BadgeVariant> = {
  TENANT_DEACTIVATED:       'red',
  TENANT_ACTIVATED:         'green',
  TENANT_PLAN_CHANGED:      'blue',
  TENANT_STORAGE_BLOCKED:   'orange',
  TENANT_STORAGE_UNBLOCKED: 'green',
  SITE_CREATED:             'green',
  SITE_ACTIVATED:           'green',
  SITE_DEACTIVATED:         'red',
  SITE_RENAMED:             'blue',
  MEMBER_INVITED:           'indigo',
  MEMBER_INVITE_EMAIL_SENT: 'indigo',
  MEMBER_ROLE_CHANGED:      'purple',
  MEMBER_ACTIVATED:         'green',
  MEMBER_DEACTIVATED:       'red',
  MEMBER_REMOVED:           'red',
}

const BADGE_CLASSES: Record<BadgeVariant, string> = {
  red:    'bg-red-50 text-red-700 ring-1 ring-red-200',
  green:  'bg-emerald-50 text-emerald-700 ring-1 ring-emerald-200',
  blue:   'bg-blue-50 text-blue-700 ring-1 ring-blue-200',
  indigo: 'bg-indigo-50 text-indigo-700 ring-1 ring-indigo-200',
  purple: 'bg-purple-50 text-purple-700 ring-1 ring-purple-200',
  orange: 'bg-orange-50 text-orange-700 ring-1 ring-orange-200',
  gray:   'bg-gray-100 text-gray-600 ring-1 ring-gray-200',
}

function ActionBadge({ action, label }: { action: string; label: string }) {
  const variant = ACTION_VARIANT[action] ?? 'gray'
  return (
    <span className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${BADGE_CLASSES[variant]}`}>
      {label}
    </span>
  )
}

function formatDate(iso: string): string {
  return new Date(iso).toLocaleString('ca-ES', {
    day:    '2-digit',
    month:  '2-digit',
    year:   'numeric',
    hour:   '2-digit',
    minute: '2-digit',
  })
}

function PayloadSummary({ payload }: { payload: Record<string, unknown> | null }) {
  if (!payload) return <span className="text-gray-300">—</span>

  // Mostrem els camps més rellevants, excloent UUIDs llargs
  const entries = Object.entries(payload).filter(
    ([k]) => !k.endsWith('_id') || k === 'site_id',
  )

  if (entries.length === 0) return <span className="text-gray-300">—</span>

  return (
    <ul className="space-y-0.5">
      {entries.slice(0, 4).map(([k, v]) => (
        <li key={k} className="text-xs text-gray-500">
          <span className="font-medium text-gray-600">{k}:</span>{' '}
          <span>{String(v ?? '—')}</span>
        </li>
      ))}
    </ul>
  )
}

export function AuditLogsTab({ logs }: Props) {
  const { t } = useTranslation('tenants')
  const [selectedLogId, setSelectedLogId] = useState<string | null>(null)

  if (logs.length === 0) {
    return (
      <div className="bg-white rounded-2xl border border-gray-100 p-8 text-center shadow-sm">
        <p className="text-sm text-gray-400">
          {t('tenants.detail.audit.empty', 'No hi ha activitat registrada per a aquest tenant.')}
        </p>
      </div>
    )
  }

  return (
    <div className="bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
      <div className="px-6 py-4 border-b border-gray-100">
        <h2 className="text-sm font-semibold text-gray-700">
          {t('tenants.detail.audit.title', 'Registre d\'activitat')}
        </h2>
        <p className="text-xs text-gray-400 mt-0.5">
          {t('tenants.detail.audit.subtitle', 'Últims {{count}} registres', { count: logs.length })}
        </p>
      </div>

      <div className="overflow-x-auto">
        <table className="min-w-full text-sm">
          <thead>
            <tr className="bg-gray-50 border-b border-gray-100 text-left">
              <th className="px-4 py-3 text-xs font-semibold text-gray-500 uppercase tracking-wide whitespace-nowrap">
                {t('tenants.detail.audit.col_date', 'Data')}
              </th>
              <th className="px-4 py-3 text-xs font-semibold text-gray-500 uppercase tracking-wide">
                {t('tenants.detail.audit.col_action', 'Acció')}
              </th>
              <th className="px-4 py-3 text-xs font-semibold text-gray-500 uppercase tracking-wide">
                {t('tenants.detail.audit.col_entity', 'Entitat')}
              </th>
              <th className="px-4 py-3 text-xs font-semibold text-gray-500 uppercase tracking-wide">
                {t('tenants.detail.audit.col_actor', 'Realitzat per')}
              </th>
              <th className="px-4 py-3 text-xs font-semibold text-gray-500 uppercase tracking-wide">
                {t('tenants.detail.audit.col_details', 'Detalls')}
              </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-50">
            {logs.map((log) => {
              const actionLabel = t(
                `tenants.detail.audit.actions.${log.action}`,
                log.action,
              )
              const actor = log.user_name ?? log.user_email
              return (
                <tr
                  key={log.id}
                  className="hover:bg-indigo-50/40 cursor-pointer transition-colors"
                  onClick={() => setSelectedLogId(log.id)}
                  role="button"
                  tabIndex={0}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter' || e.key === ' ') {
                      e.preventDefault()
                      setSelectedLogId(log.id)
                    }
                  }}
                  aria-label={`Veure detall del log ${log.action}`}
                >
                  <td className="px-4 py-3 text-xs text-gray-500 whitespace-nowrap align-top">
                    {formatDate(log.created_at)}
                  </td>
                  <td className="px-4 py-3 align-top">
                    <ActionBadge action={log.action} label={actionLabel} />
                  </td>
                  <td className="px-4 py-3 align-top">
                    {log.entity_type ? (
                      <span className="text-xs text-gray-600 font-mono">
                        {log.entity_type}
                      </span>
                    ) : (
                      <span className="text-gray-300 text-xs">—</span>
                    )}
                  </td>
                  <td className="px-4 py-3 align-top">
                    {actor ? (
                      <span className="text-xs text-gray-700">{actor}</span>
                    ) : (
                      <span className="text-xs italic text-gray-400">
                        {t('tenants.detail.audit.system', 'Sistema')}
                      </span>
                    )}
                  </td>
                  <td className="px-4 py-3 align-top max-w-xs">
                    <PayloadSummary payload={log.payload} />
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>

      <AuditLogDetailModal
        logId={selectedLogId}
        onClose={() => setSelectedLogId(null)}
      />
    </div>
  )
}
