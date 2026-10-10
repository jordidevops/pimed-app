import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'

type SiteOption = { id: string; name: string }

type SiteScopeFilterProps = {
  sites: SiteOption[]
  /** null = all sites (when canSelectAll). */
  value: string | null
  onChange: (siteId: string | null) => void
  canSelectAll?: boolean
  className?: string
  /** 'pills' for quick filters, 'select' for compact toolbars. */
  variant?: 'pills' | 'select'
}

/** Table / list filter for tenant operational locals (`data.sites`). */
export function SiteScopeFilter({
  sites,
  value,
  onChange,
  canSelectAll = true,
  className,
  variant = 'pills',
}: SiteScopeFilterProps) {
  const { t } = useTranslation('common')

  if (sites.length <= 1) return null

  if (variant === 'select') {
    return (
      <label className={cn('flex min-w-[10rem] flex-col gap-1 text-xs text-muted-foreground', className)}>
        {t('select_site', 'Selecciona local')}
        <select
          className="h-10 rounded-md border border-input bg-background px-3 text-sm text-foreground"
          value={value ?? ''}
          onChange={(e) => onChange(e.target.value || null)}
        >
          {canSelectAll ? (
            <option value="">{t('all_sites', 'Tots els locals')}</option>
          ) : null}
          {sites.map((site) => (
            <option key={site.id} value={site.id}>
              {site.name}
            </option>
          ))}
        </select>
      </label>
    )
  }

  return (
    <div className={cn('flex flex-wrap gap-1.5', className)} role="group" aria-label={t('select_site', 'Selecciona local')}>
      {canSelectAll ? (
        <Button
          type="button"
          size="sm"
          variant={value == null ? 'default' : 'outline'}
          className="h-7 rounded-full px-2.5 text-xs"
          onClick={() => onChange(null)}
        >
          {t('all_sites', 'Tots els locals')}
        </Button>
      ) : null}
      {sites.map((site) => (
        <Button
          key={site.id}
          type="button"
          size="sm"
          variant={value === site.id ? 'default' : 'outline'}
          className="h-7 rounded-full px-2.5 text-xs"
          onClick={() => onChange(site.id)}
        >
          {site.name}
        </Button>
      ))}
    </div>
  )
}
