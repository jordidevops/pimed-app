import React from 'react'
import { Edit, UserCheck, UserX, User, ChevronRight } from 'lucide-react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import type { Employee } from '../api/employeesService'
import type { EmployeeStatus } from '../schemas/employeeSchema'
import { EmployeeAvatar } from './EmployeePhotoUploader'

const STATUS_CLASS: Record<EmployeeStatus, string> = {
  active: 'bg-emerald-100 text-emerald-700 border-emerald-200',
  inactive: 'bg-amber-100 text-amber-700 border-amber-200',
  terminated: 'bg-muted text-muted-foreground border-border',
}

const STATUS_ICON: Record<EmployeeStatus, React.ReactNode> = {
  active: <UserCheck className="h-3.5 w-3.5" aria-hidden />,
  inactive: <User className="h-3.5 w-3.5" aria-hidden />,
  terminated: <UserX className="h-3.5 w-3.5" aria-hidden />,
}

interface EmployeeRowProps {
  employee: Employee
  departmentName?: string
  siteName?: string
  positionName?: string
  onEdit: (emp: Employee) => void
  canWrite: boolean
}

export function EmployeeRow({
  employee,
  departmentName,
  siteName,
  positionName,
  onEdit,
  canWrite,
}: EmployeeRowProps) {
  const { t } = useTranslation('employees')
  const empStatus = (employee.status ?? 'active') as EmployeeStatus

  const statusLabels: Record<EmployeeStatus, string> = {
    active: t('employees.status.active', 'Actiu'),
    inactive: t('employees.status.inactive', 'Inactiu'),
    terminated: t('employees.status.terminated', 'Baixa definitiva'),
  }

  const displayName = employee.preferred_name?.trim() || employee.full_name

  return (
    <div className="flex items-center gap-3 px-4 py-3 rounded-xl border border-border bg-card hover:bg-accent/30 transition-colors">
      <EmployeeAvatar
        fullName={employee.full_name}
        preferredName={employee.preferred_name}
        photoObjectPath={employee.photo_object_path}
        size="sm"
      />

      <div className="flex-1 min-w-0">
        <Link
          to={`/employees/${employee.id}`}
          className="text-sm font-medium text-foreground hover:text-primary hover:underline truncate block"
        >
          {displayName ?? '—'}
        </Link>
        <div className="flex items-center gap-2 mt-0.5 flex-wrap">
          {employee.employee_code ? (
            <span className="text-xs text-muted-foreground/60">{employee.employee_code}</span>
          ) : null}
          {positionName ? (
            <span className="text-xs text-muted-foreground truncate">{positionName}</span>
          ) : null}
          {departmentName && (
            <span className="text-xs text-muted-foreground/60">· {departmentName}</span>
          )}
          {siteName && (
            <span className="text-xs text-muted-foreground/60">· {siteName}</span>
          )}
        </div>
      </div>

      <div className="hidden md:block text-xs text-muted-foreground truncate max-w-40">
        {employee.email ?? ''}
      </div>

      <Badge
        variant="outline"
        className={`flex items-center gap-1 text-xs font-medium shrink-0 ${STATUS_CLASS[empStatus]}`}
      >
        {STATUS_ICON[empStatus]}
        {statusLabels[empStatus]}
      </Badge>

      {canWrite && (
        <Button
          variant="ghost"
          size="icon"
          className="h-8 w-8 shrink-0"
          onClick={() => onEdit(employee)}
          aria-label={t('employees.actions.edit', 'Editar')}
        >
          <Edit className="h-4 w-4" />
        </Button>
      )}
      <Button
        variant="ghost"
        size="icon"
        className="h-8 w-8 shrink-0"
        asChild
        aria-label={t('employees.actions.view_detail', 'Veure detall')}
      >
        <Link to={`/employees/${employee.id}`}>
          <ChevronRight className="h-4 w-4" />
        </Link>
      </Button>
    </div>
  )
}
