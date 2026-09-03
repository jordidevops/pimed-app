import React, { useCallback, useEffect, useMemo, useState } from 'react'
import { useNavigate, useParams, useSearchParams } from 'react-router-dom'
import { useForm, type FieldErrors } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { useTranslation } from 'react-i18next'
import { ArrowLeft, Loader2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useAuth } from '@/contexts/AuthContext'
import { usePermission } from '@/hooks/usePermission'
import { useDepartments } from '@/features/departments/api/useDepartments'
import { DocumentsPage } from '@/features/documents'
import { EmployeeTimesheetTab } from '@/features/attendance/components/EmployeeTimesheetTab'
import { useEmployee } from '../api/useEmployee'
import { useEmployeeHrProfile } from '../api/useEmployeeHrProfile'
import { useUpdateEmployee } from '../api/useUpdateEmployee'
import { normalizeEmployeeError } from '../api/employeesService'
import { useEmployeePermissions } from '../hooks/useEmployeePermissions'
import { EntityTimeline, getEntityTimeline } from '@/features/entity-timeline'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { employeeSchema, EMPLOYEE_STATUSES } from '../schemas/employeeSchema'
import type { EmployeeFormInput, EmployeeFormValues, EmployeeStatus } from '../schemas/employeeSchema'
import {
  buildEmployeeSiteOptions,
  defaultEmployeeSiteId,
  fromAttendanceGeoEnabledFormValue,
  sanitizeUuidField,
  toAttendanceGeoEnabledFormValue,
  fromAttendanceWorkProfileFormValue,
  toAttendanceWorkProfileFormValue,
} from '../schemas/employeeFormFields'
import { employeeFieldErrorMessage, employeeValidationToastDescription } from '../utils/employeeFormUi'
import {
  useCalendarGroups,
  useSetEmployeeCalendarGroup,
  sanitizeOptionalUuid,
} from '@/features/attendance/api/useLaborCalendar'
import { EmployeeLaborCalendarView } from '@/features/attendance/components/EmployeeLaborCalendarView'
import { AttendanceGeoEnabledField } from '@/features/attendance/components/AttendanceGeoEnabledField'
import { AttendancePunchOnlyAtStationsField } from '@/features/attendance/components/AttendancePunchOnlyAtStationsField'
import { AttendanceWorkProfileField } from '@/features/attendance/components/AttendanceWorkProfileField'
import { AttendanceRecordPolicyPreview } from '@/features/attendance/components/AttendanceRecordPolicyPreview'
import { attendanceRecordPolicyQueryKey } from '@/features/attendance/api/useAttendanceRecordPolicy'
import { EmployeePortalAccessTab } from '@/features/employee-portal'
import { EmployeeRolesQualsSection } from './EmployeeRolesQualsSection'
import { EmployeeAvailabilitySection } from './EmployeeAvailabilitySection'
import { EmployeeExternalMappingsSection } from './EmployeeExternalMappingsSection'
import { EmployeeCertificationsSection } from './EmployeeCertificationsSection'
import { EmployeeLifecycleSection } from './EmployeeLifecycleSection'
import { EmployeeReadinessBadge } from './EmployeeReadinessBadge'
import { EmployeeHeaderAvatar } from './EmployeePhotoUploader'
import { ScrollableTabBar } from '@/components/ui/scrollable-tab-bar'
import { EmployeeUserLinkField } from './EmployeeUserLinkField'
import { EmployeeTagsField } from './EmployeeTagsField'
import { EmployeeOrganizationSection } from './EmployeeOrganizationSection'
import { EmployeePrivateProfileTab } from './EmployeePrivateProfileTab'
import { useJobPositions } from '../api/useJobPositions'
import { jobPlaceName } from '../utils/jobPlaceName'
import { EmployeeSkillsTab } from '@/features/employee-skills'
import { EmployeeContractsTab } from './EmployeeContractsTab'
import { EmployeeEquipmentTab } from './EmployeeEquipmentTab'
import { useEffectiveEmploymentContract } from '../api/useEmploymentContracts'

type Tab =
  | 'info'
  | 'personal'
  | 'skills'
  | 'contracts'
  | 'equipment'
  | 'documents'
  | 'timesheet'
  | 'work_calendar'
  | 'activity'
  | 'portal_access'
  | 'certifications'

