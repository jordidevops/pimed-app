import { useEffect } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { useTranslation } from 'react-i18next'
import { useNavigate } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
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
import { useIsFieldService } from '@/hooks/useSectorLabel'
import { useCreateProject } from '../api/useCreateProject'
import { useUpdateProject } from '../api/useUpdateProject'
import type { Project } from '../api/projectsService'
import { useDepartments } from '@/features/departments/api/useDepartments'
import { getContacts, getContactSites } from '@/features/contacts/api/contactsService'
import {
  applyPricingTemplate,
  listPricingTemplateItems,
  listPricingTemplates,
} from '@/features/commercial/api/commercialFlowService'
import { cn } from '@/lib/utils'

const projectSchema = z.object({
  name: z.string().min(1, 'validation.name_required'),
  type: z.enum(['internal', 'work_order', 'maintenance']).optional(),
  description: z.string().optional().or(z.literal('')),
  status: z.string().optional(),
  visibility: z.enum(['private', 'department', 'company']).optional(),
  department_id: z.string().min(1, 'validation.department_required'),
  site_id: z.string().min(1, 'validation.site_required'),
  client_id: z.string().optional().or(z.literal('')),
  contact_site_id: z.string().optional().or(z.literal('')),
  planned_start: z.string().optional().or(z.literal('')),
  planned_end: z.string().optional().or(z.literal('')),
})

type ProjectFormValues = z.infer<typeof projectSchema>

interface ProjectFormProps {
  open: boolean
  onClose: () => void
  editProject?: Project | null
  initialClientId?: string | null
  initialContactSiteId?: string | null
}

function normalizeSelectId(value: string | undefined): string | null {
  if (!value) return null
  const normalized = value.trim()
  if (!normalized || normalized.toLowerCase() === 'null') return null
  return normalized
}

function toDateInputValue(value: string | null | undefined): string {
  if (!value) return ''
  return value.split('T')[0]
}

function getSubmitErrorMessage(err: unknown): string {
  if (err instanceof Error) return err.message
  if (err && typeof err === 'object') {
    const maybe = err as { message?: string; details?: string; hint?: string }
    return maybe.message || maybe.details || maybe.hint || 'submit_failed'
  }
  return 'submit_failed'
}

