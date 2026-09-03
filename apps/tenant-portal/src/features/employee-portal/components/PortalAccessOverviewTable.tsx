import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { AlertTriangle, MoreHorizontal } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import type {
  PortalAccessOverviewRow,
  PortalAccessTokenSummary,
} from '../api/employeePortalOverviewTypes'
import { hasEmployeeDocumentId } from '../utils/portalDocumentId'

function formatWhen(value: string | null | undefined): string {
  if (!value) return '—'
  try {
    return new Date(value).toLocaleString()
  } catch {
    return value
  }
}

function personalLinkLabel(
  t: (key: string, fallback: string) => string,
  personal: PortalAccessTokenSummary,
): { label: string; variant: 'default' | 'secondary' | 'outline' | 'destructive' } {
  if (!personal.has_active) {
    return {
      label: t('employees.portal_hub.personal_none', 'Sense enllaç'),
      variant: 'outline',
    }
  }
  if (!personal.first_accessed_at) {
    return {
      label: t('employees.portal_hub.personal_never_opened', 'Mai obert'),
      variant: 'secondary',
    }
  }
  return {
    label: t('employees.portal_hub.personal_active', 'Actiu'),
    variant: 'default',
  }
}

function pinLabel(
  t: (key: string, fallback: string) => string,
  personal: PortalAccessTokenSummary,
): string {
  if (!personal.has_active) return '—'
  const pinRequired =
    personal.pin_required ??
    Boolean(personal.pin_must_set || personal.pin_configured)
  if (!pinRequired) {
    return t('employees.portal_hub.pin_not_required', 'No requerit')
  }
  if (personal.pin_configured) {
    return t('employees.portal_hub.pin_configured', 'Configurat')
  }
  return t('employees.portal_hub.pin_pending', 'Pendent')
}

function employeeStatusLabel(
  t: (key: string, fallback: string) => string,
  status: string | null,
): { label: string; variant: 'default' | 'secondary' | 'outline' | 'destructive' } {
  if (status === 'inactive') {
    return {
      label: t('employees.status.inactive', 'Inactiu'),
      variant: 'secondary',
    }
  }
  if (status === 'terminated') {
    return {
      label: t('employees.status.terminated', 'Baixa definitiva'),
      variant: 'outline',
    }
  }
  return {
    label: t('employees.status.active', 'Actiu'),
    variant: 'default',
  }
}

interface PortalAccessOverviewTableProps {
  rows: PortalAccessOverviewRow[]
  selectedIds: Set<string>
  onToggleSelect: (employeeId: string) => void
  onToggleSelectAll: (employeeIds: string[], selected: boolean) => void
  selectableIds: string[]
  onGeneratePersonal?: (row: PortalAccessOverviewRow) => void
  onSendEmail?: (row: PortalAccessOverviewRow) => void
  onRevoke?: (row: PortalAccessOverviewRow) => void
}

