import { useState, useCallback } from 'react'
import { useTranslation } from 'react-i18next'
import { useEmailLogs } from '../api/useEmailLogs'
import { useEmailLogsRealtime, type EmailAlertEvent } from '../api/useEmailLogsRealtime'
import { useEmailConfig } from '../api/useEmailConfig'
import { EmailLogDetailModal } from './EmailLogDetailModal'
import { Spinner } from '../../../components/ui/Spinner'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import {
  Table,
  TableHeader,
  TableBody,
  TableRow,
  TableHead,
  TableCell,
} from '@/components/ui/table'
import { toast } from '@/hooks/use-toast'
import { useTenant } from '../../../contexts/TenantContext'
import type { EmailLog, EmailLogStatus } from '../types'

const PAGE_SIZE = 15

const STATUS_BADGE_CLASS: Record<EmailLogStatus, string> = {
  queued: 'bg-muted text-muted-foreground border-0 hover:bg-muted',
  processing: 'bg-blue-100 text-blue-700 border-0 hover:bg-blue-100 dark:bg-blue-950/50 dark:text-blue-400',
  sent: 'bg-indigo-100 text-indigo-700 border-0 hover:bg-indigo-100 dark:bg-indigo-950/50 dark:text-indigo-400',
  delivered: 'bg-green-100 text-green-700 border-0 hover:bg-green-100 dark:bg-green-950/50 dark:text-green-400',
  bounced: 'bg-red-100 text-red-700 border-0 hover:bg-red-100 dark:bg-red-950/50 dark:text-red-400',
  failed: 'bg-red-100 text-red-700 border-0 hover:bg-red-100 dark:bg-red-950/50 dark:text-red-400',
}

const ALL_STATUSES: EmailLogStatus[] = [
  'queued',
  'processing',
  'sent',
  'delivered',
  'bounced',
  'failed',
]

/** Retorna la data ISO d'inici de fa N dies (mig dia corrent inclòs). */
function daysAgoIso(n: number): string {
  const d = new Date()
  d.setDate(d.getDate() - n)
  d.setHours(0, 0, 0, 0)
  return d.toISOString()
}

interface DateRange {
  label: string
  days: number | null
}

function buildDateRanges(retentionDays: number): DateRange[] {
  const ranges: DateRange[] = [{ label: '7d', days: 7 }]
  if (retentionDays >= 30) ranges.push({ label: '30d', days: 30 })
  if (retentionDays > 30) ranges.push({ label: 'all', days: null })
  return ranges
}

interface EmailLogsTabProps {
  tenantId: string
}