export function EmployeeDetailPage() {
  const { id } = useParams<{ id: string }>()
  const navigate = useNavigate()
  const [searchParams] = useSearchParams()
  const tabParam = searchParams.get('tab')
  const isWideTab = tabParam === 'work_calendar' || tabParam === 'timesheet'
  const { t } = useTranslation('employees')
  const { toast } = useToast()
  const { sites, selectedSiteId } = useTenant()
  const { user } = useAuth()
  const { data: employee, isLoading } = useEmployee(id)
  const perms = useEmployeePermissions(employee)
  const canWrite = perms.canManage
  const canManageSkills = usePermission('employees.skills.manage')
  const canViewContracts =
    usePermission('employees.contracts.view') || usePermission('employees.contracts.manage')
  const canManageContracts = usePermission('employees.contracts.manage') || canWrite
  const canViewEquipment =
    usePermission('assets.employee_assignments.view') ||
    usePermission('assets.employee_assignments.manage')
  const canManageEquipment = usePermission('assets.employee_assignments.manage')
  const canViewCertifications =
    usePermission('compliance.certifications.view') ||
    usePermission('compliance.medical_clearance.view')
  const canViewPrivateTab =
    perms.canViewPrivate || perms.canManagePrivate || employee?.user_id === user?.id
  const { data: hrProfile } = useEmployeeHrProfile(
    id,
    (perms.canViewPrivate || perms.canManagePrivate) && !!id,
  )
  const { data: departments = [] } = useDepartments()
  const { data: jobPositions = [] } = useJobPositions(true)
  const updateMutation = useUpdateEmployee()
  const queryClient = useQueryClient()
  const { data: effectiveContract } = useEffectiveEmploymentContract(id)
  const legacyTermsLocked = Boolean(effectiveContract?.id)

  const {
    register,
    handleSubmit,
    reset,
    setValue,
    watch,
    trigger,
    formState: { errors, isSubmitting, isDirty, isValid },
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
      job_position_id: '',
      manager_employee_id: '',
      status: 'active',
      starts_on: '',
      ends_on: '',
      weekly_hours: null,
      department_id: '',
      site_id: '',
      attendance_geo_enabled: 'inherit',
      punch_only_at_stations: 'inherit',
      attendance_work_profile: 'inherit',
    },
  })

  const siteOptions = useMemo(
    () =>
      buildEmployeeSiteOptions(
        sites,
        employee?.site_id,
        t('employees.form.site_inactive', 'Local assignat (inactiu)'),
      ),
    [sites, employee?.site_id, t],
  )

  // Sync form quan l'empleat es carrega
  useEffect(() => {
    if (!employee) return
    reset({
      full_name: employee.full_name ?? '',
      preferred_name: employee.preferred_name ?? '',
      legal_name: employee.legal_name ?? '',
      employee_code: employee.employee_code ?? '',
      email: employee.email ?? '',
      phone: employee.phone ?? '',
      job_position_id: sanitizeUuidField(employee.job_position_id),
      manager_employee_id: sanitizeUuidField(employee.manager_employee_id),
      status: (employee.status as EmployeeFormValues['status']) ?? 'active',
      starts_on: employee.starts_on ?? '',
      ends_on: employee.ends_on ?? '',
      weekly_hours: employee.weekly_hours ?? null,
      department_id: sanitizeUuidField(employee.department_id),
      site_id: defaultEmployeeSiteId(employee.site_id, sites, selectedSiteId),
      attendance_geo_enabled: toAttendanceGeoEnabledFormValue(
        (employee as { attendance_geo_enabled?: boolean | null }).attendance_geo_enabled,
      ),
      punch_only_at_stations: toAttendanceGeoEnabledFormValue(
        (employee as { punch_only_at_stations?: boolean | null }).punch_only_at_stations,
      ),
      attendance_work_profile: toAttendanceWorkProfileFormValue(
        (employee as { attendance_work_profile?: string | null }).attendance_work_profile,
      ),
    })
    void trigger()
  }, [employee, reset, sites, departments, selectedSiteId, trigger])

  const watchedStatus = watch('status')
  const watchedEndsOn = watch('ends_on')

  // Auto-omplir data de baixa quan canvia a terminated
  useEffect(() => {
    if (watchedStatus === 'terminated' && !watchedEndsOn) {
      setValue('ends_on', new Date().toISOString().slice(0, 10))
    }
  }, [watchedStatus, watchedEndsOn, setValue])

  const statusLabels: Record<EmployeeStatus, string> = {
    active: t('employees.status.active', 'Actiu'),
    inactive: t('employees.status.inactive', 'Inactiu'),
    terminated: t('employees.status.terminated', 'Baixa definitiva'),
  }

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
    if (!id) return
    try {
      const updated = await updateMutation.mutateAsync({
        id,
        params: {
          full_name: values.full_name,
          preferred_name: values.preferred_name?.trim() || null,
          legal_name: values.legal_name?.trim() || null,
          employee_code: values.employee_code?.trim() || null,
          email: values.email || null,
          phone: values.phone || null,
          job_position_id: values.job_position_id ?? null,
          manager_employee_id: values.manager_employee_id ?? null,
          status: values.status,
          ...(legacyTermsLocked
            ? {}
            : {
                starts_on: values.starts_on || null,
                ends_on: values.ends_on || null,
                weekly_hours: values.weekly_hours ?? null,
              }),
          department_id: values.department_id ?? null,
          site_id: values.site_id ?? null,
          attendance_geo_enabled: fromAttendanceGeoEnabledFormValue(values.attendance_geo_enabled),
          punch_only_at_stations: fromAttendanceGeoEnabledFormValue(values.punch_only_at_stations),
          attendance_work_profile: fromAttendanceWorkProfileFormValue(values.attendance_work_profile),
        },
      })

      reset({
        full_name: updated.full_name ?? '',
        preferred_name: updated.preferred_name ?? '',
        legal_name: updated.legal_name ?? '',
        employee_code: updated.employee_code ?? '',
        email: updated.email ?? '',
        phone: updated.phone ?? '',
        job_position_id: sanitizeUuidField(updated.job_position_id),
        manager_employee_id: sanitizeUuidField(updated.manager_employee_id),
        status: (updated.status as EmployeeFormValues['status']) ?? 'active',
        starts_on: updated.starts_on ?? '',
        ends_on: updated.ends_on ?? '',
        weekly_hours: updated.weekly_hours ?? null,
        department_id: sanitizeUuidField(updated.department_id),
        site_id: defaultEmployeeSiteId(updated.site_id, sites, selectedSiteId),
        attendance_geo_enabled: toAttendanceGeoEnabledFormValue(
          (updated as { attendance_geo_enabled?: boolean | null }).attendance_geo_enabled,
        ),
        punch_only_at_stations: toAttendanceGeoEnabledFormValue(
          (updated as { punch_only_at_stations?: boolean | null }).punch_only_at_stations,
        ),
        attendance_work_profile: toAttendanceWorkProfileFormValue(
          (updated as { attendance_work_profile?: string | null }).attendance_work_profile,
        ),
      })
      await queryClient.invalidateQueries({ queryKey: attendanceRecordPolicyQueryKey(id) })
      toast({ description: t('employees.toast.updated', 'Empleat actualitzat') })
    } catch (err) {
      const kind = normalizeEmployeeError(err)
      const rawMessage = err instanceof Error ? err.message : ''
      toast({
        variant: 'destructive',
        description:
          kind === 'unauthorized'
            ? t('employees.errors.unauthorized', 'No tens permís per fer aquesta acció')
            : rawMessage.includes('legacy_terms_locked')
              ? t(
                  'employees.form.legacy_terms_locked',
                  'Dates i hores venen del contracte efectiu. Edita’ls a la pestanya Contractes.',
                )
              : rawMessage || t('employees.errors.generic', "Error en desar l'empleat"),
      })
    }
  }

  // Estats de càrrega / no trobat
  if (isLoading) {
    return (
      <div className="p-6 text-sm text-muted-foreground">
        {t('employees.detail.loading', 'Carregant...')}
      </div>
    )
  }

  if (!employee) {
    return (
      <div className="p-6 space-y-4" data-testid="employee-not-found">
        <p className="text-sm text-muted-foreground">
          {t('employees.detail.not_found', 'Empleat no trobat')}
        </p>
        <Button variant="outline" size="sm" onClick={() => navigate('/employees')}>
          <ArrowLeft className="h-4 w-4 mr-1" />
          {t('employees.detail.back', 'Tornar a empleats')}
        </Button>
      </div>
    )
  }

  const displayName = employee.preferred_name?.trim() || employee.full_name
  const lifecycleState = employee.lifecycle_state ?? 'active'
  const siteName =
    sites.length > 1 && employee.site_id
      ? sites.find((s) => s.id === employee.site_id)?.name
      : undefined
  const positionsById: Record<string, { name?: string | null }> = {}
  for (const p of jobPositions) {
    if (p.id) positionsById[p.id] = p
  }
  const metaParts = [
    employee.employee_code || null,
    jobPlaceName(employee.job_position_id, positionsById) || null,
    siteName || null,
  ].filter(Boolean) as string[]

  const stickyHeader = (
    <div className="flex flex-wrap items-start gap-3 pb-3">
      <Button
        variant="ghost"
        size="icon"
        className="shrink-0 mt-1"
        onClick={() => navigate('/employees')}
        aria-label={t('employees.detail.back', 'Tornar a empleats')}
      >
        <ArrowLeft className="h-4 w-4" />
      </Button>
      <EmployeeHeaderAvatar
        employeeId={id!}
        fullName={employee.full_name}
        preferredName={employee.preferred_name}
        photoObjectPath={employee.photo_object_path}
        canWrite={canWrite}
      />
      <div className="min-w-0 flex-1 space-y-0.5">
        <h1 className="text-xl font-semibold truncate leading-tight" data-testid="employee-detail-name">
          {displayName}
        </h1>
        <p
          className="text-sm font-medium text-foreground/80"
          data-testid="employee-lifecycle-state"
        >
          {t(`employees.lifecycle.states.${lifecycleState}`, lifecycleState)}
        </p>
        {metaParts.length > 0 ? (
          <p className="text-xs text-muted-foreground truncate">
            {metaParts.join(' · ')}
          </p>
        ) : null}
      </div>
      <div className="w-full sm:w-auto sm:ml-auto sm:max-w-xs sm:shrink-0">
        <EmployeeReadinessBadge employeeId={id!} compact />
      </div>
    </div>
  )

  return (
    <div className={`p-4 sm:p-6 w-full ${isWideTab ? 'max-w-none' : 'max-w-7xl mx-auto'}`}>
      <EmployeeDetailTabs
        employeeId={id!}
        canWrite={canWrite}
        isOwnEmployee={employee.user_id === user?.id}
        canViewCertifications={canViewCertifications}
        canViewPersonal={!!canViewPrivateTab}
        canViewContracts={canViewContracts || canWrite}
        canViewEquipment={canViewEquipment}
        stickyHeader={stickyHeader}
      >
        {/* Formulari inline - Info */}
        {({ activeTab, selectTab }: { activeTab: Tab; selectTab: (tab: Tab) => void }) =>
          activeTab === 'info' ? (
            <form onSubmit={handleSubmit(onSubmit, onInvalid)} className="space-y-4">
              {/* Nom complet */}
              <div className="space-y-1">
                <label className="text-sm font-medium">
                  {t('employees.form.full_name_label', 'Nom complet')}
                  <span className="text-destructive ml-0.5">*</span>
                </label>
                <Input
                  {...register('full_name')}
                  disabled={!canWrite}
                  placeholder={t('employees.form.full_name_placeholder', 'p.ex. Anna Garcia López')}
                />
                {errors.full_name && (
                  <p className="text-xs text-destructive">
                    {employeeFieldErrorMessage(t, 'full_name', errors) ??
                      t('employees.validation.full_name_required', 'El nom és obligatori')}
                  </p>
                )}
              </div>

              {/* Nom preferit + Nom legal + Codi */}
              <div className="grid gap-3 sm:grid-cols-3">
                <div className="space-y-1">
                  <label className="text-sm font-medium">
                    {t('employees.form.preferred_name_label', 'Nom preferit')}
                  </label>
                  <Input
                    {...register('preferred_name')}
                    disabled={!canWrite}
                    placeholder={t('employees.form.preferred_name_placeholder', 'p.ex. Anna')}
                  />
                </div>
                <div className="space-y-1">
                  <label className="text-sm font-medium">
                    {t('employees.form.legal_name_label', 'Nom legal')}
                  </label>
                  <Input
                    {...register('legal_name')}
                    disabled={!canWrite}
                    placeholder={t('employees.form.legal_name_placeholder', 'Nom al DNI / contracte')}
                  />
                </div>
                <div className="space-y-1">
                  <label className="text-sm font-medium">
                    {t('employees.form.employee_code_label', 'Codi empleat')}
                  </label>
                  <Input
                    {...register('employee_code')}
                    disabled={!canWrite}
                    placeholder={t('employees.form.employee_code_placeholder', 'p.ex. EMP-001')}
                  />
                </div>
              </div>

              {/* Email */}
              <div className="space-y-1">
                <label className="text-sm font-medium">
                  {t('employees.form.email_label', 'Correu electrònic')}
                </label>
                <Input
                  {...register('email')}
                  type="email"
                  disabled={!canWrite}
                  placeholder={t('employees.form.email_placeholder', 'p.ex. anna@empresa.com')}
                />
                {errors.email && (
                  <p className="text-xs text-destructive">
                    {employeeFieldErrorMessage(t, 'email', errors)}
                  </p>
                )}
              </div>

              {/* Telèfon */}
              <div className="space-y-1">
                <label className="text-sm font-medium">
                  {t('employees.form.phone_label', 'Telèfon')}
                </label>
                <Input
                  {...register('phone')}
                  disabled={!canWrite}
                  placeholder={t('employees.form.phone_placeholder', 'p.ex. 600 000 000')}
                />
              </div>

              {/* Lloc de treball */}
              <div className="space-y-1">
                <label className="text-sm font-medium">
                  {t('employees.form.job_position_label', 'Lloc de treball')}
                </label>
                <select
                  {...register('job_position_id')}
                  disabled={!canWrite}
                  className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:opacity-60"
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

              <EmployeeUserLinkField
                employeeId={id!}
                linkedUserId={employee.user_id}
                canWrite={canWrite}
              />

              <EmployeeTagsField employeeId={id!} canWrite={canWrite} />

              <EmployeeOrganizationSection
                employeeId={id!}
                managerEmployeeId={watch('manager_employee_id') || null}
                canWrite={canWrite}
                onManagerChange={(managerId) =>
                  setValue('manager_employee_id', managerId ?? '', {
                    shouldDirty: true,
                    shouldValidate: true,
                  })
                }
              />

              {/* Estat */}
              <div className="space-y-1">
                <label className="text-sm font-medium">
                  {t('employees.form.status_label', 'Estat')}
                </label>
                <select
                  {...register('status')}
                  disabled={!canWrite}
                  className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:opacity-60"
                >
                  {EMPLOYEE_STATUSES.map((s) => (
                    <option key={s} value={s}>{statusLabels[s]}</option>
                  ))}
                </select>
              </div>

              {/* Dates */}
              <div className="grid grid-cols-2 gap-3">
                <div className="space-y-1">
                  <label className="text-sm font-medium">
                    {t('employees.form.starts_on_label', "Data d'incorporació")}
                  </label>
                  <Input
                    {...register('starts_on')}
                    type="date"
                    disabled={!canWrite || legacyTermsLocked}
                  />
                </div>
                <div className="space-y-1">
                  <label className="text-sm font-medium">
                    {t('employees.form.ends_on_label', 'Data de baixa')}
                  </label>
                  <Input
                    {...register('ends_on')}
                    type="date"
                    disabled={!canWrite || legacyTermsLocked}
                  />
                </div>
              </div>

              {/* Hores setmanals */}
              <div className="space-y-1">
                <label className="text-sm font-medium">
                  {t('employees.form.weekly_hours_label', 'Hores setmanals')}
                </label>
                <Input
                  {...register('weekly_hours')}
                  type="number"
                  min={0}
                  step={0.5}
                  disabled={!canWrite || legacyTermsLocked}
                  placeholder={t('employees.form.weekly_hours_placeholder', 'p.ex. 40')}
                />
                {legacyTermsLocked ? (
                  <p className="text-xs text-muted-foreground">
                    {t(
                      'employees.form.legacy_terms_locked',
                      'Dates i hores venen del contracte efectiu. Edita’ls a la pestanya Contractes.',
                    )}
                  </p>
                ) : null}
                {errors.weekly_hours && (
                  <p className="text-xs text-destructive">
                    {employeeFieldErrorMessage(t, 'weekly_hours', errors)}
                  </p>
                )}
              </div>

              {/* Departament */}
              <div className="space-y-1">
                <label className="text-sm font-medium">
                  {t('employees.form.department_label', 'Departament')}
                </label>
                <select
                  {...register('department_id')}
                  disabled={!canWrite}
                  className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:opacity-60"
                >
                  <option value="">{t('employees.form.no_department', '(Sense departament)')}</option>
                  {departments.map((d) => (
                    <option key={d.id} value={d.id ?? ''}>{d.name}</option>
                  ))}
                </select>
                {errors.department_id && (
                  <p className="text-xs text-destructive">
                    {employeeFieldErrorMessage(t, 'department_id', errors)}
                  </p>
                )}
              </div>

              {/* Local */}
              <div className="space-y-1">
                <label className="text-sm font-medium">
                  {t('employees.form.site_label', 'Local')}
                </label>
                <select
                  {...register('site_id')}
                  disabled={!canWrite}
                  className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:opacity-60"
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

              {/* Grup de calendari – gestionat per RPC fora del formulari estàndard */}
              <AttendanceGeoEnabledField
                value={watch('attendance_geo_enabled') ?? 'inherit'}
                onChange={(v) => setValue('attendance_geo_enabled', v, { shouldDirty: true, shouldValidate: true })}
                disabled={!canWrite}
                inheritLabel={t(
                  'employees.form.attendance_geo_inherit',
                  'Heretar (departament / grup / tenant)',
                )}
                hint={t(
                  'employees.form.attendance_geo_hint',
                  'Override per aquest empleat. Si està desactivat, no es desa geo al fitxar encara amb consentiment.',
                )}
              />

              <AttendancePunchOnlyAtStationsField
                value={watch('punch_only_at_stations') ?? 'inherit'}
                onChange={(v) => setValue('punch_only_at_stations', v, { shouldDirty: true, shouldValidate: true })}
                disabled={!canWrite}
                inheritLabel={t(
                  'employees.form.punch_only_inherit',
                  'Heretar (grup / site / tenant)',
                )}
                hint={t(
                  'employees.form.punch_only_hint',
                  'Excepció per teletreball o casos mixtos. «Permetre portal» força el mòbil encara que el grup i el tenant diguin només estacions.',
                )}
              />

              <AttendanceWorkProfileField
                value={watch('attendance_work_profile') ?? 'inherit'}
                onChange={(v) =>
                  setValue('attendance_work_profile', v, { shouldDirty: true, shouldValidate: true })
                }
                disabled={!canWrite}
                inheritLabel={t(
                  'employees.form.attendance_work_profile_inherit',
                  'Hereta (grup / conveni)',
                )}
                hint={t(
                  'employees.form.attendance_work_profile_hint',
                  'Override del perfil de jornada. Si hereta, s\'aplica la política del grup o conveni.',
                )}
              />

              <AttendanceRecordPolicyPreview employeeId={id!} />

              <EmployeeCalendarGroupSelector
                employeeId={id!}
                siteId={watch('site_id') ?? undefined}
                currentGroupId={(employee as { calendar_group_id?: string | null }).calendar_group_id ?? null}
                canWrite={canWrite}
              />

              <EmployeeRolesQualsSection employeeId={id!} canWrite={canWrite} />

              <EmployeeLifecycleSection
                employeeId={id!}
                lifecycleState={employee.lifecycle_state}
                siteId={employee.site_id}
              />

              <EmployeeAvailabilitySection employeeId={id!} canWrite={canWrite} />

              <EmployeeExternalMappingsSection employeeId={id!} />

              {canWrite && (
                <div className="flex justify-end pt-2">
                  <Button
                    type="submit"
                    disabled={isSubmitting || !isDirty || !isValid}
                  >
                    {isSubmitting && <Loader2 className="h-4 w-4 mr-2 animate-spin" aria-hidden />}
                    {isSubmitting
                      ? t('employees.form.saving', 'Desant…')
                      : t('employees.form.save_changes', 'Desar canvis')}
                  </Button>
                </div>
              )}
            </form>
          ) : activeTab === 'personal' ? (
            <EmployeePrivateProfileTab
              employeeId={id!}
              canView={perms.canViewPrivate || perms.canManagePrivate}
              canManageHr={perms.canManagePrivate}
              canReveal={perms.canRevealPrivate}
              isOwnEmployee={employee.user_id === user?.id}
            />
          ) : activeTab === 'skills' ? (
            <EmployeeSkillsTab employeeId={id!} canManage={canManageSkills || canWrite} />
          ) : activeTab === 'contracts' ? (
            <EmployeeContractsTab
              employeeId={id!}
              canView={canViewContracts || canWrite}
              canManage={canManageContracts}
            />
          ) : activeTab === 'equipment' ? (
            <EmployeeEquipmentTab
              employeeId={id!}
              siteId={employee.site_id}
              canView={canViewEquipment}
              canManage={canManageEquipment}
            />
          ) : activeTab === 'documents' ? (
            <DocumentsPage
              entityFilter={{ type: 'employee', id: id! }}
              entityLabel={employee?.full_name ?? undefined}
              entityEmail={employee?.email ?? undefined}
            />
          ) : activeTab === 'activity' ? (
            <EntityTimeline
              entityType="employee"
              entityId={id!}
              siteId={employee.site_id}
            />
          ) : activeTab === 'timesheet' ? (
            <EmployeeTimesheetTab
              employeeId={id!}
              siteId={employee.site_id ?? undefined}
              employeeName={employee.full_name ?? undefined}
              employeeEmail={employee.email ?? undefined}
              employeePhone={employee.phone ?? undefined}
              workProfile={(employee as { attendance_work_profile?: string | null }).attendance_work_profile}
              canManage={canWrite}
            />
          ) : activeTab === 'portal_access' ? (
            <EmployeePortalAccessTab
              employeeId={id!}
              employeeName={employee.full_name ?? undefined}
              employeeEmail={employee.email ?? undefined}
              employeeCode={hrProfile?.document_id ?? undefined}
              employeeStatus={employee.status}
              canManage={canWrite}
              onOpenProfileTab={() => selectTab('info')}
            />
          ) : activeTab === 'certifications' ? (
            <EmployeeCertificationsSection employeeId={id!} />
          ) : (
            <EmployeeLaborCalendarView
              employeeId={id!}
              siteId={employee.site_id ?? undefined}
              calendarGroupId={(employee as { calendar_group_id?: string | null }).calendar_group_id ?? null}
              canWrite={canWrite}
            />
          )
        }
      </EmployeeDetailTabs>
    </div>
  )
}

