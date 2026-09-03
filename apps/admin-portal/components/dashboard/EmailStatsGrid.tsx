'use client'

import { useState, useTransition, useEffect, useRef } from 'react'
import { useTranslation } from 'react-i18next'
import {
  getEmailMetrics,
  type EmailMetrics,
  type GetEmailLogsParams,
} from '@/app/admin/actions/email-logs'
import { EmailVolumeChart } from './charts/EmailVolumeChart'
import { EmailDonutChart } from './charts/EmailDonutChart'
import { EmailTopIssuesChart } from './charts/EmailTopIssuesChart'
import { EmailLatencyChart } from './charts/EmailLatencyChart'

// ---------------------------------------------------------------------------
// localStorage hook — remembers which extra charts are pinned to the grid
// ---------------------------------------------------------------------------

const PINNED_KEY = 'email_stats_pinned_charts'

interface PinnedCharts {
  latency: boolean
  topIssues: boolean
}

function usePinnedCharts() {
  const [pinned, setPinned] = useState<PinnedCharts>({ latency: false, topIssues: false })

  useEffect(() => {
    try {
      const stored = localStorage.getItem(PINNED_KEY)
      if (stored) setPinned(JSON.parse(stored) as PinnedCharts)
    } catch {
      // ignore
    }
  }, [])

  function toggle(key: keyof PinnedCharts) {
    setPinned((prev) => {
      const next = { ...prev, [key]: !prev[key] }
      try {
        localStorage.setItem(PINNED_KEY, JSON.stringify(next))
      } catch {
        // ignore
      }
      return next
    })
  }

  return { pinned, toggle }
}

// ---------------------------------------------------------------------------
// Skeleton
// ---------------------------------------------------------------------------

function ChartSkeleton({ className }: { className: string }) {
  return (
    <div
      className={`${className} animate-pulse rounded-lg bg-gray-100`}
      aria-hidden="true"
    />
  )
}

// ---------------------------------------------------------------------------
// ChartModal — generic modal wrapper with pin/unpin button
// ---------------------------------------------------------------------------

interface ChartModalProps {
  title: string
  isPinned: boolean
  onTogglePin: () => void
  onClose: () => void
  children: React.ReactNode
}