export function EmailLogsTab({ tenantId }: EmailLogsTabProps) {
  const { t } = useTranslation('email')
  const { data: config } = useEmailConfig(tenantId)
  const retentionDays = config?.retention_days ?? 7
  const maxRetries = config?.max_retries ?? 3
  
  const { selectedSiteId, sites, canUseAllSites } = useTenant()

  const dateRanges = buildDateRanges(retentionDays)

  const [page, setPage] = useState(0)
  const [statusFilter, setStatusFilter] = useState<EmailLogStatus | null>(null)
  const [selectedRange, setSelectedRange] = useState<DateRange>(dateRanges[0])
  const [selectedLog, setSelectedLog] = useState<EmailLog | null>(null)

  const dateFrom = selectedRange.days ? daysAgoIso(selectedRange.days) : null

  const { data, isLoading, isError, isFetching } = useEmailLogs(tenantId, {
    page,
    pageSize: PAGE_SIZE,
    siteId: selectedSiteId,
    status: statusFilter,
    dateFrom,
  })

  const handleAlert = useCallback(
    (event: EmailAlertEvent) => {
      const recipient = event.to_emails[0] ?? '—'
      const subject = event.subject ?? t('email.logs.no_subject', '(sense assumpte)')
      const statusLabel =
        event.status === 'bounced'
          ? t('email.logs.status_bounced', 'rebutjat')
          : t('email.logs.status_failed', 'fallit')

      const message = t(
        'email.logs.realtime_alert',
        `Correu ${statusLabel}: "${subject}" → ${recipient}`,
        { recipient, subject, status: statusLabel },
      )

      toast({
        title: t('email.logs.toast_title', 'Error de lliurament'),
        description: message,
        variant: 'destructive',
      })
    },
    [t],
  )

  useEmailLogsRealtime(tenantId, handleAlert)

  const totalPages = Math.ceil((data?.total ?? 0) / PAGE_SIZE)

  const handleRangeClick = (range: DateRange) => {
    setSelectedRange(range)
    setPage(0)
  }

  const handleStatusClick = (s: EmailLogStatus | null) => {
    setStatusFilter(s)
    setPage(0)
  }

  if (isLoading) {
    return (
      <div className="flex justify-center py-12">
        <Spinner />
      </div>
    )
  }

  if (isError) {
    return (
      <div className="rounded-lg border border-destructive/30 bg-destructive/10 p-5 text-sm text-destructive">
        {t('email.logs.load_error', "Error en carregar l'historial d'emails.")}
      </div>
    )
  }

  const logs = data?.data ?? []

  return (
    <div className="space-y-4">
      {/* Barra de filtres */}
      <div className="flex flex-wrap items-center gap-2">
        {/* Rang de dates */}
        <div className="flex items-center gap-1 rounded-lg border bg-muted/40 p-1">
          {dateRanges.map((range) => (
            <button
              key={range.label}
              type="button"
              onClick={() => handleRangeClick(range)}
              className={`rounded px-2.5 py-1 text-xs font-medium transition-colors ${
                selectedRange.label === range.label
                  ? 'bg-background shadow-sm text-foreground'
                  : 'text-muted-foreground hover:text-foreground'
              }`}
            >
              {range.label === 'all'
                ? t('email.logs.range_all', 'Tots')
                : t('email.logs.range_last_n_days', 'Darrers {{n}} dies', {
                    n: range.days,
                  })}
            </button>
          ))}
        </div>

        {/* Filtre d'estat */}
        <div className="flex items-center gap-1 flex-wrap">
          <button
            type="button"
            onClick={() => handleStatusClick(null)}
            className={`rounded-full px-2.5 py-0.5 text-xs font-medium border transition-colors ${
              statusFilter === null
                ? 'bg-foreground text-background border-foreground'
                : 'border-muted-foreground/30 text-muted-foreground hover:text-foreground'
            }`}
          >
            {t('email.logs.filter_all', 'Tots')}
          </button>
          {ALL_STATUSES.map((s) => (
            <button
              key={s}
              type="button"
              onClick={() => handleStatusClick(s)}
              className={`rounded-full px-2.5 py-0.5 text-xs font-medium border transition-colors ${
                statusFilter === s
                  ? 'bg-foreground text-background border-foreground'
                  : 'border-muted-foreground/30 text-muted-foreground hover:text-foreground'
              }`}
            >
              {t(`email.logs.status_${s}`, s)}
            </button>
          ))}
        </div>

        {/* Recompte + indicador temps real */}
        <div className="ml-auto flex items-center gap-3">
          <p className="text-sm text-muted-foreground">
            {t('email.logs.total_results', '{{total}} resultats', {
              total: data?.total ?? 0,
            })}
          </p>
          <span className="flex items-center gap-1.5 text-xs text-green-600 font-medium">
            <span className="inline-block h-2 w-2 rounded-full bg-green-400 animate-pulse" />
            {t('email.logs.realtime_active', 'Temps real actiu')}
          </span>
        </div>
      </div>

      {/* Taula de logs */}
      {logs.length === 0 ? (
        <div className="rounded-lg border border-dashed p-10 text-center">
          <p className="text-sm text-muted-foreground">
            {t('email.logs.empty', 'Encara no hi ha correus enviats.')}
          </p>
        </div>
      ) : (
        <div
          className={`rounded-lg border overflow-hidden transition-opacity ${isFetching ? 'opacity-70' : ''}`}
        >
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>{t('email.logs.col_date', 'Data')}</TableHead>
                {canUseAllSites && !selectedSiteId && (
                  <TableHead>{t('email.logs.col_site', 'Local')}</TableHead>
                )}
                <TableHead>{t('email.logs.col_from', 'De')}</TableHead>
                <TableHead>{t('email.logs.col_recipient', 'Destinatari')}</TableHead>
                <TableHead>{t('email.logs.col_subject', 'Assumpte')}</TableHead>
                <TableHead>{t('email.logs.col_attempts', 'Intents')}</TableHead>
                <TableHead>{t('email.logs.col_status', 'Estat')}</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {logs.map((log) => {
                const siteName = log.site_id ? (sites.find(s => s.id === log.site_id)?.name ?? log.site_id) : '—'
                return (
                  <TableRow
                    key={log.id}
                    className="cursor-pointer hover:bg-muted/50"
                    onClick={() => setSelectedLog(log)}
                  >
                    <TableCell className="text-muted-foreground whitespace-nowrap">
                      {new Date(log.created_at).toLocaleString('ca-ES', {
                        dateStyle: 'short',
                        timeStyle: 'short',
                      })}
                    </TableCell>
                    {canUseAllSites && !selectedSiteId && (
                      <TableCell className="max-w-32 truncate text-sm">
                        {siteName}
                      </TableCell>
                    )}
                    <TableCell className="max-w-40 truncate text-sm">
                      <span className="block truncate font-medium">
                        {log.from_name || '—'}
                      </span>
                      <span className="block truncate text-xs text-muted-foreground">
                        {log.from_email}
                      </span>
                    </TableCell>
                    <TableCell className="max-w-45 truncate">
                      {log.to_emails?.[0] ?? '—'}
                      {log.to_emails?.length > 1 && (
                        <span className="ml-1 text-xs text-muted-foreground">
                          +{log.to_emails.length - 1}
                        </span>
                      )}
                    </TableCell>
                    <TableCell className="max-w-55">
                      <span
                        className="block truncate text-sm"
                        title={log.subject ?? undefined}
                      >
                        {log.subject ?? (
                          <span className="italic text-muted-foreground">
                            {t('email.logs.no_subject', '(sense assumpte)')}
                          </span>
                        )}
                      </span>
                    </TableCell>
                    <TableCell className="text-sm">
                      {log.attempt_count} / {maxRetries}
                    </TableCell>
                    <TableCell>
                      <Badge className={STATUS_BADGE_CLASS[log.status]}>
                        {t(`email.logs.status_${log.status}`, log.status)}
                      </Badge>
                      {log.is_dead_letter && (
                        <span className="ml-2 text-xs text-destructive font-medium">
                          {t('email.logs.dead_letter', 'dead-letter')}
                        </span>
                      )}
                    </TableCell>
                  </TableRow>
                )
              })}
            </TableBody>
          </Table>
        </div>
      )}

      {/* Paginació */}
      {totalPages > 1 && (
        <div className="flex items-center justify-between pt-1">
          <Button
            variant="outline"
            size="sm"
            disabled={page === 0}
            onClick={() => setPage((p) => p - 1)}
          >
            {t('email.logs.prev_page', 'Anterior')}
          </Button>
          <span className="text-sm text-muted-foreground">
            {t('email.logs.page_of', 'Pàgina {{current}} de {{total}}', {
              current: page + 1,
              total: totalPages,
            })}
          </span>
          <Button
            variant="outline"
            size="sm"
            disabled={page >= totalPages - 1}
            onClick={() => setPage((p) => p + 1)}
          >
            {t('email.logs.next_page', 'Següent')}
          </Button>
        </div>
      )}

      {/* Modal de detall */}
      <EmailLogDetailModal
        log={selectedLog}
        open={selectedLog !== null}
        onClose={() => setSelectedLog(null)}
      />
    </div>
  )
}
