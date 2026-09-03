import { Edit, Mail, MapPin, Building2 } from 'lucide-react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import type { Employee } from '../api/employeesService'
import type { EmployeeStatus } from '../schemas/employeeSchema'
import { useEmployeeAvatarSrc } from '../api/useEmployeePhoto'
import { EmployeeAvatar } from './EmployeePhotoUploader'
import { EmployeePortalStatusIcon } from '@/features/employee-portal/components/EmployeePortalStatusIcon'
import type { EmployeePortalStatusInfo } from '@/features/employee-portal/api/useEmployeePortalStatusMap'

/** Atmosfera quan no hi ha foto (vista cover) — tons neutres. */
const PLACEHOLDER_TONES = [
  'from-slate-600 via-slate-500 to-teal-700',
  'from-stone-600 via-amber-800/80 to-stone-700',
  'from-zinc-700 via-sky-900/70 to-zinc-800',
  'from-neutral-700 via-emerald-900/60 to-neutral-800',
  'from-stone-700 via-orange-900/50 to-stone-800',
  'from-slate-800 via-cyan-950 to-slate-700',
] as const

function toneForId(id: string | null | undefined): string {
  if (!id) return PLACEHOLDER_TONES[0]
  let hash = 0
  for (let i = 0; i < id.length; i++) hash = (hash * 31 + id.charCodeAt(i)) >>> 0
  return PLACEHOLDER_TONES[hash % PLACEHOLDER_TONES.length]
}

export type EmployeeCardVariant = 'avatar' | 'photo'

interface EmployeeCardProps {
  employee: Employee
  departmentName?: string
  siteName?: string
  positionName?: string
  onEdit: (emp: Employee) => void
  canWrite: boolean
  /** avatar = avatar gran + dades org/contacte; photo = foto a dalt + dades cicle de vida */
  variant: EmployeeCardVariant
  /** Estat portal (una sola icona). Només si l’usuari pot gestionar portal. */
  portalStatus?: EmployeePortalStatusInfo | null
}

function CardEditButton({
  canWrite,
  onEdit,
  employee,
  label,
  className,
}: {
  canWrite: boolean
  onEdit: (emp: Employee) => void
  employee: Employee
  label: string
  className?: string
}) {
  if (!canWrite) return null
  return (
    <div
      className={
        className ??
        'absolute right-2 top-2 opacity-0 transition-opacity group-hover:opacity-100 group-focus-within:opacity-100'
      }
    >
      <Button
        type="button"
        variant="secondary"
        size="icon"
        className="h-8 w-8 shadow-sm"
        onClick={(e) => {
          e.preventDefault()
          e.stopPropagation()
          onEdit(employee)
        }}
        aria-label={label}
      >
        <Edit className="h-4 w-4" />
      </Button>
    </div>
  )
}

export function EmployeeCard({
  employee,
  departmentName,
  siteName,
  positionName,
  onEdit,
  canWrite,
  variant,
  portalStatus,
}: EmployeeCardProps) {
  const { t } = useTranslation('employees')
  const displayName = employee.preferred_name?.trim() || employee.full_name || '—'
  const lifecycle = employee.lifecycle_state ?? 'active'
  const empStatus = (employee.status ?? 'active') as EmployeeStatus
  const editLabel = t('employees.actions.edit', 'Editar')

  if (variant === 'photo') {
    return (
      <PhotoCard
        employee={employee}
        displayName={displayName}
        departmentName={departmentName}
        siteName={siteName}
        positionName={positionName}
        onEdit={onEdit}
        canWrite={canWrite}
        editLabel={editLabel}
        lifecycleLabel={t(`employees.lifecycle.states.${lifecycle}`, lifecycle)}
        portalStatus={portalStatus}
      />
    )
  }

  return (
    <AvatarCard
      employee={employee}
      displayName={displayName}
      empStatus={empStatus}
      departmentName={departmentName}
      siteName={siteName}
      positionName={positionName}
      onEdit={onEdit}
      canWrite={canWrite}
      editLabel={editLabel}
      statusLabel={t(`employees.status.${empStatus}`, empStatus)}
      portalStatus={portalStatus}
    />
  )
}

