'use client'

import { useState, useTransition } from 'react'
import { useTranslation } from 'react-i18next'
import {
  type QueueMetricsResult,
  getQueueMetrics,
  purgeQueue,
} from '@/app/admin/actions/queue-metrics'
import { QueueMessagesTable } from './QueueMessagesTable'
import { EmailLogDetailModal } from './EmailLogDetailModal'

interface QueueMonitorDashboardProps {
  initialMetrics: QueueMetricsResult
}

// ---------------------------------------------------------------------------
// Purge confirmation modal
// ---------------------------------------------------------------------------

interface PurgeConfirmModalProps {
  onConfirm: () => void
  onCancel: () => void
  isPurging: boolean
  t: ReturnType<typeof useTranslation>['t']
}

function PurgeConfirmModal({ onConfirm, onCancel, isPurging, t }: PurgeConfirmModalProps) {
  const [step, setStep] = useState<1 | 2>(1)

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      {/* Backdrop */}
      <div
        className="absolute inset-0 bg-black/40 backdrop-blur-sm"
        onClick={!isPurging ? onCancel : undefined}
        aria-hidden="true"
      />

      {/* Dialog */}
      <div className="relative z-10 w-full max-w-md rounded-xl bg-white shadow-xl ring-1 ring-gray-200 p-6 space-y-4">
        <div className="flex items-start gap-3">
          <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-red-100">
            <span className="text-red-600 text-lg">⚠</span>
          </div>
          <div>
            <h2 className="text-base font-semibold text-gray-900">
              {step === 1
                ? t('email_logs.queue_monitor.purge_modal_title_1', 'Purgar la cua?')
                : t('email_logs.queue_monitor.purge_modal_title_2', 'Darrera confirmació')}
            </h2>
            <p className="mt-1 text-sm text-gray-600">
              {step === 1
                ? t(
                    'email_logs.queue_monitor.purge_modal_body_1',
                    'Això eliminarà tots els missatges pendents de la cua email_send_queue. Els correus encuats es perdran de forma permanent.',
                  )
                : t(
                    'email_logs.queue_monitor.purge_modal_body_2',
                    'Confirmes que vols purgar la cua? Aquesta acció és irreversible i no es pot desfer.',
                  )}
            </p>
          </div>
        </div>

        <div className="flex justify-end gap-2 pt-2">
          <button
            type="button"
            onClick={onCancel}
            disabled={isPurging}
            className="h-9 px-4 rounded-md border border-gray-300 text-sm text-gray-700 hover:bg-gray-50 disabled:opacity-50"
          >
            {t('email_logs.queue_monitor.purge_modal_cancel', 'Cancel·lar')}
          </button>

          {step === 1 ? (
            <button
              type="button"
              onClick={() => setStep(2)}
              className="h-9 px-4 rounded-md bg-red-600 text-sm font-medium text-white hover:bg-red-700"
            >
              {t('email_logs.queue_monitor.purge_modal_next', 'Continuar →')}
            </button>
          ) : (
            <button
              type="button"
              onClick={onConfirm}
              disabled={isPurging}
              className="h-9 px-4 rounded-md bg-red-600 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
            >
              {isPurging
                ? t('email_logs.queue_monitor.purging', 'Purgant…')
                : t('email_logs.queue_monitor.purge_modal_confirm', 'Sí, purgar')}
            </button>
          )}
        </div>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function formatLatency(seconds: number, t: ReturnType<typeof useTranslation>['t']): string {
  if (seconds < 60) {
    return t('email_logs.queue_monitor.latency_seconds', '{{count}} segons', { count: seconds })
  }
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) {
    return t('email_logs.queue_monitor.latency_minutes', '{{count}} minuts', { count: minutes })
  }
  const hours = Math.floor(minutes / 60)
  return t('email_logs.queue_monitor.latency_hours', '{{count}} hores', { count: hours })
}

function formatDateTime(value: string): string {
  return new Date(value).toLocaleString('ca-ES', {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  })
}

// ---------------------------------------------------------------------------
// Main component
// ---------------------------------------------------------------------------

