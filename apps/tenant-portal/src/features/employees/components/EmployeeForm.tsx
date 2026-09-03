import { useCallback, useEffect, useMemo } from 'react'
import { useForm, type FieldErrors } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { useTranslation } from 'react-i18next'
import { Loader2 } from 'lucide-react'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useDepartments } from '@/features/departments/api/useDepartments'
import { employeeSchema, EMPLOYEE_STATUSES } from '../schemas/employeeSchema'
import type { EmployeeFormInput, EmployeeFormValues } from '../schemas/employeeSchema'
import { useCreateEmployee } from '../api/useCreateEmployee'
import { useUpdateEmployee } from '../api/useUpdateEmployee'
import { normalizeEmployeeError, updateEmployeeHrProfile } from '../api/employeesService'
import type { Employee } from '../api/employeesService'
import { useJobPositions } from '../api/useJobPositions'
import { useEmployeePermissions } from '../hooks/useEmployeePermissions'
import {
  buildEmployeeSiteOptions,
  defaultEmployeeSiteId,
  sanitizeUuidField,
} from '../schemas/employeeFormFields'
import { employeeFieldErrorMessage, employeeValidationToastDescription } from '../utils/employeeFormUi'

interface EmployeeFormProps {
  open: boolean
  onClose: () => void
  editEmployee?: Employee | null
}

