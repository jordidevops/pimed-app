import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Loader2, Trash2, UserPlus, Users } from 'lucide-react'
import { useSiteEmployeesForSite } from '@/features/attendance/api/useShifts'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import type { Location } from '../api/locationsService'
import {
  useAddLocationAttendanceAssignment,
  useBulkAddLocationAttendanceAssignments,
  useLocationAttendanceAssignments,
  useRemoveLocationAttendanceAssignment,
  useUpdateLocationAttendanceAssignment,
} from '../api/useLocationAttendanceAssignments'

export interface LocationAttendanceEmployeesPanelProps {
  location: Location
  canManage: boolean
}

export function LocationAttendanceEmployeesPanel({
  location,
  canManage,
}: LocationAttendanceEmployeesPanelProps) {
  const { t } = useTranslation('locations')
  const locationId = location.id ?? null
  const siteId = location.site_id ?? null

  const [includeInactive, setIncludeInactive] = useState(false)
  const { data, isLoading, error } = useLocationAttendanceAssignments(locationId, includeInactive)
  const { data: siteEmployees = [] } = useSiteEmployeesForSite(siteId)
  const addMutation = useAddLocationAttendanceAssignment(locationId)
  const updateMutation = useUpdateLocationAttendanceAssignment(locationId)
  const bulkMutation = useBulkAddLocationAttendanceAssignments(locationId)
  const removeMutation = useRemoveLocationAttendanceAssignment(locationId)

  const [selectedEmployeeIds, setSelectedEmployeeIds] = useState<string[]>([])
  const [startsOn, setStartsOn] = useState('')
  const [endsOn, setEndsOn] = useState('')
  const [editingId, setEditingId] = useState<string | null>(null)
  const [editStartsOn, setEditStartsOn] = useState('')
  const [editEndsOn, setEditEndsOn] = useState('')

  const assignedEmployeeIds = useMemo(
    () => new Set((data?.assignments ?? []).map((row) => row.employee_id)),
    [data?.assignments],
  )

  const availableEmployees = useMemo(
    () =>
      siteEmployees.filter(
        (employee) => employee.id && employee.status === 'active' && !assignedEmployeeIds.has(employee.id),
      ),
    [assignedEmployeeIds, siteEmployees],
  )

  function toggleEmployee(employeeId: string) {
    setSelectedEmployeeIds((prev) =>
      prev.includes(employeeId) ? prev.filter((id) => id !== employeeId) : [...prev, employeeId],
    )
  }

  async function handleAdd() {
    if (!locationId || selectedEmployeeIds.length === 0) return
    const payload = {
      locationId,
      startsOn: startsOn || null,
      endsOn: endsOn || null,
    }
    if (selectedEmployeeIds.length === 1) {
      await addMutation.mutateAsync({
        ...payload,
        employeeId: selectedEmployeeIds[0]!,
      })
    } else {
      await bulkMutation.mutateAsync({
        ...payload,
        employeeIds: selectedEmployeeIds,
      })
    }
    setSelectedEmployeeIds([])
    setStartsOn('')
    setEndsOn('')
  }

  async function handleRemove(assignmentId: string) {
    await removeMutation.mutateAsync(assignmentId)
  }

  function startEdit(row: { id: string; starts_on: string | null; ends_on: string | null }) {
    setEditingId(row.id)
    setEditStartsOn(row.starts_on ?? '')
    setEditEndsOn(row.ends_on ?? '')
  }

  async function saveEdit() {
    if (!editingId) return
    await updateMutation.mutateAsync({
      assignmentId: editingId,
      startsOn: editStartsOn || null,
      endsOn: editEndsOn || null,
    })
    setEditingId(null)
  }

  const saving = addMutation.isPending || bulkMutation.isPending

  return (
    <div className="rounded-xl border p-3 space-y-2.5">
      <div className="flex items-start justify-between gap-2">
        <p className="text-xs font-semibold text-foreground uppercase tracking-wide flex items-center gap-1.5">
          <Users className="h-3.5 w-3.5" aria-hidden />
          {t('locations.attendance_assignments.title', 'Empleats de la zona (fitxatge)')}
        </p>
        {data?.scope_has_assignments ? (
          <Badge variant="secondary" className="text-[10px] shrink-0">
            {t('locations.attendance_assignments.badge_zone_mode', 'Mode zona')}
          </Badge>
        ) : null}
      </div>

      <p className="text-[11px] text-muted-foreground leading-relaxed">
        {t(
          'locations.attendance_assignments.explanation',
          'Les assignacions d\'una zona pare s\'apliquen també a les subzones. Si no hi ha cap assignació a la zona ni als seus pares, l\'estació mostra tots els empleats actius del centre.',
        )}
      </p>

      <label className="flex items-center gap-2 text-[11px] text-muted-foreground">
        <input
          type="checkbox"
          checked={includeInactive}
          onChange={(e) => setIncludeInactive(e.target.checked)}
          className="rounded border-input"
        />
        {t('locations.attendance_assignments.show_inactive', 'Mostrar assignacions fora de vigència')}
      </label>

      {isLoading ? (
        <div className="flex justify-center py-6 text-muted-foreground">
          <Loader2 className="h-5 w-5 animate-spin" aria-hidden />
        </div>
      ) : error ? (
        <p className="rounded-lg border border-destructive/30 bg-destructive/5 p-3 text-xs text-destructive">
          {(error as Error).message}
        </p>
      ) : (
        <>
          {data && data.scope_has_assignments ? (
            <p className="text-[11px] text-muted-foreground">
              {t(
                'locations.attendance_assignments.scope_hint',
                '{{assigned}} assignats directament · {{site}} empleats al centre',
                {
                  assigned: data.assigned_count,
                  site: data.site_employee_count,
                },
              )}
            </p>
          ) : (
            <p className="text-[11px] text-amber-800 bg-amber-50 border border-amber-200 rounded-lg px-2.5 py-2">
              {t(
                'locations.attendance_assignments.fallback_hint',
                'Sense assignacions en aquest abast: l\'estació mostrarà tots els empleats actius del centre.',
              )}
            </p>
          )}

          {(data?.assignments ?? []).length === 0 ? (
            <p className="text-xs text-muted-foreground py-2">
              {t('locations.attendance_assignments.empty', 'Cap empleat assignat directament a aquesta zona.')}
            </p>
          ) : (
            <ul className="space-y-1.5">
              {(data?.assignments ?? []).map((row) => (
                <li
                  key={row.id}
                  className="rounded-lg border px-2.5 py-2 text-sm space-y-1.5"
                >
                  <div className="flex items-center justify-between gap-2">
                    <div className="min-w-0 flex items-center gap-2">
                      <span className="truncate font-medium">{row.full_name}</span>
                      {row.is_active_today === false ? (
                        <Badge variant="outline" className="text-[10px] shrink-0">
                          {t('locations.attendance_assignments.inactive', 'Fora de vigència')}
                        </Badge>
                      ) : null}
                    </div>
                    {canManage ? (
                      <div className="flex items-center gap-1 shrink-0">
                        <Button
                          type="button"
                          variant="ghost"
                          size="sm"
                          className="h-7 px-2 text-xs"
                          onClick={() => startEdit(row)}
                        >
                          {t('locations.attendance_assignments.edit_dates', 'Dates')}
                        </Button>
                        <Button
                          type="button"
                          variant="ghost"
                          size="sm"
                          className="h-7 w-7 p-0 text-muted-foreground hover:text-destructive"
                          disabled={removeMutation.isPending}
                          onClick={() => void handleRemove(row.id)}
                          title={t('locations.attendance_assignments.remove', 'Eliminar assignació')}
                          aria-label={t('locations.attendance_assignments.remove', 'Eliminar assignació')}
                        >
                          <Trash2 className="h-3.5 w-3.5" aria-hidden />
                        </Button>
                      </div>
                    ) : null}
                  </div>
                  <p className="text-[11px] text-muted-foreground tabular-nums">
                    {row.starts_on || row.ends_on
                      ? `${row.starts_on ?? '…'} → ${row.ends_on ?? '…'}`
                      : t('locations.attendance_assignments.no_dates', 'Sense límit de dates')}
                  </p>
                  {editingId === row.id ? (
                    <div className="flex flex-wrap items-end gap-2 pt-1 border-t">
                      <div className="space-y-1">
                        <Label className="text-[10px]">{t('locations.attendance_assignments.starts_on', 'Des de')}</Label>
                        <Input
                          type="date"
                          className="h-8 w-[9.5rem] text-xs"
                          value={editStartsOn}
                          onChange={(e) => setEditStartsOn(e.target.value)}
                        />
                      </div>
                      <div className="space-y-1">
                        <Label className="text-[10px]">{t('locations.attendance_assignments.ends_on', 'Fins')}</Label>
                        <Input
                          type="date"
                          className="h-8 w-[9.5rem] text-xs"
                          value={editEndsOn}
                          onChange={(e) => setEditEndsOn(e.target.value)}
                        />
                      </div>
                      <Button
                        type="button"
                        size="sm"
                        className="h-8"
                        disabled={updateMutation.isPending}
                        onClick={() => void saveEdit()}
                      >
                        {updateMutation.isPending ? (
                          <Loader2 className="h-3.5 w-3.5 animate-spin" aria-hidden />
                        ) : (
                          t('common.save', 'Desar')
                        )}
                      </Button>
                      <Button
                        type="button"
                        size="sm"
                        variant="ghost"
                        className="h-8"
                        onClick={() => setEditingId(null)}
                      >
                        {t('common.cancel', 'Cancel·lar')}
                      </Button>
                    </div>
                  ) : null}
                </li>
              ))}
            </ul>
          )}

          {canManage ? (
            <div className="space-y-2 pt-1 border-t">
              <Label className="text-xs">
                {t('locations.attendance_assignments.add_label', 'Afegir empleat')}
              </Label>
              <div className="max-h-36 overflow-y-auto rounded-md border p-2 space-y-1">
                {availableEmployees.length === 0 ? (
                  <p className="text-xs text-muted-foreground px-1 py-1">
                    {t('locations.attendance_assignments.no_available', 'Cap empleat disponible')}
                  </p>
                ) : (
                  availableEmployees.map((employee) => {
                    const id = employee.id ?? ''
                    return (
                      <label
                        key={id}
                        className="flex items-center gap-2 rounded px-1 py-0.5 text-sm hover:bg-muted/50"
                      >
                        <input
                          type="checkbox"
                          checked={selectedEmployeeIds.includes(id)}
                          onChange={() => toggleEmployee(id)}
                          disabled={saving}
                        />
                        <span className="truncate">{employee.full_name ?? id}</span>
                      </label>
                    )
                  })
                )}
              </div>
              <div className="flex flex-wrap gap-2">
                <div className="space-y-1">
                  <Label className="text-[10px]">{t('locations.attendance_assignments.starts_on', 'Des de')}</Label>
                  <Input
                    type="date"
                    className="h-9 w-[9.5rem] text-sm"
                    value={startsOn}
                    onChange={(e) => setStartsOn(e.target.value)}
                    disabled={saving}
                  />
                </div>
                <div className="space-y-1">
                  <Label className="text-[10px]">{t('locations.attendance_assignments.ends_on', 'Fins')}</Label>
                  <Input
                    type="date"
                    className="h-9 w-[9.5rem] text-sm"
                    value={endsOn}
                    onChange={(e) => setEndsOn(e.target.value)}
                    disabled={saving}
                  />
                </div>
                <div className="flex items-end">
                  <Button
                    type="button"
                    size="sm"
                    className="h-9"
                    disabled={selectedEmployeeIds.length === 0 || saving}
                    onClick={() => void handleAdd()}
                  >
                    {saving ? (
                      <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
                    ) : (
                      <>
                        <UserPlus className="h-4 w-4 mr-1" aria-hidden />
                        {selectedEmployeeIds.length > 1
                          ? t('locations.attendance_assignments.bulk_add', 'Afegir {{count}}', {
                              count: selectedEmployeeIds.length,
                            })
                          : t('locations.attendance_assignments.add_one', 'Afegir')}
                      </>
                    )}
                  </Button>
                </div>
              </div>
            </div>
          ) : (
            <p className="text-[11px] text-muted-foreground">
              {t(
                'locations.attendance_assignments.readonly_hint',
                'Només usuaris amb permís de gestió d\'estacions poden modificar assignacions.',
              )}
            </p>
          )}
        </>
      )}
    </div>
  )
}