function ChartModal({ title, isPinned, onTogglePin, onClose, children }: ChartModalProps) {
  const { t } = useTranslation('email_logs')

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center p-4"
      aria-modal="true"
      role="dialog"
    >
      <div
        className="absolute inset-0 bg-black/40"
        onClick={onClose}
        aria-hidden="true"
      />
      <div className="relative z-10 w-full max-w-2xl bg-white rounded-2xl shadow-2xl flex flex-col max-h-[85vh]">
        <div className="flex items-center justify-between px-6 py-4 border-b border-gray-100 shrink-0">
          <h3 className="text-sm font-semibold text-gray-900">{title}</h3>
          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={() => { onTogglePin(); onClose() }}
              className={`inline-flex items-center gap-1.5 rounded-full px-3 py-1 text-xs font-medium border transition-colors ${
                isPinned
                  ? 'bg-indigo-600 border-indigo-600 text-white hover:bg-indigo-700'
                  : 'bg-white border-indigo-300 text-indigo-700 hover:bg-indigo-50'
              }`}
            >
              📌{' '}
              {isPinned
                ? t('email_logs.stats.unpin_chart', 'Desafixar')
                : t('email_logs.stats.pin_chart', 'Fixar al panell')}
            </button>
            <button
              type="button"
              onClick={onClose}
              className="rounded-full p-1.5 text-gray-400 hover:text-gray-600 hover:bg-gray-100 transition-colors"
              aria-label={t('email_logs.detail.close', 'Tancar')}
            >
              <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>
        </div>
        <div className="px-6 py-5 overflow-y-auto flex-1">{children}</div>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Props
// ---------------------------------------------------------------------------

interface EmailStatsGridProps {
  initialMetrics: EmailMetrics
  filters: GetEmailLogsParams
}

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------

export function EmailStatsGrid({ initialMetrics, filters }: EmailStatsGridProps) {
  const { t } = useTranslation('email_logs')
  const [metrics, setMetrics] = useState<EmailMetrics>(initialMetrics)
  const [isLoading, startTransition] = useTransition()
  const isFirst = useRef(true)
  const { pinned, toggle } = usePinnedCharts()
  const [openModal, setOpenModal] = useState<'latency' | 'topIssues' | null>(null)

  useEffect(() => {
    if (isFirst.current) {
      isFirst.current = false
      return
    }
    startTransition(async () => {
      const next = await getEmailMetrics({
        dateFrom: filters.dateFrom,
        dateTo: filters.dateTo,
        tenantId: filters.tenantId,
        siteId: filters.siteId,
      })
      setMetrics(next)
    })
    // Re-run only when committed filter values change (not page/search)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [filters.dateFrom, filters.dateTo, filters.tenantId, filters.siteId])

  const topIssuesTitle = filters.tenantId
    ? t('email_logs.stats.top_sites', 'Sites més actius')
    : t('email_logs.stats.top_issues', 'Tenants amb més incidències')

  return (
    <>
      {/* ------------------------------------------------------------------ */}
      {/* Main grid                                                            */}
      {/* ------------------------------------------------------------------ */}
      <div
        className={`grid grid-cols-1 md:grid-cols-3 gap-4 transition-opacity duration-200 ${
          isLoading ? 'opacity-60 pointer-events-none' : ''
        }`}
      >
        {/* Daily volume — always visible, spans 2 cols */}
        <div className="md:col-span-2 rounded-xl border border-gray-200 bg-white p-4">
          <h3 className="text-sm font-semibold text-gray-700 mb-3">
            {t('email_logs.stats.daily_evolution', 'Evolució diària')}
          </h3>
          {isLoading ? (
            <ChartSkeleton className="h-48" />
          ) : (
            <EmailVolumeChart data={metrics.daily_volume} />
          )}
        </div>

        {/* Donut — always visible */}
        <div className="rounded-xl border border-gray-200 bg-white p-4">
          <h3 className="text-sm font-semibold text-gray-700 mb-3">
            {t('email_logs.stats.delivery_summary', 'Resum de lliurament')}
          </h3>
          {isLoading ? (
            <ChartSkeleton className="h-48" />
          ) : (
            <EmailDonutChart data={metrics.status_totals} />
          )}
        </div>

        {/* Latency — optional, shown when pinned */}
        {pinned.latency && (
          <div className="md:col-span-2 rounded-xl border border-indigo-200 bg-white p-4">
            <div className="flex items-center justify-between mb-3">
              <h3 className="text-sm font-semibold text-gray-700">
                ⏱️ {t('email_logs.stats.avg_latency', 'Latència Mitjana')}
              </h3>
              <button
                type="button"
                onClick={() => toggle('latency')}
                title={t('email_logs.stats.unpin_chart', 'Desafixar')}
                className="text-xs text-indigo-400 hover:text-indigo-700"
              >
                📌 {t('email_logs.stats.unpin_chart', 'Desafixar')}
              </button>
            </div>
            {isLoading ? (
              <ChartSkeleton className="h-48" />
            ) : (
              <EmailLatencyChart data={metrics.daily_volume} />
            )}
          </div>
        )}

        {/* Top Issues — optional, shown when pinned */}
        {pinned.topIssues && (
          <div className="md:col-span-3 rounded-xl border border-indigo-200 bg-white p-4">
            <div className="flex items-center justify-between mb-3">
              <h3 className="text-sm font-semibold text-gray-700">🏢 {topIssuesTitle}</h3>
              <button
                type="button"
                onClick={() => toggle('topIssues')}
                title={t('email_logs.stats.unpin_chart', 'Desafixar')}
                className="text-xs text-indigo-400 hover:text-indigo-700"
              >
                📌 {t('email_logs.stats.unpin_chart', 'Desafixar')}
              </button>
            </div>
            {isLoading ? (
              <ChartSkeleton className="h-24" />
            ) : (
              <EmailTopIssuesChart data={metrics.top_issues} />
            )}
          </div>
        )}
      </div>

      {/* ------------------------------------------------------------------ */}
      {/* Extra metrics badge zone                                            */}
      {/* ------------------------------------------------------------------ */}
      <div className="flex flex-wrap items-center gap-2 pt-1">
        <span className="text-xs font-medium text-gray-400">
          {t('email_logs.stats.extra_metrics', 'Mètriques addicionals')}:
        </span>

        <button
          type="button"
          onClick={() => setOpenModal('latency')}
          className={`inline-flex items-center gap-1 rounded-full px-3 py-1 text-xs font-medium border transition-colors ${
            pinned.latency
              ? 'bg-indigo-600 border-indigo-600 text-white'
              : 'bg-indigo-50 border-indigo-200 text-indigo-700 hover:bg-indigo-100'
          }`}
        >
          ⏱️ {t('email_logs.stats.avg_latency', 'Latència Mitjana')}
          {pinned.latency && <span className="ml-0.5 opacity-80">📌</span>}
        </button>

        <button
          type="button"
          onClick={() => setOpenModal('topIssues')}
          className={`inline-flex items-center gap-1 rounded-full px-3 py-1 text-xs font-medium border transition-colors ${
            pinned.topIssues
              ? 'bg-indigo-600 border-indigo-600 text-white'
              : 'bg-indigo-50 border-indigo-200 text-indigo-700 hover:bg-indigo-100'
          }`}
        >
          🏢 {t('email_logs.stats.site_analysis', 'Anàlisi per Site/Tenant')}
          {pinned.topIssues && <span className="ml-0.5 opacity-80">📌</span>}
        </button>
      </div>

      {/* ------------------------------------------------------------------ */}
      {/* Latency modal                                                        */}
      {/* ------------------------------------------------------------------ */}
      {openModal === 'latency' && (
        <ChartModal
          title={`⏱️ ${t('email_logs.stats.avg_latency', 'Latència Mitjana')}`}
          isPinned={pinned.latency}
          onTogglePin={() => toggle('latency')}
          onClose={() => setOpenModal(null)}
        >
          <EmailLatencyChart data={metrics.daily_volume} />
        </ChartModal>
      )}

      {/* ------------------------------------------------------------------ */}
      {/* Top Issues modal                                                     */}
      {/* ------------------------------------------------------------------ */}
      {openModal === 'topIssues' && (
        <ChartModal
          title={`🏢 ${topIssuesTitle}`}
          isPinned={pinned.topIssues}
          onTogglePin={() => toggle('topIssues')}
          onClose={() => setOpenModal(null)}
        >
          <EmailTopIssuesChart data={metrics.top_issues} />
        </ChartModal>
      )}
    </>
  )
}
