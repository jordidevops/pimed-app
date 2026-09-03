import type { JobPosting, JobPostingStatus } from '../api/recruitmentService'

/** Human-facing capture readiness (not raw DB status alone). */
export type CaptureStatus = 'live' | 'needs_publish' | 'unlisted' | 'closed'

export function getCaptureStatus(
  posting: Pick<JobPosting, 'status'> & { public_site_count?: number },
  publicSiteCount?: number,
): CaptureStatus {
  const sites = publicSiteCount ?? posting.public_site_count ?? 0
  const status: JobPostingStatus = posting.status
  if (status === 'archived' || status === 'expired') return 'closed'
  if (status === 'unlisted') return 'unlisted'
  if (status === 'published' && sites >= 1) return 'live'
  return 'needs_publish'
}

export function captureStatusBadgeClass(status: CaptureStatus): string {
  switch (status) {
    case 'live':
      return 'border-emerald-200 bg-emerald-50 text-emerald-800 dark:border-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-300'
    case 'needs_publish':
      return 'border-amber-200 bg-amber-50 text-amber-900 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-200'
    case 'unlisted':
      return 'border-slate-200 bg-slate-50 text-slate-700 dark:border-slate-700 dark:bg-slate-900/40 dark:text-slate-300'
    case 'closed':
      return 'border-muted bg-muted text-muted-foreground'
  }
}

export function initialsFromName(name: string | null | undefined): string {
  if (!name?.trim()) return '?'
  const parts = name.trim().split(/\s+/).slice(0, 2)
  return parts.map((p) => p[0]?.toUpperCase() ?? '').join('') || '?'
}

export function relativeDaysLabel(iso: string, t: (key: string, opts?: Record<string, unknown>) => string): string {
  const then = new Date(iso).getTime()
  const days = Math.max(0, Math.floor((Date.now() - then) / 86_400_000))
  if (days === 0) return t('time.today')
  if (days === 1) return t('time.yesterday')
  return t('time.days_ago', { count: days })
}

export function humanSourceKey(source: string): string {
  const known = ['web', 'qr', 'whatsapp', 'email', 'manual', 'csv_import'] as const
  if ((known as readonly string[]).includes(source)) return `source.${source}`
  return 'source.other'
}
