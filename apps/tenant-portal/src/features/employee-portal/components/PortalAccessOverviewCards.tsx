import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { KeyRound, LogIn, MoreHorizontal } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { cn } from '@/lib/utils'
import type { PortalAccessOverviewRow } from '../api/employeePortalOverviewTypes'
import { hasEmployeeDocumentId } from '../utils/portalDocumentId'
import { EmployeeAvatar } from '@/features/employees/components/EmployeePhotoUploader'

function PortalStatusIcons({ row }: { row: PortalAccessOverviewRow }) {
  const { t } = useTranslation('employees')
  const hasAccess = row.personal.has_active
  const hasAccessed = Boolean(row.personal.first_accessed_at || row.last_access_any)

  const accessTitle = hasAccess
    ? t('employees.portal_hub.icon_has_access', 'Té enllaç d\'accés al portal')
    : t('employees.portal_hub.icon_no_access', 'Sense enllaç d\'accés')
  const visitedTitle = !hasAccess
    ? t('employees.portal_hub.icon_not_applicable', 'Sense accés')
    : hasAccessed
      ? t('employees.portal_hub.icon_has_visited', 'Ha accedit al portal')
      : t('employees.portal_hub.icon_never_visited', 'Encara no ha accedit')

  return (
    <div className="flex items-center gap-1" data-testid="portal-status-icons">
      <span
        title={accessTitle}
        aria-label={accessTitle}
        className={cn(
          'inline-flex h-7 w-7 items-center justify-center rounded-full border',
          hasAccess
            ? 'border-emerald-200 bg-emerald-50 text-emerald-700'
            : 'border-border bg-muted/60 text-muted-foreground',
        )}
      >
        <KeyRound className="h-3.5 w-3.5" aria-hidden />
      </span>
      <span
        title={visitedTitle}
        aria-label={visitedTitle}
        className={cn(
          'inline-flex h-7 w-7 items-center justify-center rounded-full border',
          !hasAccess
            ? 'border-border bg-muted/40 text-muted-foreground/50'
            : hasAccessed
              ? 'border-sky-200 bg-sky-50 text-sky-700'
              : 'border-amber-200 bg-amber-50 text-amber-800',
        )}
      >
        <LogIn className="h-3.5 w-3.5" aria-hidden />
      </span>
    </div>
  )
}

interface PortalAccessOverviewCardsProps {
  rows: PortalAccessOverviewRow[]
  selectedIds: Set<string>
  selectableIds: string[]
  onToggleSelect: (employeeId: string) => void
  onGeneratePersonal: (row: PortalAccessOverviewRow) => void
  onSendEmail: (row: PortalAccessOverviewRow) => void
  onRevoke: (row: PortalAccessOverviewRow) => void
}

export function PortalAccessOverviewCards({
  rows,
  selectedIds,
  selectableIds,
  onToggleSelect,
  onGeneratePersonal,
  onSendEmail,
  onRevoke,
}: PortalAccessOverviewCardsProps) {
  const { t } = useTranslation('employees')
  const selectableSet = new Set(selectableIds)

  if (rows.length === 0) {
    return (
      <p className="rounded-xl border border-dashed px-4 py-10 text-center text-sm text-muted-foreground">
        {t('employees.portal_hub.empty', 'Cap empleat amb els filtres actuals')}
      </p>
    )
  }

  return (
    <div
      className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4"
      data-testid="portal-access-cards"
    >
      {rows.map((row) => {
        const canSelect = selectableSet.has(row.employee_id)
        const selected = selectedIds.has(row.employee_id)
        const name = row.full_name || '—'

        return (
          <article
            key={row.employee_id}
            className={cn(
              'group relative flex flex-col gap-3 rounded-2xl border border-border bg-card p-4 shadow-sm transition-shadow hover:shadow-md',
              selected && 'border-primary/50 ring-1 ring-primary/30',
            )}
          >
            <div className="flex items-start gap-3">
              {canSelect ? (
                <Checkbox
                  checked={selected}
                  onCheckedChange={() => onToggleSelect(row.employee_id)}
                  aria-label={t('employees.portal_hub.select_employee', 'Seleccionar {{name}}', {
                    name,
                  })}
                  className="mt-1"
                />
              ) : (
                <span className="mt-1 h-4 w-4 shrink-0" />
              )}
              <Link to={`/employees/${row.employee_id}`} className="min-w-0 flex-1 outline-none">
                <div className="flex items-center gap-3">
                  <EmployeeAvatar fullName={row.full_name} size="lg" />
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-semibold text-foreground group-hover:text-primary">
                      {name}
                    </p>
                    {row.site_name ? (
                      <p className="truncate text-xs text-muted-foreground">{row.site_name}</p>
                    ) : null}
                  </div>
                </div>
              </Link>
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <Button type="button" variant="ghost" size="icon" className="h-8 w-8 shrink-0">
                    <MoreHorizontal className="h-4 w-4" />
                  </Button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end">
                  <DropdownMenuItem asChild>
                    <Link to={`/employees/${row.employee_id}`}>
                      {t('employees.actions.view_detail', 'Veure detall')}
                    </Link>
                  </DropdownMenuItem>
                  <DropdownMenuSeparator />
                  {!row.personal.has_active ? (
                    <DropdownMenuItem
                      disabled={!hasEmployeeDocumentId(row.document_id) || row.status !== 'active'}
                      onClick={() => onGeneratePersonal(row)}
                    >
                      {t('employees.portal_hub.action_generate', 'Generar enllaç')}
                    </DropdownMenuItem>
                  ) : (
                    <>
                      <DropdownMenuItem
                        disabled={!row.email?.trim()}
                        onClick={() => onSendEmail(row)}
                      >
                        {t('employees.portal_hub.action_send_email', 'Enviar / regenerar')}
                      </DropdownMenuItem>
                      <DropdownMenuItem onClick={() => onRevoke(row)}>
                        {t('employees.portal_hub.action_revoke', 'Revocar')}
                      </DropdownMenuItem>
                    </>
                  )}
                </DropdownMenuContent>
              </DropdownMenu>
            </div>

            <div className="flex items-center justify-between gap-2 border-t border-border/60 pt-3">
              <PortalStatusIcons row={row} />
              <p className="text-[11px] text-muted-foreground">
                {row.personal.has_active
                  ? row.personal.first_accessed_at
                    ? t('employees.portal_hub.personal_active', 'Actiu')
                    : t('employees.portal_hub.personal_never_opened', 'Mai obert')
                  : t('employees.portal_hub.personal_none', 'Sense enllaç')}
              </p>
            </div>
          </article>
        )
      })}
    </div>
  )
}