export function PortalAccessOverviewTable({
  rows,
  selectedIds,
  onToggleSelect,
  onToggleSelectAll,
  selectableIds,
  onGeneratePersonal,
  onSendEmail,
  onRevoke,
}: PortalAccessOverviewTableProps) {
  const { t } = useTranslation('employees')

  const allSelected =
    selectableIds.length > 0 && selectableIds.every((id) => selectedIds.has(id))
  const someSelected = selectableIds.some((id) => selectedIds.has(id))

  return (
    <div className="overflow-auto rounded-xl border">
      <table className="w-full text-sm">
        <thead className="bg-muted/50 sticky top-0">
          <tr>
            <th className="w-10 px-3 py-2">
              <Checkbox
                checked={allSelected ? true : someSelected ? 'indeterminate' : false}
                onCheckedChange={(checked) =>
                  onToggleSelectAll(selectableIds, checked === true)
                }
                disabled={selectableIds.length === 0}
                aria-label={t('employees.portal_hub.select_all', 'Seleccionar tots')}
              />
            </th>
            <th className="text-left px-3 py-2 font-medium">
              {t('employees.portal_hub.col_name', 'Nom')}
            </th>
            <th className="text-left px-3 py-2 font-medium">
              {t('employees.portal_hub.col_document', 'DNI/NIE')}
            </th>
            <th className="text-left px-3 py-2 font-medium hidden md:table-cell">
              {t('employees.portal_hub.col_site', 'Local')}
            </th>
            <th className="text-left px-3 py-2 font-medium hidden sm:table-cell">
              {t('employees.portal_hub.col_employee_status', 'Estat empleat')}
            </th>
            <th className="text-left px-3 py-2 font-medium">
              {t('employees.portal_hub.col_personal', 'Personal')}
            </th>
            <th className="text-left px-3 py-2 font-medium hidden lg:table-cell">
              {t('employees.portal_hub.col_pin', 'PIN')}
            </th>
            <th className="text-left px-3 py-2 font-medium hidden xl:table-cell">
              {t('employees.portal_hub.col_last_access', 'Últim accés')}
            </th>
            <th className="text-left px-3 py-2 font-medium hidden xl:table-cell">
              {t('employees.portal_hub.col_link_created', 'Creat enllaç')}
            </th>
            <th className="w-10 px-3 py-2" />
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => {
            const selectable =
              row.status === 'active' && hasEmployeeDocumentId(row.document_id)
            const personal = personalLinkLabel(t, row.personal)
            const employeeStatus = employeeStatusLabel(t, row.status)
            const dimmed = row.status !== 'active'
            const canGenerate =
              row.status === 'active' && hasEmployeeDocumentId(row.document_id)
            const canEmail =
              canGenerate && Boolean(row.email?.trim()) && row.personal.has_active
            const canRevoke = row.personal.has_active

            return (
              <tr
                key={row.employee_id}
                className={`border-t ${dimmed ? 'opacity-60' : ''}`}
              >
                <td className="px-3 py-2 align-middle">
                  {selectable ? (
                    <Checkbox
                      checked={selectedIds.has(row.employee_id)}
                      onCheckedChange={() => onToggleSelect(row.employee_id)}
                      aria-label={t('employees.batch.select_employee', 'Seleccionar {{name}}', {
                        name: row.full_name ?? '',
                      })}
                    />
                  ) : (
                    <span
                      className="inline-block h-4 w-4 rounded border border-dashed border-muted-foreground/40"
                      title={t(
                        'employees.batch.skip_missing_document',
                        'Sense DNI/NIE: afegeix-lo a la fitxa abans de generar l\'enllaç.',
                      )}
                      aria-hidden
                    />
                  )}
                </td>
                <td className="px-3 py-2 align-middle">
                  <Link
                    to={`/employees/${row.employee_id}?tab=portal_access`}
                    className="font-medium hover:text-primary hover:underline"
                  >
                    {row.full_name ?? '—'}
                  </Link>
                  {!row.site_configured ? (
                    <span
                      className="ml-1 inline-flex text-amber-600"
                      title={t(
                        'employees.portal_hub.site_not_configured',
                        'Falta configurar l\'adreça del portal',
                      )}
                    >
                      <AlertTriangle className="h-3.5 w-3.5" aria-hidden />
                    </span>
                  ) : null}
                </td>
                <td className="px-3 py-2 align-middle">
                  {row.missing_document_id ? (
                    <Badge variant="outline" className="text-amber-800 border-amber-400">
                      {t('employees.portal_hub.missing_document_badge', 'Incomplet')}
                    </Badge>
                  ) : (
                    <span className="text-muted-foreground">{row.document_id ?? '—'}</span>
                  )}
                </td>
                <td className="px-3 py-2 align-middle text-muted-foreground hidden md:table-cell">
                  {row.site_name ?? '—'}
                </td>
                <td className="px-3 py-2 align-middle hidden sm:table-cell">
                  <Badge variant={employeeStatus.variant}>{employeeStatus.label}</Badge>
                </td>
                <td className="px-3 py-2 align-middle">
                  <Badge variant={personal.variant}>{personal.label}</Badge>
                </td>
                <td className="px-3 py-2 align-middle text-muted-foreground hidden lg:table-cell">
                  {pinLabel(t, row.personal)}
                </td>
                <td className="px-3 py-2 align-middle text-muted-foreground hidden xl:table-cell">
                  {formatWhen(row.last_access_any)}
                </td>
                <td className="px-3 py-2 align-middle text-muted-foreground hidden xl:table-cell">
                  {formatWhen(row.personal.created_at)}
                </td>
                <td className="px-3 py-2 align-middle">
                  <DropdownMenu>
                    <DropdownMenuTrigger asChild>
                      <Button variant="ghost" size="icon" className="h-8 w-8">
                        <MoreHorizontal className="h-4 w-4" />
                        <span className="sr-only">
                          {t('employees.portal_hub.row_actions', 'Accions')}
                        </span>
                      </Button>
                    </DropdownMenuTrigger>
                    <DropdownMenuContent align="end">
                      <DropdownMenuItem asChild>
                        <Link to={`/employees/${row.employee_id}`}>
                          {t('employees.portal_hub.action_profile', 'Obrir fitxa')}
                        </Link>
                      </DropdownMenuItem>
                      <DropdownMenuItem asChild>
                        <Link to={`/employees/${row.employee_id}?tab=portal_access`}>
                          {t('employees.portal_hub.action_portal_access', 'Gestionar accés')}
                        </Link>
                      </DropdownMenuItem>
                      <DropdownMenuSeparator />
                      <DropdownMenuItem
                        disabled={!canGenerate}
                        onClick={() => onGeneratePersonal?.(row)}
                      >
                        {t('employees.portal_hub.action_generate_personal', 'Generar personal')}
                      </DropdownMenuItem>
                      <DropdownMenuItem disabled={!canEmail} onClick={() => onSendEmail?.(row)}>
                        {t('employees.portal_hub.action_send_email', 'Enviar correu')}
                      </DropdownMenuItem>
                      <DropdownMenuItem
                        disabled={!canRevoke}
                        className="text-destructive focus:text-destructive"
                        onClick={() => onRevoke?.(row)}
                      >
                        {t('employees.portal_hub.action_revoke', 'Revocar')}
                      </DropdownMenuItem>
                    </DropdownMenuContent>
                  </DropdownMenu>
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
      {rows.length === 0 ? (
        <p className="text-sm text-muted-foreground text-center py-10">
          {t('employees.portal_hub.empty', 'Cap empleat coincideix amb els filtres.')}
        </p>
      ) : null}
    </div>
  )
}