export function EmployeeForm({ open, onClose, editEmployee }: EmployeeFormProps) {
  const { t } = useTranslation('employees')
  const { toast } = useToast()
  const { activeTenant, sites, selectedSiteId } = useTenant()
  const { data: departments = [] } = useDepartments()
  const { data: jobPositions = [] } = useJobPositions(true)
  const isEditing = !!editEmployee

  const createMutation = useCreateEmployee()
  const updateMutation = useUpdateEmployee()
  const perms = useEmployeePermissions(editEmployee)

  const {
    register,
    handleSubmit,
    reset,
    setValue,
    watch,
    trigger,
    formState: { errors, isSubmitting, isValid },
  } = useForm<EmployeeFormInput, unknown, EmployeeFormValues>({
    resolver: zodResolver(employeeSchema),
    mode: 'onChange',
    reValidateMode: 'onChange',
    defaultValues: {
      full_name: '',
      preferred_name: '',
      legal_name: '',
      employee_code: '',
      email: '',
      phone: '',
      document_id: '',
      job_position_id: '',
      status: 'active',
      starts_on: '',
      ends_on: '',
      weekly_hours: null,
      department_id: '',
      site_id: '',
    },
  })

  const siteOptions = useMemo(
    () =>
      buildEmployeeSiteOptions(
        sites,
        editEmployee?.site_id,
        t('employees.form.site_inactive', 'Local assignat (inactiu)'),
      ),
    [sites, editEmployee?.site_id, t],
  )

  // Sync form whenever dialog opens or target changes
  useEffect(() => {
    if (!open) return
    if (editEmployee) {
      reset({
        full_name: editEmployee.full_name ?? '',
        preferred_name: editEmployee.preferred_name ?? '',
        legal_name: editEmployee.legal_name ?? '',
        employee_code: editEmployee.employee_code ?? '',
        email: editEmployee.email ?? '',
        phone: editEmployee.phone ?? '',
        document_id: '',
        job_position_id: sanitizeUuidField(editEmployee.job_position_id),
        status: (editEmployee.status as EmployeeFormValues['status']) ?? 'active',
        starts_on: editEmployee.starts_on ?? '',
        ends_on: editEmployee.ends_on ?? '',
        weekly_hours: editEmployee.weekly_hours ?? null,
        department_id: sanitizeUuidField(editEmployee.department_id),
        site_id: defaultEmployeeSiteId(editEmployee.site_id, sites, selectedSiteId),
      })
    } else {
      reset({
        full_name: '',
        preferred_name: '',
        legal_name: '',
        employee_code: '',
        email: '',
        phone: '',
        document_id: '',
        job_position_id: '',
        status: 'active',
        starts_on: '',
        ends_on: '',
        weekly_hours: null,
        department_id: '',
        site_id: defaultEmployeeSiteId(null, sites, selectedSiteId),
      })
    }
    void trigger()
  }, [open, editEmployee, selectedSiteId, reset, sites, departments, trigger])

  const watchedStatus = watch('status')
  const watchedEndsOn = watch('ends_on')

  // Auto-fill ends_on when switching to terminated
  useEffect(() => {
    if (watchedStatus === 'terminated' && !watchedEndsOn) {
      setValue('ends_on', new Date().toISOString().slice(0, 10))
    }
  }, [watchedStatus, watchedEndsOn, setValue])

  const onInvalid = useCallback(
    (fieldErrors: FieldErrors<EmployeeFormInput>) => {
      toast({
        variant: 'destructive',
        title: t('employees.errors.validation_title', 'No es pot desar'),
        description: employeeValidationToastDescription(t, fieldErrors),
      })
    },
    [t, toast],
  )

  async function onSubmit(values: EmployeeFormValues) {
    try {
      if (isEditing) {
        await updateMutation.mutateAsync({
          id: editEmployee!.id!,
          params: {
            full_name: values.full_name,
            preferred_name: values.preferred_name?.trim() || null,
            legal_name: values.legal_name?.trim() || null,
            employee_code: values.employee_code?.trim() || null,
            email: values.email || null,
            phone: values.phone || null,
            job_position_id: values.job_position_id ?? null,
            status: values.status,
            starts_on: values.starts_on || null,
            ends_on: values.ends_on || null,
            weekly_hours: values.weekly_hours ?? null,
            department_id: values.department_id ?? null,
            site_id: values.site_id ?? null,
          },
        })
        if (perms.canManagePrivate && values.document_id) {
          await updateEmployeeHrProfile(editEmployee!.id!, {
            document_id: values.document_id || null,
            metadata: null,
          })
        }
        toast({ description: t('employees.toast.updated', 'Empleat actualitzat') })
      } else {
        if (!activeTenant?.id) {
          toast({
            variant: 'destructive',
            description: t('employees.errors.no_tenant', 'Selecciona una organització per crear un empleat'),
          })
          return
        }
        const created = await createMutation.mutateAsync({
          tenant_id: activeTenant.id,
          full_name: values.full_name,
          preferred_name: values.preferred_name?.trim() || null,
          legal_name: values.legal_name?.trim() || null,
          employee_code: values.employee_code?.trim() || null,
          email: values.email || null,
          phone: values.phone || null,
          job_position_id: values.job_position_id ?? null,
          status: values.status,
          starts_on: values.starts_on || null,
          ends_on: values.ends_on || null,
          weekly_hours: values.weekly_hours ?? null,
          department_id: values.department_id ?? null,
          site_id: values.site_id ?? null,
        })
        if (perms.canManagePrivate && values.document_id && created.id) {
          await updateEmployeeHrProfile(created.id, {
            document_id: values.document_id || null,
            metadata: null,
          })
        }
        toast({ description: t('employees.toast.created', 'Empleat creat') })
      }
      onClose()
    } catch (err) {
      const kind = normalizeEmployeeError(err)
      const rawMessage = err instanceof Error ? err.message : ''
      toast({
        variant: 'destructive',
        description:
          kind === 'unauthorized'
            ? t('employees.errors.unauthorized', 'No tens permís per fer aquesta acció')
            : rawMessage || t('employees.errors.generic', "Error en desar l'empleat"),
      })
    }
  }

  const statusLabels: Record<string, string> = {
    active: t('employees.status.active', 'Actiu'),
    inactive: t('employees.status.inactive', 'Inactiu'),
    terminated: t('employees.status.terminated', 'Baixa definitiva'),
  }

  return (
    <Dialog open={open} onOpenChange={(v) => { if (!v) onClose() }}>
      <DialogContent className="max-w-lg max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {isEditing
              ? t('employees.form.title_edit', 'Editar empleat')
              : t('employees.form.title_create', 'Nou empleat')}
          </DialogTitle>
        </DialogHeader>

        <form onSubmit={handleSubmit(onSubmit, onInvalid)} className="space-y-4 pt-1">
          {/* Nom complet */}
          <div className="space-y-1">
            <label className="text-sm font-medium text-foreground">
              {t('employees.form.full_name_label', 'Nom complet')}
              <span className="text-destructive ml-0.5">*</span>
            </label>
            <Input
              {...register('full_name')}
              placeholder={t('employees.form.full_name_placeholder', 'p.ex. Anna Garcia López')}
            />
            {errors.full_name && (
              <p className="text-xs text-destructive">{t('employees.validation.full_name_required', 'El nom és obligatori')}</p>
            )}
          </div>

          <div className="grid gap-3 sm:grid-cols-3">
            <div className="space-y-1">
              <label className="text-sm font-medium text-foreground">
                {t('employees.form.preferred_name_label', 'Nom preferit')}
              </label>
              <Input
                {...register('preferred_name')}
                placeholder={t('employees.form.preferred_name_placeholder', 'p.ex. Anna')}
              />
            </div>
            <div className="space-y-1">
              <label className="text-sm font-medium text-foreground">
                {t('employees.form.legal_name_label', 'Nom legal')}
              </label>
              <Input
                {...register('legal_name')}
                placeholder={t('employees.form.legal_name_placeholder', 'Nom al DNI / contracte')}
              />
            </div>
            <div className="space-y-1">
              <label className="text-sm font-medium text-foreground">
                {t('employees.form.employee_code_label', 'Codi empleat')}
              </label>
              <Input
                {...register('employee_code')}
                placeholder={t('employees.form.employee_code_placeholder', 'p.ex. EMP-001')}
              />
            </div>
          </div>

          {/* Correu electrònic */}
          <div className="space-y-1">
            <label className="text-sm font-medium text-foreground">
              {t('employees.form.email_label', 'Correu electrònic')}
            </label>
            <Input
              {...register('email')}
              type="email"
              placeholder={t('employees.form.email_placeholder', 'p.ex. anna@empresa.com')}
            />
            {errors.email && (
              <p className="text-xs text-destructive">
                {employeeFieldErrorMessage(t, 'email', errors)}
              </p>
            )}
          </div>

          {/* Telèfon + Document */}
          <div className={`grid gap-3 ${perms.canViewPrivate ? 'grid-cols-2' : 'grid-cols-1'}`}>
            <div className="space-y-1">
              <label className="text-sm font-medium text-foreground">
                {t('employees.form.phone_label', 'Telèfon')}
              </label>
              <Input
                {...register('phone')}
                placeholder={t('employees.form.phone_placeholder', 'p.ex. 600 000 000')}
              />
            </div>
            {perms.canViewPrivate ? (
              <div className="space-y-1">
                <label className="text-sm font-medium text-foreground">
                  {t('employees.form.document_id_label', 'Document (DNI/NIE)')}
                </label>
                <Input
                  {...register('document_id')}
                  disabled={!perms.canManagePrivate}
                  placeholder={t('employees.form.document_id_placeholder', 'p.ex. 12345678A')}
                />
              </div>
            ) : null}
          </div>

          {/* Lloc de treball */}
          <div className="space-y-1">
            <label className="text-sm font-medium text-foreground">
              {t('employees.form.job_position_label', 'Lloc de treball')}
            </label>
            <select
              {...register('job_position_id')}
              className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            >
              <option value="">{t('employees.form.no_job_position', 'Sense lloc de treball')}</option>
              {jobPositions.map((p) => (
                <option key={p.id!} value={p.id!}>
                  {p.name}
                  {p.code ? ` (${p.code})` : ''}
                </option>
              ))}
            </select>
          </div>

          {/* Estat */}
          <div className="space-y-1">
            <label className="text-sm font-medium text-foreground">
              {t('employees.form.status_label', 'Estat')}
            </label>
            <select
              {...register('status')}
              className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            >
              {EMPLOYEE_STATUSES.map((s) => (
                <option key={s} value={s}>{statusLabels[s]}</option>
              ))}
            </select>
          </div>

          {/* Dates d'inici i fi */}
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1">
              <label className="text-sm font-medium text-foreground">
                {t('employees.form.starts_on_label', "Data d'incorporació")}
              </label>
              <Input {...register('starts_on')} type="date" />
            </div>
            <div className="space-y-1">
              <label className="text-sm font-medium text-foreground">
                {t('employees.form.ends_on_label', 'Data de baixa')}
              </label>
              <Input {...register('ends_on')} type="date" />
            </div>
          </div>

          {/* Hores setmanals */}
          <div className="space-y-1">
            <label className="text-sm font-medium text-foreground">
              {t('employees.form.weekly_hours_label', 'Hores setmanals')}
            </label>
            <Input
              {...register('weekly_hours')}
              type="number"
              min={0}
              step={0.5}
              placeholder={t('employees.form.weekly_hours_placeholder', 'p.ex. 40')}
            />
            {errors.weekly_hours && (
              <p className="text-xs text-destructive">{t('employees.validation.weekly_hours_min', 'Les hores no poden ser negatives')}</p>
            )}
          </div>

          {/* Departament */}
          <div className="space-y-1">
            <label className="text-sm font-medium text-foreground">
              {t('employees.form.department_label', 'Departament')}
            </label>
            <select
              {...register('department_id')}
              className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            >
              <option value="">{t('employees.form.no_department', '(Sense departament)')}</option>
              {departments.map((d) => (
                <option key={d.id} value={d.id ?? ''}>{d.name}</option>
              ))}
            </select>
            {errors.department_id && (
              <p className="text-xs text-destructive">
                {t('employees.validation.department_invalid', 'Departament no vàlid')}
              </p>
            )}
          </div>

          {/* Local (site) */}
          <div className="space-y-1">
            <label className="text-sm font-medium text-foreground">
              {t('employees.form.site_label', 'Local')}
            </label>
            <select
              {...register('site_id')}
              className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            >
              <option value="">
                {t('employees.form.no_site_assigned', '(Sense local assignat)')}
              </option>
              {siteOptions.map((s) => (
                <option key={s.id} value={s.id}>{s.name}</option>
              ))}
            </select>
            {errors.site_id && (
              <p className="text-xs text-destructive">
                {employeeFieldErrorMessage(t, 'site_id', errors)}
              </p>
            )}
          </div>

          {/* Botons */}
          <div className="flex justify-end gap-2 pt-3 sticky bottom-0 bg-background border-t border-border mt-2 -mx-1 px-1 pb-1">
            <Button type="button" variant="ghost" onClick={onClose} disabled={isSubmitting}>
              {t('employees.form.cancel', 'Cancel·lar')}
            </Button>
            <Button type="submit" disabled={isSubmitting || !isValid}>
              {isSubmitting && <Loader2 className="h-4 w-4 mr-2 animate-spin" aria-hidden />}
              {isSubmitting
                ? t('employees.form.saving', 'Desant…')
                : t('employees.form.save', 'Desar')}
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  )
}