export function QueueMonitorDashboard({ initialMetrics }: QueueMonitorDashboardProps) {
  const { t } = useTranslation('email_logs')

  const [data, setData] = useState(initialMetrics)
  const [refreshCounter, setRefreshCounter] = useState(0)
  const [errorMessage, setErrorMessage] = useState<string | null>(null)
  const [showPurgeModal, setShowPurgeModal] = useState(false)
  const [selectedLogId, setSelectedLogId] = useState<string | null>(null)
  const [isRefreshing, startRefreshTransition] = useTransition()
  const [isPurging, startPurgeTransition] = useTransition()
  const isAvailable = data.available

  const queueLengthClass =
    data.metrics.queue_length > 100
      ? 'text-red-600'
      : data.metrics.queue_length > 50
        ? 'text-orange-600'
        : 'text-gray-900'

  function handleRefresh() {
    setErrorMessage(null)
    startRefreshTransition(async () => {
      try {
        const nextMetrics = await getQueueMetrics()
        setData(nextMetrics)
        setRefreshCounter((c) => c + 1)
      } catch (error) {
        setErrorMessage(
          error instanceof Error
            ? error.message
            : t('email_logs.queue_monitor.refresh_error', 'No s\'han pogut refrescar les mètriques'),
        )
      }
    })
  }

  function handlePurgeConfirm() {
    startPurgeTransition(async () => {
      try {
        await purgeQueue()
        const nextMetrics = await getQueueMetrics()
        setData(nextMetrics)
        setRefreshCounter((c) => c + 1)
        setShowPurgeModal(false)
      } catch (error) {
        setShowPurgeModal(false)
        setErrorMessage(
          error instanceof Error
            ? error.message
            : t('email_logs.queue_monitor.purge_error', 'No s\'ha pogut executar la purga de la cua'),
        )
      }
    })
  }

  return (
    <>
      {showPurgeModal && (
        <PurgeConfirmModal
          onConfirm={handlePurgeConfirm}
          onCancel={() => setShowPurgeModal(false)}
          isPurging={isPurging}
          t={t}
        />
      )}

      {selectedLogId && (
        <EmailLogDetailModal
          logId={selectedLogId}
          onClose={() => setSelectedLogId(null)}
        />
      )}

      <section className="rounded-xl border border-gray-200 bg-white p-4 md:p-5 space-y-4">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h2 className="text-base font-semibold text-gray-900">
              {t('email_logs.queue_monitor.title', 'Queue Monitor Dashboard')}
            </h2>
            <p className="text-sm text-gray-500">
              {t(
                'email_logs.queue_monitor.subtitle',
                'Salut i rendiment tècnic de la cua asíncrona de correus (pgmq).',
              )}
            </p>
          </div>

          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={handleRefresh}
              disabled={isRefreshing || isPurging}
              className="h-9 px-3 rounded-md border border-gray-300 text-sm text-gray-700 hover:bg-gray-50 disabled:opacity-50"
            >
              {isRefreshing
                ? t('email_logs.queue_monitor.refreshing', 'Refrescant…')
                : t('email_logs.queue_monitor.refresh', 'Refrescar')}
            </button>

            <button
              type="button"
              onClick={() => setShowPurgeModal(true)}
              disabled={isPurging || isRefreshing || !isAvailable}
              className="h-9 px-3 rounded-md border border-red-300 bg-red-50 text-sm text-red-700 hover:bg-red-100 disabled:opacity-50"
              title={
                !isAvailable
                  ? t(
                      'email_logs.queue_monitor.purge_unavailable',
                      'Purga no disponible: manca permisos sobre pgmq.',
                    )
                  : undefined
              }
            >
              {t('email_logs.queue_monitor.purge', 'Purgar cua')}
            </button>
          </div>
        </div>

        {!isAvailable && (
          <div className="rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-800">
            {data.error_message ??
              t(
                'email_logs.queue_monitor.unavailable',
                'Monitor no disponible: no hi ha permisos per llegir pgmq.',
              )}
          </div>
        )}

        {errorMessage && (
          <div className="rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
            {errorMessage}
          </div>
        )}

        <div className="grid gap-3 md:grid-cols-3">
          <article className="rounded-lg border border-gray-200 bg-gray-50 p-4">
            <p className="text-xs font-semibold uppercase tracking-wide text-gray-500">
              {t('email_logs.queue_monitor.card_pending', 'Missatges pendents')}
            </p>
            <p className={`mt-2 text-2xl font-semibold ${queueLengthClass}`}>
              {data.metrics.queue_length.toLocaleString('ca-ES')}
            </p>
            <p className="mt-1 text-xs text-gray-500">
              {data.metrics.queue_length > 100
                ? t('email_logs.queue_monitor.pending_warning', 'Alerta: cua amb acumulació alta')
                : t('email_logs.queue_monitor.pending_ok', 'Ritme de cua dins del rang normal')}
            </p>
          </article>

          <article className="rounded-lg border border-gray-200 bg-gray-50 p-4">
            <p className="text-xs font-semibold uppercase tracking-wide text-gray-500">
              {t('email_logs.queue_monitor.card_max_latency', 'Latència màxima')}
            </p>
            <p className="mt-2 text-2xl font-semibold text-gray-900">
              {formatLatency(data.metrics.oldest_msg_age_sec, t)}
            </p>
            <p className="mt-1 text-xs text-gray-500">
              {t('email_logs.queue_monitor.latency_hint', 'Antiguitat del missatge més vell pendent')}
            </p>
          </article>

          <article className="rounded-lg border border-gray-200 bg-gray-50 p-4">
            <p className="text-xs font-semibold uppercase tracking-wide text-gray-500">
              {t('email_logs.queue_monitor.card_archive', 'Volum històric processat')}
            </p>
            <p className="mt-2 text-2xl font-semibold text-gray-900">
              {data.archive_count.toLocaleString('ca-ES')}
            </p>
            <p className="mt-1 text-xs text-gray-500">
              {t('email_logs.queue_monitor.archive_hint', 'Total de missatges processats amb èxit (arxiu)')}
            </p>
          </article>
        </div>

        <p className="text-xs text-gray-500">
          {t('email_logs.queue_monitor.last_scrape', 'Última lectura de mètriques: {{date}}', {
            date: formatDateTime(data.metrics.scrape_time),
          })}
        </p>

        <hr className="border-gray-100" />

        <QueueMessagesTable refreshTrigger={refreshCounter} onOpenLog={setSelectedLogId} />
      </section>
    </>
  )
}