export function ProjectForm({
  open,
  onClose,
  editProject,
  initialClientId,
  initialContactSiteId,
}: ProjectFormProps) {
  const { t } = useTranslation(['projects', 'field-service'])
  const { toast } = useToast()
  const navigate = useNavigate()
  const { activeTenant, sites } = useTenant()
  const isFieldService = useIsFieldService()
  const isEditing = !!editProject

  const { data: departments = [] } = useDepartments()
  const { data: contacts = [] } = useQuery({
    queryKey: ['contacts', 'select', 200],
    queryFn: () => getContacts({ limit: 200 }),
    enabled: open && isFieldService,
  })
  const createMutation = useCreateProject()
  const updateMutation = useUpdateProject()

  const {
    register,
    handleSubmit,
    reset,
    watch,
    setValue,
    setError,
    formState: { errors, isSubmitting },
  } = useForm<ProjectFormValues>({
    resolver: zodResolver(projectSchema),
    defaultValues: {
      name: '',
      type: 'internal',
      description: '',
      status: 'draft',
      visibility: 'company',
      department_id: '',
      site_id: '',
      client_id: '',
      contact_site_id: '',
      planned_start: '',
      planned_end: '',
    },
  })

  const selectedClientId = watch('client_id')
  const projectType = watch('type') ?? (isFieldService ? 'work_order' : 'internal')
  const showSiteSelect = sites.length > 1
  const showDepartmentSelect = departments.length > 1

  const { data: contactSites = [] } = useQuery({
    queryKey: ['contact_sites', selectedClientId],
    queryFn: () => getContactSites(selectedClientId!),
    enabled: open && !!selectedClientId,
  })

  useEffect(() => {
    if (!open) return
    if (editProject) {
      reset({
        name: editProject.name ?? '',
        type: editProject.type ?? (isFieldService ? 'work_order' : 'internal'),
        description: editProject.description ?? '',
        status: editProject.status ?? 'draft',
        visibility: editProject.visibility ?? 'company',
        department_id: editProject.department_id ?? '',
        site_id: editProject.site_id ?? '',
        client_id: editProject.client_id ?? '',
        contact_site_id: editProject.contact_site_id ?? '',
        planned_start: toDateInputValue(editProject.planned_start),
        planned_end: toDateInputValue(editProject.planned_end),
      })
    } else {
      reset({
        name: '',
        type: isFieldService ? 'work_order' : 'internal',
        description: '',
        status: 'draft',
        visibility: 'company',
        department_id: departments.length === 1 ? (departments[0]?.id ?? '') : '',
        site_id: sites.length === 1 ? (sites[0]?.id ?? '') : '',
        client_id: initialClientId ?? '',
        contact_site_id: initialContactSiteId ?? '',
        planned_start: '',
        planned_end: '',
      })
    }
  }, [open, editProject, reset, isFieldService, initialClientId, initialContactSiteId, departments, sites])

  useEffect(() => {
    if (!selectedClientId) {
      setValue('contact_site_id', '')
    }
  }, [selectedClientId, setValue])

  useEffect(() => {
    if (!open || editProject) return
    if (sites.length === 1 && sites[0]?.id) {
      setValue('site_id', sites[0].id)
    }
    if (departments.length === 1 && departments[0]?.id) {
      setValue('department_id', departments[0].id)
    }
  }, [open, editProject, sites, departments, setValue])

  async function onSubmit(values: ProjectFormValues) {
    if (!activeTenant?.id) {
      toast({
        variant: 'destructive',
        description: t('projects.errors.no_tenant', 'Selecciona una organització primer'),
      })
      return
    }

    try {
      const normalizedDepartmentId = normalizeSelectId(values.department_id)
      const normalizedSiteId = normalizeSelectId(values.site_id)
      const normalizedClientId = normalizeSelectId(values.client_id)
      const normalizedContactSiteId = normalizeSelectId(values.contact_site_id)

      const projectType = values.type ?? (isFieldService ? 'work_order' : 'internal')

      if (isFieldService && projectType === 'work_order') {
        if (!normalizedClientId) {
          setError('client_id', { type: 'manual', message: 'validation.client_required' })
          return
        }
        if (!normalizedContactSiteId) {
          setError('contact_site_id', {
            type: 'manual',
            message: 'validation.site_address_required',
          })
          return
        }
      }

      if (!normalizedSiteId || !normalizedDepartmentId) {
        if (!normalizedDepartmentId) {
          setError('department_id', {
            type: 'manual',
            message: 'validation.department_required',
          })
        }
        if (!normalizedSiteId) {
          setError('site_id', {
            type: 'manual',
            message: 'validation.site_required',
          })
        }
        return
      }

      if (isEditing) {
        await updateMutation.mutateAsync({
          id: editProject!.id!,
          params: {
            name: values.name,
            type: values.type ?? null,
            description: values.description || null,
            status: values.status ?? null,
            visibility: values.visibility ?? null,
            department_id: normalizedDepartmentId,
            site_id: normalizedSiteId,
            client_id: normalizedClientId,
            contact_site_id: normalizedContactSiteId,
            planned_start: values.planned_start || null,
            planned_end: values.planned_end || null,
          },
        })
        toast({ description: t('projects.toast.updated', 'Projecte actualitzat') })
        onClose()
      } else {
        const id = await createMutation.mutateAsync({
          p_tenant_id: activeTenant.id,
          p_name: values.name,
          p_type: values.type,
          p_description: values.description || undefined,
          p_status: values.status,
          p_visibility: values.visibility,
          p_department_id: normalizedDepartmentId ?? undefined,
          p_site_id: normalizedSiteId ?? undefined,
          p_client_id: normalizedClientId ?? undefined,
          p_contact_site_id: normalizedContactSiteId ?? undefined,
          p_planned_start: values.planned_start || undefined,
          p_planned_end: values.planned_end || undefined,
        })

        if (isFieldService && id) {
          try {
            const templates = await listPricingTemplates()
            const def =
              templates.find((x) => x.is_default) ??
              templates.find((x) => /visita\s*est[aà]ndard/i.test(x.name)) ??
              null
            if (def) {
              const items = await listPricingTemplateItems(def.id)
              const quantities: Record<string, number> = {}
              for (const item of items) {
                quantities[item.id] = Number(item.default_quantity ?? 1)
              }
              await applyPricingTemplate({
                projectId: id,
                templateId: def.id,
                quantities,
              })
            }
          } catch (applyErr) {
            console.warn('[ProjectForm] default pricing template apply failed', applyErr)
            toast({
              description: t(
                'projects.toast.template_apply_skipped',
                'Ordre creada; no s’ha pogut aplicar el servei habitual per defecte.',
              ),
            })
          }
        }

        toast({ description: t('projects.toast.created', 'Projecte creat') })
        onClose()
        navigate(isFieldService ? `/field/orders/${id}?tab=prepare` : `/projects/${id}`)
      }
    } catch (err) {
      const msg = getSubmitErrorMessage(err)
      console.error('[ProjectForm] Submit error:', msg)
      toast({
        variant: 'destructive',
        description: msg || (isEditing
          ? t('projects.errors.update_failed', 'Error en actualitzar el projecte')
          : t('projects.errors.create_failed', 'Error en crear el projecte')),
      })
    }
  }

  const title = isEditing
    ? (isFieldService
      ? t('field-service:orders.form_title_edit', 'Editar ordre')
      : t('projects.form.title_edit', 'Editar projecte'))
    : (isFieldService
      ? t('field-service:orders.form_title_create', 'Nova ordre')
      : t('projects.form.title_create', 'Nou projecte'))

  return (
    <Dialog open={open} onOpenChange={(v) => { if (!v) onClose() }}>
      <DialogContent className="sm:max-w-lg max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
        </DialogHeader>

        <form onSubmit={handleSubmit(onSubmit)} className="space-y-4 mt-2">
          <div className="space-y-1">
            <label className="text-sm font-medium" htmlFor="project-name">
              {t('projects.form.name', 'Nom')}
              <span className="text-destructive ml-1">*</span>
            </label>
            <Input
              id="project-name"
              placeholder={isFieldService
                ? t('field-service:orders.form_name_placeholder', "Nom de l'ordre")
                : t('projects.form.name_placeholder', 'Nom del projecte')}
              {...register('name')}
              aria-invalid={!!errors.name}
            />
            {errors.name && (
              <p className="text-xs text-destructive">{t('projects.errors.name_required', 'El nom és obligatori')}</p>
            )}
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-1">
              <label className="text-sm font-medium" htmlFor="project-type">
                {t('projects.form.type', 'Tipus')}
              </label>
              <select
                id="project-type"
                {...register('type')}
                className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
                aria-describedby="project-type-help"
              >
                <option value="internal">{t('projects.type.internal', 'Intern')}</option>
                <option value="work_order">{t('projects.type.work_order', 'Ordre de treball')}</option>
                <option value="maintenance">{t('projects.type.maintenance', 'Manteniment')}</option>
              </select>
            </div>
            <div className="space-y-1">
              <label className="text-sm font-medium" htmlFor="project-status">
                {t('projects.form.status', 'Estat')}
              </label>
              <select
                id="project-status"
                {...register('status')}
                className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
              >
                <option value="draft">{t('projects.status.draft', 'Esborrany')}</option>
                <option value="active">{t('projects.status.active', 'Actiu')}</option>
                <option value="in_progress">{t('projects.status.in_progress', 'En curs')}</option>
                <option value="on_hold">{t('projects.status.on_hold', 'En espera')}</option>
                <option value="completed">{t('projects.status.completed', 'Completat')}</option>
                <option value="cancelled">{t('projects.status.cancelled', 'Cancel·lat')}</option>
              </select>
            </div>
          </div>
          <p id="project-type-help" className="text-xs text-muted-foreground -mt-2">
            {projectType === 'work_order'
              ? (isFieldService
                ? t(
                  'field-service:orders.type_help_work_order',
                  'Servei o visita a un client. Requereix client i sol aparèixer a Avui / Agenda.',
                )
                : t(
                  'projects.type.work_order_help',
                  'Feina o servei orientat a un client (ordre de treball).',
                ))
              : projectType === 'maintenance'
                ? (isFieldService
                  ? t(
                    'field-service:orders.type_help_maintenance',
                    'Manteniment periòdic o preventiu (sovint generat per un pla). El client és opcional.',
                  )
                  : t(
                    'projects.type.maintenance_help',
                    'Manteniment periòdic o preventiu, sovint lligat a un pla.',
                  ))
                : (isFieldService
                  ? t(
                    'field-service:orders.type_help_internal',
                    'Feina interna del negoci (sense visita a client). No surt com a ordre de camp tipica.',
                  )
                  : t(
                    'projects.type.internal_help',
                    'Projecte o feina interna, sense client d’obra.',
                  ))}
          </p>

          {isFieldService && projectType !== 'internal' && (
            <div className="grid grid-cols-2 gap-4">
              <div className="space-y-1">
                <label className="text-sm font-medium" htmlFor="project-client">
                  {t('field-service:detail.client', 'Client')}
                  {projectType === 'work_order' && (
                    <span className="text-destructive ml-1">*</span>
                  )}
                  {projectType === 'maintenance' && (
                    <span className="text-muted-foreground font-normal ml-1 text-xs">
                      ({t('field-service:orders.client_optional', 'opcional')})
                    </span>
                  )}
                </label>
                <select
                  id="project-client"
                  {...register('client_id')}
                  className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
                >
                  <option value="">{t('projects.form.select_placeholder', 'Selecciona…')}</option>
                  {contacts.map((c) => (
                    <option key={c.id} value={c.id ?? ''}>{c.display_name}</option>
                  ))}
                </select>
                {errors.client_id && (
                  <p className="text-xs text-destructive">
                    {t('projects.errors.client_required', 'El client és obligatori')}
                  </p>
                )}
              </div>
              <div className="space-y-1">
                <label className="text-sm font-medium" htmlFor="project-contact-site">
                  {t('field-service:detail.address', 'Adreça')}
                  {projectType === 'work_order' && (
                    <span className="text-destructive ml-1">*</span>
                  )}
                  {projectType === 'maintenance' && (
                    <span className="text-muted-foreground font-normal ml-1 text-xs">
                      ({t('field-service:orders.client_optional', 'opcional')})
                    </span>
                  )}
                </label>
                <select
                  id="project-contact-site"
                  {...register('contact_site_id')}
                  disabled={!selectedClientId}
                  className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm disabled:opacity-50"
                >
                  <option value="">{t('projects.form.select_placeholder', 'Selecciona…')}</option>
                  {contactSites.map((s) => (
                    <option key={s.id} value={s.id ?? ''}>
                      {[s.name, s.address].filter(Boolean).join(' — ') || s.id}
                    </option>
                  ))}
                </select>
                {errors.contact_site_id && (
                  <p className="text-xs text-destructive">
                    {t('projects.errors.contact_site_required', 'L\'adreça d\'obra és obligatòria')}
                  </p>
                )}
              </div>
            </div>
          )}

          <div className="space-y-1">
            <label className="text-sm font-medium" htmlFor="project-visibility">
              {t('projects.form.visibility', 'Visibilitat')}
            </label>
            <select
              id="project-visibility"
              {...register('visibility')}
              className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
            >
              <option value="company">{t('projects.visibility.company', 'Empresa')}</option>
              <option value="department">{t('projects.visibility.department', 'Departament')}</option>
              <option value="private">{t('projects.visibility.private', 'Privat')}</option>
            </select>
          </div>

          <div className={cn('grid gap-4', showDepartmentSelect && showSiteSelect ? 'grid-cols-2' : showDepartmentSelect || showSiteSelect ? 'grid-cols-1 sm:grid-cols-2' : 'hidden')}>
            {showDepartmentSelect ? (
              <div className="space-y-1">
                <label className="text-sm font-medium" htmlFor="project-dept">
                  {t('projects.form.department', 'Departament')}
                  <span className="text-destructive ml-1">*</span>
                </label>
                <select
                  id="project-dept"
                  {...register('department_id')}
                  className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
                >
                  <option value="">{t('projects.form.select_placeholder', 'Selecciona…')}</option>
                  {departments.map((d) => (
                    <option key={d.id} value={d.id ?? ''}>{d.name}</option>
                  ))}
                </select>
                {errors.department_id && (
                  <p className="text-xs text-destructive">
                    {t('projects.errors.department_required', 'El departament és obligatori')}
                  </p>
                )}
              </div>
            ) : (
              <input type="hidden" {...register('department_id')} />
            )}
            {showSiteSelect ? (
              <div className="space-y-1">
                <label className="text-sm font-medium" htmlFor="project-site">
                  {t('projects.form.site', 'Local')}
                  <span className="text-destructive ml-1">*</span>
                </label>
                <select
                  id="project-site"
                  {...register('site_id')}
                  className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
                >
                  <option value="">{t('projects.form.select_placeholder', 'Selecciona…')}</option>
                  {sites.map((s) => (
                    <option key={s.id} value={s.id}>{s.name}</option>
                  ))}
                </select>
                {errors.site_id && (
                  <p className="text-xs text-destructive">
                    {t('projects.errors.site_required', 'El local és obligatori')}
                  </p>
                )}
              </div>
            ) : (
              <input type="hidden" {...register('site_id')} />
            )}
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-1">
              <label className="text-sm font-medium" htmlFor="project-start">
                {t('projects.form.planned_start', 'Inici previst')}
              </label>
              <Input id="project-start" type="date" {...register('planned_start')} />
            </div>
            <div className="space-y-1">
              <label className="text-sm font-medium" htmlFor="project-end">
                {t('projects.form.planned_end', 'Fi prevista')}
              </label>
              <Input id="project-end" type="date" {...register('planned_end')} />
            </div>
          </div>

          <div className="space-y-1">
            <label className="text-sm font-medium" htmlFor="project-desc">
              {t('projects.form.description', 'Descripció')}
            </label>
            <textarea
              id="project-desc"
              rows={3}
              placeholder={isFieldService
                ? t('field-service:orders.form_description_placeholder', "Descripció de l'ordre (opcional)")
                : t('projects.form.description_placeholder', 'Descripció del projecte (opcional)')}
              {...register('description')}
              className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm resize-none"
            />
          </div>

          <div className="flex justify-end gap-2 pt-2">
            <Button type="button" variant="outline" onClick={onClose}>
              {t('projects.form.cancel', 'Cancel·lar')}
            </Button>
            <Button type="submit" disabled={isSubmitting}>
              {isSubmitting
                ? t('projects.form.saving', 'Desant…')
                : t('projects.form.save', 'Desar')}
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  )
}