// Subcomponent de tabs

interface EmployeeDetailTabsProps {
  employeeId: string
  canWrite: boolean
  isOwnEmployee: boolean
  canViewCertifications: boolean
  canViewPersonal: boolean
  canViewContracts: boolean
  canViewEquipment: boolean
  stickyHeader?: React.ReactNode
  children: (ctx: { activeTab: Tab; selectTab: (tab: Tab) => void }) => React.ReactNode
}

function EmployeeDetailTabs({
  employeeId,
  canWrite,
  isOwnEmployee,
  canViewCertifications,
  canViewPersonal,
  canViewContracts,
  canViewEquipment,
  stickyHeader,
  children,
}: EmployeeDetailTabsProps) {
  const { t } = useTranslation(['employees', 'activity'])
  const [searchParams, setSearchParams] = useSearchParams()
  const tabParam = searchParams.get('tab')
  const commentParam = searchParams.get('comment')
  const initialTab: Tab = (() => {
    if (tabParam === 'activity' || commentParam) return 'activity'
    if (
      tabParam === 'documents' ||
      tabParam === 'timesheet' ||
      tabParam === 'work_calendar' ||
      tabParam === 'portal_access' ||
      tabParam === 'certifications' ||
      tabParam === 'personal' ||
      tabParam === 'skills' ||
      tabParam === 'contracts' ||
      tabParam === 'equipment'
    ) {
      return tabParam
    }
    return 'info'
  })()
  const [activeTab, setActiveTab] = useState<Tab>(initialTab)
  const [unreadCount, setUnreadCount] = useState(0)
  const canSeeAttendance = canWrite || isOwnEmployee

  const { data: unreadData } = useQuery({
    queryKey: ['entity-timeline-unread', 'employee', employeeId],
    queryFn: () =>
      getEntityTimeline({
        entityType: 'employee',
        entityId: employeeId,
        limit: 1,
      }),
    enabled: !!employeeId,
    staleTime: 0,
  })

  useEffect(() => {
    setUnreadCount(unreadData?.page.unread_since_last_visit ?? 0)
  }, [unreadData])

  useEffect(() => {
    if (commentParam && activeTab !== 'activity') {
      setActiveTab('activity')
      const next = new URLSearchParams(searchParams)
      next.set('tab', 'activity')
      setSearchParams(next, { replace: true })
      return
    }
    if (tabParam && tabParam !== activeTab) {
      if (
        tabParam === 'activity' ||
        tabParam === 'documents' ||
        tabParam === 'timesheet' ||
        tabParam === 'work_calendar' ||
        tabParam === 'portal_access' ||
        tabParam === 'certifications' ||
        tabParam === 'personal' ||
        tabParam === 'skills' ||
        tabParam === 'contracts' ||
        tabParam === 'equipment' ||
        tabParam === 'info'
      ) {
        setActiveTab(tabParam)
      }
    }
  }, [tabParam, commentParam, activeTab, searchParams, setSearchParams])

  function selectTab(tab: Tab) {
    setActiveTab(tab)
    const next = new URLSearchParams(searchParams)
    if (tab === 'info') next.delete('tab')
    else next.set('tab', tab)
    setSearchParams(next, { replace: true })
  }

  const allTabs: { id: Tab; label: string; visible: boolean; badge?: number }[] = [
    { id: 'info', label: t('employees.detail.tabInfo', 'Informació'), visible: true },
    {
      id: 'personal',
      label: t('employees.detail.tabPersonal', 'Informació personal'),
      visible: canViewPersonal,
    },
    {
      id: 'skills',
      label: t('employees.detail.tabSkills', 'Skills'),
      visible: true,
    },
    {
      id: 'contracts',
      label: t('employees.detail.tabContracts', 'Contractes'),
      visible: canViewContracts,
    },
    {
      id: 'equipment',
      label: t('employees.detail.tabEquipment', 'Equipament'),
      visible: canViewEquipment,
    },
    { id: 'activity', label: t('activity:timeline.title', 'Activitat'), visible: true, badge: unreadCount },
    { id: 'documents', label: t('employees.detail.tabDocuments', 'Documents'), visible: true },
    {
      id: 'certifications',
      label: t('employees.detail.tabCertifications', 'Certificacions'),
      visible: canViewCertifications,
    },
    { id: 'timesheet', label: t('employees.detail.tabTimesheet', 'Full horari'), visible: canSeeAttendance },
    { id: 'work_calendar', label: t('employees.detail.tabWorkCalendar', 'Calendari laboral'), visible: canSeeAttendance },
    { id: 'portal_access', label: t('employees.detail.tabPortalAccess', 'Accés Portal'), visible: canWrite },
  ]
  const visibleTabs = allTabs.filter((tab) => tab.visible)

  return (
    <div>
      <div className="sticky top-0 z-20 -mx-4 sm:-mx-6 px-4 sm:px-6 pt-1 bg-background/95 backdrop-blur supports-[backdrop-filter]:bg-background/80 border-b border-border">
        {stickyHeader}
        <ScrollableTabBar
          activeKey={activeTab}
          aria-label={t('employees.detail.tabs', "Seccions de l'empleat")}
          className="-mb-px"
        >
          {visibleTabs.map((tab) => (
            <button
              key={tab.id}
              type="button"
              role="tab"
              data-tab-key={tab.id}
              aria-selected={activeTab === tab.id}
              onClick={() => selectTab(tab.id)}
              className={`px-3 sm:px-4 py-2.5 text-sm font-medium border-b-2 transition-colors whitespace-nowrap flex items-center gap-1.5 shrink-0 ${
                activeTab === tab.id
                  ? 'border-primary text-primary'
                  : 'border-transparent text-muted-foreground hover:text-foreground'
              }`}
            >
              {tab.label}
              {tab.badge != null && tab.badge > 0 && tab.id !== activeTab && (
                <span className="inline-flex min-w-[1.25rem] h-5 px-1 items-center justify-center rounded-full bg-primary text-primary-foreground text-[10px] font-semibold">
                  {tab.badge > 99 ? '99+' : tab.badge}
                </span>
              )}
            </button>
          ))}
        </ScrollableTabBar>
      </div>
      <div className="pt-6">{children({ activeTab, selectTab })}</div>
    </div>
  )
}


