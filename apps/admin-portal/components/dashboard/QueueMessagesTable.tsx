'use client'

import { useState, useTransition, useEffect, useRef } from 'react'
import { useTranslation } from 'react-i18next'
import {
  type ActiveQueueMessage,
  type GetQueueMessagesParams,
  getActiveQueueMessages,
} from '@/app/admin/actions/queue-metrics'

type SortColumn = 'msg_id' | 'enqueued_at' | 'vt'

interface QueueMessagesTableProps {
  refreshTrigger?: number
  onOpenLog?: (logId: string) => void
}

function formatDateTime(iso: string): string {
  return new Date(iso).toLocaleString('ca-ES', {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  })
}

function formatDuration(ms: number): string {
  if (ms < 1000) return `${Math.round(ms)} ms`
  const totalSecs = Math.round(ms / 1000)
  if (totalSecs < 60) return `${totalSecs}s`
  const h = Math.floor(totalSecs / 3600)
  const m = Math.floor((totalSecs % 3600) / 60)
  const s = totalSecs % 60
  if (h > 0) return `${h}h ${m}m ${s}s`
  return `${m}m ${s}s`
}

function isInFuture(iso: string): boolean {
  return new Date(iso) > new Date()
}

export function QueueMessagesTable({ refreshTrigger = 0, onOpenLog }: QueueMessagesTableProps) {
  const { t } = useTranslation('email_logs')

  const [messages, setMessages] = useState<ActiveQueueMessage[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const pageSize = 20
  const [sortColumn, setSortColumn] = useState<SortColumn>('msg_id')
  const [sortAsc, setSortAsc] = useState(false)
  const [searchInput, setSearchInput] = useState('')
  const [committedSearch, setCommittedSearch] = useState('')
  const [isPending, startTransition] = useTransition()
  const prevTrigger = useRef(-1)

  function fetchData(params: GetQueueMessagesParams) {
    startTransition(async () => {
      try {
        const result = await getActiveQueueMessages(params)
        setMessages(result.messages)
        setTotal(result.total)
      } catch {
        // ignore — metrics card already shows unavailable state
      }
    })
  }

  // Initial load
  useEffect(() => {
    fetchData({ page: 1, pageSize, sortColumn: 'msg_id', sortAsc: false })
    prevTrigger.current = refreshTrigger
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // External refresh (parent increments refreshTrigger after purge/refresh)
  useEffect(() => {
    if (prevTrigger.current === -1 || prevTrigger.current === refreshTrigger) return
    prevTrigger.current = refreshTrigger
    setPage(1)
    fetchData({ page: 1, pageSize, sortColumn, sortAsc, search: committedSearch || undefined })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [refreshTrigger])

  function handleSort(col: SortColumn) {
    const newAsc = sortColumn === col ? !sortAsc : false
    setSortColumn(col)
    setSortAsc(newAsc)
    setPage(1)
    fetchData({ page: 1, pageSize, sortColumn: col, sortAsc: newAsc, search: committedSearch || undefined })
  }

  function handleSearch() {
    setCommittedSearch(searchInput)
    setPage(1)
    fetchData({ page: 1, pageSize, sortColumn, sortAsc, search: searchInput || undefined })
  }

  function clearSearch() {
    setSearchInput('')
    setCommittedSearch('')
    setPage(1)
    fetchData({ page: 1, pageSize, sortColumn, sortAsc, search: undefined })
  }

  function goToPage(newPage: number) {
    setPage(newPage)
    fetchData({ page: newPage, pageSize, sortColumn, sortAsc, search: committedSearch || undefined })
  }

  const totalPages = Math.max(1, Math.ceil(total / pageSize))

  function SortBtn({ colKey, label }: { colKey: SortColumn; label: string }) {
    const isActive = sortColumn === colKey
    return (
      <button
        type="button"
        onClick={() => handleSort(colKey)}
        className="inline-flex items-center gap-0.5 group hover:text-gray-700 font-semibold uppercase tracking-wide text-xs"
      >
        {label}
        <span className="text-[9px] ml-0.5 text-gray-300 group-hover:text-gray-400">
          {isActive ? (sortAsc ? '▲' : '▼') : '↕'}
        </span>
      </button>
    )
  }

  return (
    <div className="space-y-3">
      {/* Header */}
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h3 className="text-sm font-semibold text-gray-800">
          {t('email_logs.queue_monitor.messages_title', 'Missatges actius a la cua')}
        </h3>
        <span className="text-xs text-gray-500">
          {isPending
            ? t('email_logs.queue_monitor.loading', 'Carregant…')
            : total === 0
              ? t('email_logs.queue_monitor.messages_empty_count', '0 missatges')
              : t('email_logs.queue_monitor.messages_count', '{{count}} missatges', { count: total })}
        </span>
      </div>

      {/* Search */}
      <div className="flex gap-1">
        <div className="relative">
          <input
            type="text"
            value={searchInput}
            onChange={(e) => setSearchInput(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && handleSearch()}
            placeholder={t('email_logs.queue_monitor.search_placeholder', 'Tenant, Log ID…')}
            className="h-8 w-56 rounded-md border border-gray-300 px-2 pr-7 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500"
          />
          {searchInput && (
            <button
              type="button"
              onClick={clearSearch}
              className="absolute right-2 top-1/2 -translate-y-1/2 text-gray-400 hover:text-gray-600 text-sm leading-none"
              aria-label={t('email_logs.queue_monitor.clear_search', 'Esborrar cerca')}
            >
              ✕
            </button>
          )}
        </div>
        <button
          type="button"
          onClick={handleSearch}
          className="h-8 px-3 rounded-md bg-indigo-600 text-white text-sm hover:bg-indigo-700"
        >
          {t('email_logs.queue_monitor.search_btn', 'Cercar')}
        </button>
      </div>

      {messages.length === 0 && !isPending ? (
        <div className="flex flex-col items-center justify-center rounded-lg border border-dashed border-green-300 bg-green-50 py-8 text-center">
          <span className="text-2xl">✓</span>
          <p className="mt-2 text-sm font-medium text-green-700">
            {t('email_logs.queue_monitor.messages_empty_title', 'Cua buida')}
          </p>
          <p className="mt-1 text-xs text-green-600">
            {t('email_logs.queue_monitor.messages_empty_hint', 'No hi ha missatges pendents. Estat ideal.')}
          </p>
        </div>
      ) : (
        <div className={`overflow-x-auto rounded-lg border border-gray-200 transition-opacity ${isPending ? 'opacity-50' : ''}`}>
          <table className="min-w-full divide-y divide-gray-200 text-sm">
            <thead className="bg-gray-50">
              <tr>
                <th className="whitespace-nowrap px-3 py-2.5 text-left">
                  <SortBtn colKey="msg_id" label={t('email_logs.queue_monitor.col_msg_id', 'Msg ID')} />
                </th>
                <th className="whitespace-nowrap px-3 py-2.5 text-left text-xs font-semibold uppercase tracking-wide text-gray-500">
                  {t('email_logs.queue_monitor.col_tenant', 'Tenant')}
                </th>
                <th className="whitespace-nowrap px-3 py-2.5 text-left">
                  <SortBtn colKey="enqueued_at" label={t('email_logs.queue_monitor.col_enqueued_at', 'Creat el')} />
                </th>
                <th className="whitespace-nowrap px-3 py-2.5 text-left text-xs font-semibold uppercase tracking-wide text-gray-500">
                  {t('email_logs.queue_monitor.col_time_in_queue', 'Temps a la cua')}
                </th>
                <th className="whitespace-nowrap px-3 py-2.5 text-left">
                  <SortBtn colKey="vt" label={t('email_logs.queue_monitor.col_vt', 'Bloquejat fins a')} />
                </th>
                <th className="whitespace-nowrap px-3 py-2.5 text-left text-xs font-semibold uppercase tracking-wide text-gray-500">
                  {t('email_logs.queue_monitor.col_read_ct', 'Intents')}
                </th>
                <th className="whitespace-nowrap px-3 py-2.5 text-left text-xs font-semibold uppercase tracking-wide text-gray-500">
                  {t('email_logs.queue_monitor.col_priority', 'Prioritat')}
                </th>
                <th className="whitespace-nowrap px-3 py-2.5 text-left text-xs font-semibold uppercase tracking-wide text-gray-500">
                  {t('email_logs.queue_monitor.col_log_id', 'Log ID')}
                </th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 bg-white">
              {messages.map((msg) => {
                const vtFuture = isInFuture(msg.vt)
                return (
                  <tr key={msg.msg_id} className="hover:bg-gray-50">
                    <td className="whitespace-nowrap px-3 py-2.5 font-mono text-xs text-gray-700">
                      {msg.msg_id}
                    </td>
                    <td className="whitespace-nowrap px-3 py-2.5 text-xs text-gray-700">
                      {msg.tenant_name ?? msg.tenant_id ?? '—'}
                    </td>
                    <td className="whitespace-nowrap px-3 py-2.5 text-xs text-gray-600">
                      {formatDateTime(msg.enqueued_at)}
                    </td>
                    <td className="whitespace-nowrap px-3 py-2.5 text-xs">
                      <span
                        className={
                          msg.time_in_queue_ms > 15 * 60 * 1000
                            ? 'font-bold text-red-600'
                            : msg.time_in_queue_ms > 5 * 60 * 1000
                              ? 'font-bold text-orange-500'
                              : 'text-gray-600'
                        }
                      >
                        {formatDuration(msg.time_in_queue_ms)}
                      </span>
                    </td>
                    <td className="whitespace-nowrap px-3 py-2.5 text-xs">
                      <span
                        className={vtFuture ? 'font-medium text-amber-700' : 'text-gray-500'}
                        title={vtFuture ? t('email_logs.queue_monitor.vt_future_hint', 'Missatge ocult pel Worker (visibility timeout actiu)') : undefined}
                      >
                        {formatDateTime(msg.vt)}
                        {vtFuture && (
                          <span className="ml-1 inline-flex items-center rounded-full bg-amber-100 px-1.5 py-0.5 text-[10px] font-medium text-amber-800">
                            VT
                          </span>
                        )}
                      </span>
                    </td>
                    <td className="whitespace-nowrap px-3 py-2.5 text-xs">
                      <span
                        className={msg.read_ct > 0 ? 'font-semibold text-red-600' : 'text-gray-500'}
                        title={msg.read_ct > 0 ? t('email_logs.queue_monitor.read_ct_hint', 'El Worker ha intentat processar aquest missatge {{count}} cop/s', { count: msg.read_ct }) : undefined}
                      >
                        {msg.read_ct}
                      </span>
                    </td>
                    <td className="whitespace-nowrap px-3 py-2.5 text-xs text-gray-600">
                      {msg.priority ?? '—'}
                    </td>
                    <td className="px-3 py-2.5">
                      {msg.email_log_id ? (
                        <div className="flex items-center gap-1">
                          <span className="font-mono text-[11px] text-gray-500 break-all">
                            {msg.email_log_id}
                          </span>
                          {onOpenLog && (
                            <button
                              type="button"
                              onClick={() => onOpenLog(msg.email_log_id!)}
                              className="shrink-0 text-indigo-500 hover:text-indigo-700 text-sm"
                              title={t('email_logs.queue_monitor.col_open_log', 'Veure log')}
                            >
                              🔗
                            </button>
                          )}
                        </div>
                      ) : (
                        <span className="text-xs text-gray-400">—</span>
                      )}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}

      {/* Pagination */}
      {totalPages > 1 && (
        <div className="flex items-center justify-between text-sm text-gray-600">
          <span>
            {t('email_logs.queue_monitor.pagination_info', 'Pàgina {{current}} de {{total}}', { current: page, total: totalPages })}
          </span>
          <div className="flex items-center gap-1">
            <button
              type="button"
              onClick={() => goToPage(1)}
              disabled={page <= 1 || isPending}
              className="px-2 py-1 rounded border border-gray-300 disabled:opacity-40 hover:bg-gray-50 font-mono"
              title={t('email_logs.queue_monitor.first_page', 'Primera pàgina')}
            >
              «
            </button>
            <button
              type="button"
              onClick={() => goToPage(page - 1)}
              disabled={page <= 1 || isPending}
              className="px-3 py-1 rounded border border-gray-300 disabled:opacity-40 hover:bg-gray-50"
            >
              ← {t('email_logs.queue_monitor.prev_page', 'Anterior')}
            </button>
            <button
              type="button"
              onClick={() => goToPage(page + 1)}
              disabled={page >= totalPages || isPending}
              className="px-3 py-1 rounded border border-gray-300 disabled:opacity-40 hover:bg-gray-50"
            >
              {t('email_logs.queue_monitor.next_page', 'Següent')} →
            </button>
            <button
              type="button"
              onClick={() => goToPage(totalPages)}
              disabled={page >= totalPages || isPending}
              className="px-2 py-1 rounded border border-gray-300 disabled:opacity-40 hover:bg-gray-50 font-mono"
              title={t('email_logs.queue_monitor.last_page', 'Última pàgina')}
            >
              »
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