/** Targeta amb avatar gran: cos = organització / contacte */
function AvatarCard({
  employee,
  displayName,
  empStatus,
  departmentName,
  siteName,
  positionName,
  onEdit,
  canWrite,
  editLabel,
  statusLabel,
  portalStatus,
}: {
  employee: Employee
  displayName: string
  empStatus: EmployeeStatus
  departmentName?: string
  siteName?: string
  positionName?: string
  onEdit: (emp: Employee) => void
  canWrite: boolean
  editLabel: string
  statusLabel: string
  portalStatus?: EmployeePortalStatusInfo | null
}) {
  return (
    <article
      className="group relative flex flex-col overflow-hidden rounded-2xl border border-border bg-card shadow-sm transition-shadow hover:shadow-md focus-within:ring-2 focus-within:ring-ring"
      data-testid="employee-card"
      data-variant="avatar"
    >
      {portalStatus ? (
        <div className="absolute left-2 top-2 z-[1]">
          <EmployeePortalStatusIcon info={portalStatus} />
        </div>
      ) : null}
      <Link
        to={`/employees/${employee.id}`}
        className="flex flex-1 flex-col items-center px-4 pb-4 pt-5 text-center outline-none"
        aria-label={displayName}
      >
        <EmployeeAvatar
          fullName={employee.full_name}
          preferredName={employee.preferred_name}
          photoObjectPath={employee.photo_object_path}
          size="xl"
        />
        <h2 className="mt-3 w-full truncate text-base font-semibold leading-tight text-foreground group-hover:text-primary">
          {displayName}
        </h2>
        {positionName ? (
          <p className="mt-0.5 line-clamp-2 w-full text-sm text-muted-foreground">{positionName}</p>
        ) : null}

        <div className="mt-3 w-full space-y-1.5 text-left text-xs text-muted-foreground">
          {departmentName ? (
            <p className="flex items-start gap-1.5 truncate">
              <Building2 className="mt-0.5 h-3.5 w-3.5 shrink-0 opacity-70" aria-hidden />
              <span className="truncate">{departmentName}</span>
            </p>
          ) : null}
          {siteName ? (
            <p className="flex items-start gap-1.5 truncate">
              <MapPin className="mt-0.5 h-3.5 w-3.5 shrink-0 opacity-70" aria-hidden />
              <span className="truncate">{siteName}</span>
            </p>
          ) : null}
          {employee.email ? (
            <p className="flex items-start gap-1.5 truncate">
              <Mail className="mt-0.5 h-3.5 w-3.5 shrink-0 opacity-70" aria-hidden />
              <span className="truncate">{employee.email}</span>
            </p>
          ) : null}
        </div>

        <p
          className={`mt-auto w-full pt-3 text-xs font-medium ${
            empStatus === 'active'
              ? 'text-emerald-700'
              : empStatus === 'inactive'
                ? 'text-amber-700'
                : 'text-muted-foreground'
          }`}
        >
          {statusLabel}
        </p>
      </Link>

      <CardEditButton
        canWrite={canWrite}
        onEdit={onEdit}
        employee={employee}
        label={editLabel}
      />
    </article>
  )
}

/** Targeta amb foto a dalt (una sola vegada): cos = cicle de vida / codi / context */
function PhotoCard({
  employee,
  displayName,
  departmentName,
  siteName,
  positionName,
  onEdit,
  canWrite,
  editLabel,
  lifecycleLabel,
  portalStatus,
}: {
  employee: Employee
  displayName: string
  departmentName?: string
  siteName?: string
  positionName?: string
  onEdit: (emp: Employee) => void
  canWrite: boolean
  editLabel: string
  lifecycleLabel: string
  portalStatus?: EmployeePortalStatusInfo | null
}) {
  const { src, initials } = useEmployeeAvatarSrc(employee.photo_object_path, displayName)
  const tone = toneForId(employee.id)
  const contextLine = [departmentName, siteName].filter(Boolean).join(' · ')

  return (
    <article
      className="group relative flex flex-col overflow-hidden rounded-2xl border border-border bg-card shadow-sm transition-shadow hover:shadow-md focus-within:ring-2 focus-within:ring-ring"
      data-testid="employee-card"
      data-variant="photo"
    >
      {portalStatus ? (
        <div className="absolute left-2 top-2 z-[2]">
          <EmployeePortalStatusIcon
            info={portalStatus}
            className="bg-background/90 shadow-sm backdrop-blur-sm"
          />
        </div>
      ) : null}
      <Link
        to={`/employees/${employee.id}`}
        className="flex flex-1 flex-col outline-none"
        aria-label={displayName}
      >
        <div className={`relative h-36 bg-gradient-to-br ${tone}`}>
          {src ? (
            <img src={src} alt="" className="absolute inset-0 h-full w-full object-cover" />
          ) : (
            <div className="absolute inset-0 flex items-center justify-center text-3xl font-semibold uppercase tracking-wide text-white/90">
              {initials}
            </div>
          )}
          <div className="absolute inset-0 bg-gradient-to-t from-black/55 via-black/15 to-transparent" />
          <div className="absolute inset-x-0 bottom-0 px-4 pb-3">
            <h2 className="truncate text-base font-semibold text-white drop-shadow-sm group-hover:underline">
              {displayName}
            </h2>
          </div>
        </div>

        <div className="flex flex-1 flex-col gap-1 px-4 py-3">
          <p className="text-sm font-medium text-foreground" data-testid="employee-card-lifecycle">
            {lifecycleLabel}
          </p>
          {positionName ? (
            <p className="line-clamp-2 text-xs text-muted-foreground">{positionName}</p>
          ) : null}
          {contextLine ? (
            <p className="truncate text-xs text-muted-foreground/80">{contextLine}</p>
          ) : null}
          {employee.employee_code ? (
            <p className="mt-auto pt-2 font-mono text-[11px] tracking-wide text-muted-foreground/70">
              {employee.employee_code}
            </p>
          ) : (
            <div className="mt-auto" />
          )}
        </div>
      </Link>

      <CardEditButton
        canWrite={canWrite}
        onEdit={onEdit}
        employee={employee}
        label={editLabel}
        className="absolute right-2 top-2 opacity-0 transition-opacity group-hover:opacity-100 group-focus-within:opacity-100 [&_button]:bg-background/90"
      />
    </article>
  )
}