function EmployeeCalendarGroupSelector({
  employeeId, siteId, currentGroupId, canWrite,
}: {
  employeeId: string
  siteId?: string
  currentGroupId: string | null
  canWrite: boolean
}) {
  const { t } = useTranslation('attendance')
  const { data: groups = [] } = useCalendarGroups(sanitizeOptionalUuid(siteId))
  const { mutate: setGroup, isPending } = useSetEmployeeCalendarGroup()
  const [value, setValue] = useState(currentGroupId ?? '')

  useEffect(() => { setValue(currentGroupId ?? '') }, [currentGroupId])

  function handleChange(e: React.ChangeEvent<HTMLSelectElement>) {
    const v = e.target.value
    setValue(v)
    setGroup({ employeeId, calendarGroupId: v || null })
  }

  return (
    <div className="space-y-1">
      <label className="text-sm font-medium">
        {t('cal_groups.employee_group_label', 'Grup de calendari')}
      </label>
      <select
        value={value}
        onChange={handleChange}
        disabled={!canWrite || isPending}
        className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:opacity-60"
      >
        <option value="">{t('cal_groups.no_group', '(Sense grup)')}</option>
        {groups.map((g) => (
          <option key={g.id} value={g.id}>
            {g.name}
          </option>
        ))}
      </select>
      <p className="text-xs text-muted-foreground">
        {t('cal_groups.employee_group_hint', "El grup defineix overrides de calendari que prevalen sobre l'empresa i el local.")}
      </p>
    </div>
  )
}
