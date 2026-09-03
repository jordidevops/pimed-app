import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  BuildingIcon,
  CopyIcon,
  Loader2,
  PencilIcon,
  PlusIcon,
  Trash2Icon,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Checkbox } from '@/components/ui/checkbox'
import { Label } from '@/components/ui/label'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import {
  PAYROLL_AGGREGATE_SOURCE_FIELDS,
  PAYROLL_DAILY_SOURCE_FIELDS,
  type PayrollExportColumnMapping,
  type PayrollExportProfile,
  type PayrollExportProfileMapping,
} from '../../api/payrollConnectorTypes'
import {
  useCreatePayrollExportProfileTemplate,
  useDeletePayrollExportProfile,
  usePayrollExportProfiles,
  useUpsertPayrollExportProfile,
} from '../../api/usePayrollExportProfiles'

const CONNECTOR_LABELS: Record<string, string> = {
  a3_variables: 'A3',
  sage_concepts: 'Sage',
  csv_custom: 'CSV',
}

function emptyMapping(): PayrollExportProfileMapping {
  return { columns: [], concepts: [], header_row: 1, csv_delimiter: ';' }
}

function ProfileEditDialog({
  open,
  onOpenChange,
  profile,
  tenantId,
  canManage,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  profile: PayrollExportProfile | null
  tenantId: string
  canManage: boolean
}) {
  const { t } = useTranslation('settings')
  const { toast } = useToast()
  const upsert = useUpsertPayrollExportProfile(tenantId)

  const [name, setName] = useState(profile?.name ?? '')
  const [connector, setConnector] = useState<PayrollExportProfile['connector']>(
    profile?.connector ?? 'csv_custom',
  )
  const [sourceMode, setSourceMode] = useState<PayrollExportProfile['source_mode']>(
    profile?.source_mode ?? 'aggregate',
  )
  const [delimiter, setDelimiter] = useState(profile?.mapping.csv_delimiter ?? ';')
  const [columns, setColumns] = useState<PayrollExportColumnMapping[]>(
    profile?.mapping.columns ?? [],
  )
  const [isActive, setIsActive] = useState(profile?.is_active ?? true)

  const profileKey = profile?.id ?? 'new'

  useEffect(() => {
    if (!open) return
    setName(profile?.name ?? '')
    setConnector(profile?.connector ?? 'csv_custom')
    setSourceMode(profile?.source_mode ?? 'aggregate')
    setDelimiter(profile?.mapping.csv_delimiter ?? ';')
    setColumns(profile?.mapping.columns ?? [])
    setIsActive(profile?.is_active ?? true)
  }, [open, profileKey, profile])

  function handleOpenChange(next: boolean) {
    onOpenChange(next)
  }

  const sourceFields =
    sourceMode === 'aggregate' ? PAYROLL_AGGREGATE_SOURCE_FIELDS : PAYROLL_DAILY_SOURCE_FIELDS

  function addColumn() {
    setColumns((prev) => [...prev, { header: '', source: sourceFields[0] }])
  }

  function updateColumn(index: number, patch: Partial<PayrollExportColumnMapping>) {
    setColumns((prev) => prev.map((col, i) => (i === index ? { ...col, ...patch } : col)))
  }

  function removeColumn(index: number) {
    setColumns((prev) => prev.filter((_, i) => i !== index))
  }

  async function save() {
    if (!name.trim()) return
    try {
      await upsert.mutateAsync({
        id: profile?.id,
        name: name.trim(),
        connector,
        source_mode: sourceMode,
        output_format: 'csv',
        is_active: isActive,
        mapping: {
          ...(profile?.mapping ?? emptyMapping()),
          columns,
          csv_delimiter: delimiter || ';',
          header_row: profile?.mapping.header_row ?? 1,
        },
      })
      toast({ title: t('payroll_export_profiles.saved', 'Perfil desat') })
      onOpenChange(false)
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('payroll_export_profiles.error', 'Error en desar el perfil'),
        description: err instanceof Error ? err.message : String(err),
      })
    }
  }

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogContent className="max-w-2xl max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {profile
              ? t('payroll_export_profiles.edit_title', 'Editar perfil')
              : t('payroll_export_profiles.new_title', 'Nou perfil')}
          </DialogTitle>
          <DialogDescription>
            {t(
              'payroll_export_profiles.edit_desc',
              'Defineix les columnes del fitxer destí (A3, Sage o CSV personalitzat).',
            )}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4 py-2">
          <div className="space-y-1.5">
            <Label htmlFor="profile-name">{t('payroll_export_profiles.name', 'Nom')}</Label>
            <input
              id="profile-name"
              value={name}
              disabled={!canManage}
              onChange={(e) => setName(e.target.value)}
              className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
            />
          </div>

          <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
            <div className="space-y-1.5">
              <Label>{t('payroll_export_profiles.connector', 'Connector')}</Label>
              <select
                value={connector}
                disabled={!canManage}
                onChange={(e) =>
                  setConnector(e.target.value as PayrollExportProfile['connector'])
                }
                className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
              >
                <option value="a3_variables">A3</option>
                <option value="sage_concepts">Sage</option>
                <option value="csv_custom">CSV custom</option>
              </select>
            </div>
            <div className="space-y-1.5">
              <Label>{t('payroll_export_profiles.source_mode', 'Mode dades')}</Label>
              <select
                value={sourceMode}
                disabled={!canManage}
                onChange={(e) =>
                  setSourceMode(e.target.value as PayrollExportProfile['source_mode'])
                }
                className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
              >
                <option value="daily">
                  {t('payroll_export_profiles.mode_daily', 'Diari')}
                </option>
                <option value="aggregate">
                  {t('payroll_export_profiles.mode_aggregate', 'Agregat mensual')}
                </option>
              </select>
            </div>
            <div className="space-y-1.5">
              <Label>{t('payroll_export_profiles.delimiter', 'Separador CSV')}</Label>
              <input
                value={delimiter}
                disabled={!canManage}
                maxLength={1}
                onChange={(e) => setDelimiter(e.target.value || ';')}
                className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
              />
            </div>
          </div>

          <div className="flex items-center gap-2">
            <Checkbox
              id="profile-active"
              checked={isActive}
              disabled={!canManage}
              onCheckedChange={(v) => setIsActive(v === true)}
            />
            <Label htmlFor="profile-active" className="font-normal">
              {t('payroll_export_profiles.active', 'Actiu')}
            </Label>
          </div>

          <div className="space-y-2">
            <div className="flex items-center justify-between">
              <Label>{t('payroll_export_profiles.columns', 'Columnes')}</Label>
              {canManage ? (
                <Button type="button" variant="outline" size="sm" onClick={addColumn}>
                  <PlusIcon className="mr-1 h-3.5 w-3.5" />
                  {t('payroll_export_profiles.add_column', 'Afegir')}
                </Button>
              ) : null}
            </div>

            {columns.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                {t('payroll_export_profiles.no_columns', 'Cap columna definida.')}
              </p>
            ) : (
              <div className="space-y-2">
                {columns.map((col, index) => (
                  <div
                    key={index}
                    className="grid grid-cols-1 gap-2 rounded-lg border p-3 sm:grid-cols-[1fr_1fr_1fr_auto]"
                  >
                    <input
                      placeholder={t('payroll_export_profiles.col_header', 'Capçalera')}
                      value={col.header}
                      disabled={!canManage}
                      onChange={(e) => updateColumn(index, { header: e.target.value })}
                      className="flex h-9 rounded-md border border-input bg-background px-2 text-sm"
                    />
                    <select
                      value={col.source ?? ''}
                      disabled={!canManage || !!col.concept_key}
                      onChange={(e) =>
                        updateColumn(index, {
                          source: e.target.value as PayrollExportColumnMapping['source'],
                          concept_key: undefined,
                        })
                      }
                      className="flex h-9 rounded-md border border-input bg-background px-2 text-sm"
                    >
                      <option value="">
                        {t('payroll_export_profiles.col_concept', 'Concepte')}
                      </option>
                      {sourceFields.map((f) => (
                        <option key={f} value={f}>
                          {f}
                        </option>
                      ))}
                    </select>
                    <input
                      placeholder={t('payroll_export_profiles.concept_key', 'concept_key')}
                      value={col.concept_key ?? ''}
                      disabled={!canManage || !!col.source}
                      onChange={(e) =>
                        updateColumn(index, {
                          concept_key: e.target.value || undefined,
                          source: undefined,
                        })
                      }
                      className="flex h-9 rounded-md border border-input bg-background px-2 text-sm"
                    />
                    {canManage ? (
                      <Button
                        type="button"
                        variant="ghost"
                        size="icon"
                        onClick={() => removeColumn(index)}
                      >
                        <Trash2Icon className="h-4 w-4" />
                      </Button>
                    ) : null}
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
            {t('payroll_export_profiles.cancel', 'Cancel·lar')}
          </Button>
          {canManage ? (
            <Button type="button" disabled={upsert.isPending} onClick={() => void save()}>
              {upsert.isPending ? <Loader2 className="mr-2 h-4 w-4 animate-spin" /> : null}
              {t('save', 'Desar')}
            </Button>
          ) : null}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

interface AttendancePayrollExportProfilesSectionProps {
  canManage: boolean
}

export function AttendancePayrollExportProfilesSection({
  canManage,
}: AttendancePayrollExportProfilesSectionProps) {
  const { t } = useTranslation('settings')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const tenantId = activeTenant?.id ?? null

  const { data: profiles = [], isLoading } = usePayrollExportProfiles(tenantId)
  const createTemplate = useCreatePayrollExportProfileTemplate(tenantId)
  const deleteProfile = useDeletePayrollExportProfile(tenantId)

  const [editProfile, setEditProfile] = useState<PayrollExportProfile | null>(null)
  const [dialogOpen, setDialogOpen] = useState(false)
  const [deleteTarget, setDeleteTarget] = useState<PayrollExportProfile | null>(null)

  function openNew() {
    setEditProfile(null)
    setDialogOpen(true)
  }

  function openEdit(profile: PayrollExportProfile) {
    setEditProfile(profile)
    setDialogOpen(true)
  }

  async function duplicateTemplate(template: 'a3' | 'sage') {
    try {
      await createTemplate.mutateAsync(template)
      toast({
        title: t('payroll_export_profiles.template_added', 'Plantilla afegida'),
      })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('payroll_export_profiles.error', 'Error en desar el perfil'),
        description: err instanceof Error ? err.message : String(err),
      })
    }
  }

  async function confirmRemoveProfile() {
    if (!deleteTarget) return
    try {
      await deleteProfile.mutateAsync(deleteTarget.id)
      toast({ title: t('payroll_export_profiles.deleted', 'Perfil eliminat') })
      setDeleteTarget(null)
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('payroll_export_profiles.error', 'Error en desar el perfil'),
        description: err instanceof Error ? err.message : String(err),
      })
    }
  }

  return (
    <section className="rounded-2xl border bg-card p-6 space-y-5">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div className="space-y-0.5">
          <div className="flex items-center gap-2">
            <h2 className="text-base font-semibold text-foreground">
              {t('payroll_export_profiles.title', 'Export nòmina (perfils)')}
            </h2>
            <span className="inline-flex items-center gap-1 rounded-full bg-muted text-muted-foreground text-xs font-medium px-2 py-0.5">
              <BuildingIcon className="h-3 w-3" />
              Tenant
            </span>
          </div>
          <p className="text-sm text-muted-foreground">
            {t(
              'payroll_export_profiles.description',
              'Perfils CSV per A3, Sage o formats personalitzats. Es trien a l’export de nòmina.',
            )}
          </p>
        </div>

        {canManage ? (
          <div className="flex flex-wrap gap-2">
            <Button
              type="button"
              variant="outline"
              size="sm"
              disabled={createTemplate.isPending}
              onClick={() => void duplicateTemplate('a3')}
            >
              <CopyIcon className="mr-1.5 h-3.5 w-3.5" />
              {t('payroll_export_profiles.add_a3', 'Plantilla A3')}
            </Button>
            <Button
              type="button"
              variant="outline"
              size="sm"
              disabled={createTemplate.isPending}
              onClick={() => void duplicateTemplate('sage')}
            >
              <CopyIcon className="mr-1.5 h-3.5 w-3.5" />
              {t('payroll_export_profiles.add_sage', 'Plantilla Sage')}
            </Button>
            <Button type="button" size="sm" onClick={openNew}>
              <PlusIcon className="mr-1.5 h-3.5 w-3.5" />
              {t('payroll_export_profiles.new', 'Nou perfil')}
            </Button>
          </div>
        ) : null}
      </div>

      {isLoading ? (
        <div className="h-20 animate-pulse rounded-lg bg-muted" />
      ) : profiles.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t(
            'payroll_export_profiles.empty',
            'Cap perfil configurat. Afegeix una plantilla A3 o Sage per començar.',
          )}
        </p>
      ) : (
        <ul className="divide-y rounded-lg border">
          {profiles.map((profile) => (
            <li
              key={profile.id}
              className="flex flex-col gap-2 p-4 sm:flex-row sm:items-center sm:justify-between"
            >
              <div className="space-y-1">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-medium text-sm">{profile.name}</span>
                  <Badge variant="secondary">{CONNECTOR_LABELS[profile.connector] ?? profile.connector}</Badge>
                  <Badge variant="outline">
                    {profile.source_mode === 'aggregate'
                      ? t('payroll_export_profiles.mode_aggregate', 'Agregat mensual')
                      : t('payroll_export_profiles.mode_daily', 'Diari')}
                  </Badge>
                  {!profile.is_active ? (
                    <Badge variant="destructive">
                      {t('payroll_export_profiles.inactive', 'Inactiu')}
                    </Badge>
                  ) : null}
                </div>
                <p className="text-xs text-muted-foreground">
                  {t('payroll_export_profiles.column_count', {
                    count: profile.mapping.columns?.length ?? 0,
                    defaultValue: '{{count}} columnes',
                  })}
                </p>
              </div>
              {canManage ? (
                <div className="flex gap-2">
                  <Button type="button" variant="outline" size="sm" onClick={() => openEdit(profile)}>
                    <PencilIcon className="mr-1 h-3.5 w-3.5" />
                    {t('payroll_export_profiles.edit', 'Editar')}
                  </Button>
                  <Button
                    type="button"
                    variant="ghost"
                    size="sm"
                    onClick={() => setDeleteTarget(profile)}
                  >
                    <Trash2Icon className="h-3.5 w-3.5" />
                  </Button>
                </div>
              ) : null}
            </li>
          ))}
        </ul>
      )}

      {tenantId ? (
        <ProfileEditDialog
          open={dialogOpen}
          onOpenChange={setDialogOpen}
          profile={editProfile}
          tenantId={tenantId}
          canManage={canManage}
        />
      ) : null}

      <Dialog
        open={deleteTarget !== null}
        onOpenChange={(open) => {
          if (!open) setDeleteTarget(null)
        }}
      >
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>
              {t('payroll_export_profiles.confirm_delete_title', 'Eliminar perfil')}
            </DialogTitle>
            <DialogDescription>
              {t(
                'payroll_export_profiles.confirm_delete_desc',
                'Vols eliminar el perfil «{{name}}»? Aquesta acció no es pot desfer.',
                { name: deleteTarget?.name ?? '' },
              )}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter className="gap-2 sm:gap-0">
            <Button type="button" variant="outline" onClick={() => setDeleteTarget(null)}>
              {t('payroll_export_profiles.cancel', 'Cancel·lar')}
            </Button>
            <Button
              type="button"
              variant="destructive"
              disabled={deleteProfile.isPending}
              onClick={() => void confirmRemoveProfile()}
            >
              {deleteProfile.isPending ? (
                <Loader2 className="mr-2 h-4 w-4 animate-spin" />
              ) : null}
              {t('payroll_export_profiles.confirm_delete_action', 'Eliminar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </section>
  )
}
