import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Plus, Trash2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import {
  useDeactivateEmployeeQualification,
  useDeactivateEmployeeRoleAssignment,
  useEmployeeQualifications,
  useEmployeeRoleAssignments,
  useUpsertEmployeeQualification,
  useUpsertEmployeeRoleAssignment,
  useWorkRoles,
} from '@/features/attendance/api/useWorkRoles'

export function EmployeeRolesQualsSection({
  employeeId,
  canWrite,
}: {
  employeeId: string
  canWrite: boolean
}) {
  const { t } = useTranslation('employees')
  const { toast } = useToast()
  const { data: roles = [] } = useWorkRoles()
  const { data: assignments = [] } = useEmployeeRoleAssignments(employeeId)
  const { data: quals = [] } = useEmployeeQualifications(employeeId)
  const upsertRole = useUpsertEmployeeRoleAssignment()
  const removeRole = useDeactivateEmployeeRoleAssignment()
  const upsertQual = useUpsertEmployeeQualification()
  const removeQual = useDeactivateEmployeeQualification()

  const [roleId, setRoleId] = useState('')
  const [qualLabel, setQualLabel] = useState('')
  const [qualExpires, setQualExpires] = useState('')

  const assignedIds = new Set(assignments.map((a) => a.role_id))
  const availableRoles = roles.filter((r) => !assignedIds.has(r.id))

  async function addRole() {
    if (!roleId) return
    try {
      await upsertRole.mutateAsync({
        employee_id: employeeId,
        role_id: roleId,
        is_primary: assignments.length === 0,
      })
      setRoleId('')
      toast({ title: t('employees.roles_added', 'Rol assignat') })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('employees.roles_error', 'No s\'ha pogut assignar el rol'),
        description: err instanceof Error ? err.message : String(err),
      })
    }
  }

  async function addQual() {
    if (!qualLabel.trim()) return
    try {
      await upsertQual.mutateAsync({
        employee_id: employeeId,
        label: qualLabel.trim(),
        expires_at: qualExpires || null,
      })
      setQualLabel('')
      setQualExpires('')
      toast({ title: t('employees.quals_added', 'Qualificació afegida') })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('employees.quals_error', 'No s\'ha pogut afegir'),
        description: err instanceof Error ? err.message : String(err),
      })
    }
  }

  return (
    <div className="space-y-6 rounded-lg border p-4">
      <div>
        <h3 className="text-sm font-semibold">
          {t('employees.roles_title', 'Rols operatius')}
        </h3>
        <p className="mt-1 text-xs text-muted-foreground">
          {t(
            'employees.roles_hint',
            'Capacitats per cobertura. Independent del camp «Lloc de treball».',
          )}
        </p>
        <ul className="mt-2 space-y-1">
          {assignments.map((a) => (
            <li key={a.id} className="flex items-center justify-between text-sm">
              <span>
                {a.role_name}
                {a.is_primary ? (
                  <span className="ml-2 text-xs text-muted-foreground">
                    ({t('employees.roles_primary', 'principal')})
                  </span>
                ) : null}
                <span className="ml-2 text-xs text-muted-foreground">L{a.level}</span>
              </span>
              {canWrite ? (
                <Button
                  type="button"
                  size="icon"
                  variant="ghost"
                  className="h-7 w-7"
                  onClick={() => void removeRole.mutateAsync({ id: a.id, employee_id: employeeId })}
                >
                  <Trash2 className="h-3.5 w-3.5 text-destructive" />
                </Button>
              ) : null}
            </li>
          ))}
          {assignments.length === 0 ? (
            <li className="text-xs text-muted-foreground">
              {t('employees.roles_empty', 'Sense rols assignats')}
            </li>
          ) : null}
        </ul>
        {canWrite && availableRoles.length > 0 ? (
          <div className="mt-2 flex gap-2">
            <select
              value={roleId}
              onChange={(e) => setRoleId(e.target.value)}
              className="flex-1 rounded-md border border-input bg-background px-2 py-1.5 text-sm"
            >
              <option value="">{t('employees.roles_select', 'Selecciona un rol')}</option>
              {availableRoles.map((r) => (
                <option key={r.id} value={r.id}>{r.name}</option>
              ))}
            </select>
            <Button type="button" size="sm" onClick={() => void addRole()} disabled={!roleId}>
              <Plus className="h-3.5 w-3.5" />
            </Button>
          </div>
        ) : null}
      </div>

      <div>
        <h3 className="text-sm font-semibold">
          {t('employees.quals_title', 'Qualificacions')}
        </h3>
        <ul className="mt-2 space-y-1">
          {quals.map((q) => (
            <li key={q.id} className="flex items-center justify-between text-sm">
              <span>
                {q.label}
                {q.expires_at ? (
                  <span className="ml-2 text-xs text-muted-foreground">
                    {t('employees.quals_expires', 'caduca')} {q.expires_at}
                  </span>
                ) : null}
              </span>
              {canWrite ? (
                <Button
                  type="button"
                  size="icon"
                  variant="ghost"
                  className="h-7 w-7"
                  onClick={() => void removeQual.mutateAsync({ id: q.id, employee_id: employeeId })}
                >
                  <Trash2 className="h-3.5 w-3.5 text-destructive" />
                </Button>
              ) : null}
            </li>
          ))}
          {quals.length === 0 ? (
            <li className="text-xs text-muted-foreground">
              {t('employees.quals_empty', 'Sense qualificacions')}
            </li>
          ) : null}
        </ul>
        {canWrite ? (
          <div className="mt-2 grid grid-cols-[1fr_auto_auto] gap-2">
            <input
              value={qualLabel}
              onChange={(e) => setQualLabel(e.target.value)}
              placeholder={t('employees.quals_placeholder', 'Ex. Carretilla')}
              className="rounded-md border border-input bg-background px-2 py-1.5 text-sm"
            />
            <input
              type="date"
              value={qualExpires}
              onChange={(e) => setQualExpires(e.target.value)}
              className="rounded-md border border-input bg-background px-2 py-1.5 text-sm"
              title={t('employees.quals_expires', 'caduca')}
            />
            <Button type="button" size="sm" onClick={() => void addQual()} disabled={!qualLabel.trim()}>
              <Plus className="h-3.5 w-3.5" />
            </Button>
          </div>
        ) : null}
      </div>
    </div>
  )
}
