import { useEffect } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { useTranslation } from 'react-i18next'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { departmentSchema } from '../schemas/departmentSchema'
import type { DepartmentFormValues } from '../schemas/departmentSchema'
import { useCreateDepartment } from '../api/useCreateDepartment'
import { useUpdateDepartment } from '../api/useUpdateDepartment'
import { getDescendantIds, normalizeDeptError } from '../api/departmentsService'
import type { Department } from '../api/departmentsService'
import { useTenant } from '@/contexts/TenantContext'
import { AttendanceGeoEnabledField } from '@/features/attendance/components/AttendanceGeoEnabledField'
import {
  fromAttendanceGeoEnabledFormValue,
  toAttendanceGeoEnabledFormValue,
} from '@/features/attendance/utils/attendanceGeoFormUtils'
import { useEmployees } from '@/features/employees/api/useEmployees'

interface DepartmentFormProps {
  open: boolean
  onClose: () => void
  editDepartment?: Department | null
  /** Pre-selects the parent when adding a child node. Ignored when editing. */
  defaultParentId?: string | null
  allDepartments: Department[]
}

export function DepartmentForm({
  open,
  onClose,
  editDepartment,
  defaultParentId,
  allDepartments,
}: DepartmentFormProps) {
  const { t } = useTranslation('departments')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const isEditing = !!editDepartment

  const createMutation = useCreateDepartment()
  const updateMutation = useUpdateDepartment()
  const { data: employees = [] } = useEmployees()

  const {
    register,
    handleSubmit,
    reset,
    setValue,
    watch,
    formState: { errors, isSubmitting },
  } = useForm<DepartmentFormValues>({
    resolver: zodResolver(departmentSchema),
    defaultValues: {
      name: '',
      code: '',
      parent_id: null,
      manager_employee_id: null,
      attendance_geo_enabled: 'inherit',
    },
  })

  // Sync form values whenever the dialog opens or the target changes
  useEffect(() => {
    if (!open) return
    if (editDepartment) {
      reset({
        name: editDepartment.name ?? '',
        code: editDepartment.code ?? '',
        parent_id: editDepartment.parent_id ?? null,
        manager_employee_id: editDepartment.manager_employee_id ?? null,
        attendance_geo_enabled: toAttendanceGeoEnabledFormValue(
          (editDepartment as { attendance_geo_enabled?: boolean | null }).attendance_geo_enabled,
        ),
      })
    } else {
      reset({
        name: '',
        code: '',
        parent_id: defaultParentId ?? null,
        manager_employee_id: null,
        attendance_geo_enabled: 'inherit',
      })
    }
  }, [open, editDepartment, defaultParentId, reset])

  const selectedParentId = watch('parent_id')

  // Exclude self + descendants to prevent circular hierarchies
  const excludedIds: (string | null | undefined)[] = editDepartment
    ? [editDepartment.id, ...getDescendantIds(allDepartments, editDepartment.id!)]
    : []

  const parentOptions = allDepartments.filter(
    (d) => d.is_active !== false && !excludedIds.includes(d.id),
  )

  async function onSubmit(values: DepartmentFormValues) {
    const params = {
      name: values.name,
      code: values.code || null,
      parent_id: values.parent_id ?? null,
      manager_employee_id: values.manager_employee_id ?? null,
      attendance_geo_enabled: fromAttendanceGeoEnabledFormValue(values.attendance_geo_enabled),
    }
    try {
      if (isEditing) {
        await updateMutation.mutateAsync({ id: editDepartment!.id!, params })
        toast({ description: t('departments.toast.updated', 'Departament actualitzat') })
      } else {
        if (!activeTenant?.id) {
          toast({
            variant: 'destructive',
            description: t('departments.errors.no_tenant', 'Selecciona una organització per crear un departament'),
          })
          return
        }
        await createMutation.mutateAsync({
          ...params,
          tenant_id: activeTenant.id,
        })
        toast({ description: t('departments.toast.created', 'Departament creat') })
      }
      onClose()
    } catch (err) {
      const kind = normalizeDeptError(err)
      toast({
        variant: 'destructive',
        description:
          kind === 'unauthorized'
            ? t('departments.errors.unauthorized', 'No tens permís per fer aquesta acció')
            : t('departments.errors.save_failed', 'Error en desar el departament'),
      })
    }
  }

  return (
    <Dialog open={open} onOpenChange={(v) => !v && onClose()}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>
            {isEditing
              ? t('departments.form.title_edit', 'Editar departament')
              : t('departments.form.title_create', 'Nou departament')}
          </DialogTitle>
        </DialogHeader>

        <form onSubmit={handleSubmit(onSubmit)} className="space-y-4 pt-1">
          {/* Name */}
          <div className="space-y-1.5">
            <label className="text-sm font-medium text-foreground">
              {t('departments.form.name_label', 'Nom')} *
            </label>
            <Input
              {...register('name')}
              placeholder={t('departments.form.name_placeholder', 'p.ex. Operacions')}
              autoFocus
            />
            {errors.name && (
              <p className="text-xs text-destructive">
                {t('departments.form.errors.name_required', 'El nom és obligatori')}
              </p>
            )}
          </div>

          {/* Code */}
          <div className="space-y-1.5">
            <label className="text-sm font-medium text-foreground">
              {t('departments.form.code_label', 'Codi')}
            </label>
            <Input
              {...register('code')}
              placeholder={t('departments.form.code_placeholder', 'p.ex. OPS')}
              maxLength={20}
            />
          </div>

          {/* Parent selector */}
          <div className="space-y-1.5">
            <label className="text-sm font-medium text-foreground">
              {t('departments.form.parent_label', 'Departament pare')}
            </label>
            <select
              id="dept-parent"
              aria-label={t('departments.form.parent_label', 'Departament pare')}
              value={selectedParentId ?? ''}
              onChange={(e) =>
                setValue('parent_id', e.target.value || null, { shouldValidate: true })
              }
              className="w-full h-9 rounded-md border border-input bg-background px-3 text-sm focus:outline-none focus:ring-1 focus:ring-ring"
            >
              <option value="">
                {t('departments.form.no_parent', '(Arrel, sense pare)')}
              </option>
              {parentOptions.map((d) => (
                <option key={d.id} value={d.id!}>
                  {d.code ? `[${d.code}] ${d.name}` : (d.name ?? '')}
                </option>
              ))}
            </select>
          </div>

          <div className="space-y-1.5">
            <label className="text-sm font-medium text-foreground">
              {t('departments.form.manager_label', 'Manager (empleat)')}
            </label>
            <select
              value={watch('manager_employee_id') ?? ''}
              onChange={(e) =>
                setValue('manager_employee_id', e.target.value || null, { shouldValidate: true })
              }
              className="w-full h-9 rounded-md border border-input bg-background px-3 text-sm focus:outline-none focus:ring-1 focus:ring-ring"
            >
              <option value="">
                {t('departments.form.no_manager', 'Sense manager')}
              </option>
              {employees
                .filter((e) => e.id && e.status !== 'terminated')
                .map((e) => (
                  <option key={e.id!} value={e.id!}>
                    {e.preferred_name || e.full_name}
                  </option>
                ))}
            </select>
          </div>

          <AttendanceGeoEnabledField
            value={watch('attendance_geo_enabled')}
            onChange={(v) => setValue('attendance_geo_enabled', v, { shouldValidate: true })}
            inheritLabel={t(
              'departments.form.attendance_geo_inherit',
              'Heretar (grup de calendari / tenant)',
            )}
            hint={t(
              'departments.form.attendance_geo_hint',
              'Override per a tots els empleats d’aquest departament que no tinguin valor propi.',
            )}
          />

          {/* Footer */}
          <div className="flex justify-end gap-2 pt-2">
            <Button type="button" variant="outline" onClick={onClose} disabled={isSubmitting}>
              {t('departments.form.cancel', 'Cancel·lar')}
            </Button>
            <Button type="submit" disabled={isSubmitting}>
              {isSubmitting
                ? t('departments.form.saving', 'Desant…')
                : t('departments.form.save', 'Desar')}
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  )
}
