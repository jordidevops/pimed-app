import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { BuildingIcon, BookOpen, LockIcon, PlusIcon, SaveIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useAbsenceTypeConfigs } from '../../api/useAbsences'
import {
  useCreateAbsenceTypeSubtype,
  useSaveAbsenceTypeExportSettings,
} from '../../api/useAbsenceTypeExportSettings'
import { absenceTypeLabel } from '../absences/absenceUiUtils'
import type { AbsenceParentKey, AbsenceTypeConfig } from '../../api/shiftsService'

const ABSENCE_EXPORT_HELP_URL =
  'https://github.com/jordidevops/pimed-app/blob/main/docs/help/horaris/tipus-absencia-export-nomina.md'

const PARENT_ORDER: AbsenceParentKey[] = [
  'vacation',
  'personal',
  'family',
  'permission',
  'it',
  'compensation',
  'other',
]

const PARENT_I18N: Record<AbsenceParentKey, string> = {
  vacation: 'Vacances',
  personal: 'Assumptes personals',
  family: 'Família',
  permission: 'Permisos',
  it: 'IT / Baixa',
  compensation: 'Compensació',
  other: 'Altres',
}

function groupByParent(configs: AbsenceTypeConfig[]): Map<AbsenceParentKey, AbsenceTypeConfig[]> {
  const map = new Map<AbsenceParentKey, AbsenceTypeConfig[]>()
  for (const cfg of configs) {
    const key = (cfg.parent_key ?? 'other') as AbsenceParentKey
    const list = map.get(key) ?? []
    list.push(cfg)
    map.set(key, list)
  }
  for (const [, list] of map) {
    list.sort((a, b) => a.sort_order - b.sort_order || a.absence_type.localeCompare(b.absence_type))
  }
  return map
}

interface AttendanceAbsenceTypesSettingsSectionProps {
  canManage: boolean
}

export function AttendanceAbsenceTypesSettingsSection({
  canManage,
}: AttendanceAbsenceTypesSettingsSectionProps) {
  const { t, i18n } = useTranslation('settings')
  const lang = i18n.language?.slice(0, 2) ?? 'ca'
  const { data: configs = [], isLoading } = useAbsenceTypeConfigs(true, true)
  const saveExport = useSaveAbsenceTypeExportSettings()
  const createSubtype = useCreateAbsenceTypeSubtype()

  const grouped = useMemo(() => groupByParent(configs), [configs])
  const [draftCodes, setDraftCodes] = useState<Record<string, string>>({})
  const [subtypeOpen, setSubtypeOpen] = useState(false)
  const [subtypeParent, setSubtypeParent] = useState<AbsenceParentKey>('permission')
  const [subtypeKey, setSubtypeKey] = useState('')
  const [subtypeAbsenceType, setSubtypeAbsenceType] = useState('')
  const [subtypeName, setSubtypeName] = useState('')
  const [subtypeExportCode, setSubtypeExportCode] = useState('')

  function codeFor(cfg: AbsenceTypeConfig): string {
    return draftCodes[cfg.absence_type] ?? cfg.export_code ?? ''
  }

  function setCode(absenceType: string, value: string) {
    setDraftCodes((prev) => ({ ...prev, [absenceType]: value }))
  }

  async function saveRow(cfg: AbsenceTypeConfig) {
    const exportCode = codeFor(cfg).trim()
    if (!exportCode) return
    await saveExport.mutateAsync({
      absence_type: cfg.absence_type,
      export_code: exportCode,
      parent_key: cfg.parent_key,
      subtype_key: cfg.subtype_key,
    })
    setDraftCodes((prev) => {
      const next = { ...prev }
      delete next[cfg.absence_type]
      return next
    })
  }

  async function handleCreateSubtype() {
    const absenceType = subtypeAbsenceType.trim().toLowerCase().replace(/\s+/g, '_')
    if (!absenceType || !subtypeKey.trim() || !subtypeName.trim() || !subtypeExportCode.trim()) return
    await createSubtype.mutateAsync({
      absence_type: absenceType,
      parent_key: subtypeParent,
      subtype_key: subtypeKey.trim(),
      name_i18n: { ca: subtypeName.trim(), es: subtypeName.trim() },
      export_code: subtypeExportCode.trim(),
    })
    setSubtypeOpen(false)
    setSubtypeKey('')
    setSubtypeAbsenceType('')
    setSubtypeName('')
    setSubtypeExportCode('')
  }

  return (
    <section className="rounded-2xl border bg-card p-6 space-y-5">
      <div className="flex items-start justify-between gap-4">
        <div className="space-y-0.5">
          <div className="flex items-center gap-2">
            <h2 className="text-base font-semibold text-foreground">
              {t('config.absence_types.title', 'Tipus d’absència i codis export')}
            </h2>
            <span className="inline-flex items-center gap-1 rounded-full bg-muted text-muted-foreground text-xs font-medium px-2 py-0.5">
              <BuildingIcon className="h-3 w-3" />
              Tenant
            </span>
          </div>
          <p className="text-sm text-muted-foreground">
            {t(
              'config.absence_types.description',
              'Taxonomia en dos nivells (família + subtipus) i codi per exportar a CSV, A3 o Sage.',
            )}
          </p>
          <a
            href={ABSENCE_EXPORT_HELP_URL}
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex items-center gap-1 text-xs text-primary hover:underline mt-1"
          >
            <BookOpen className="h-3.5 w-3.5" aria-hidden />
            {t('config.absence_types.help_link', 'Documentació: codis d’export i nòmina')}
          </a>
        </div>
        {!canManage && <LockIcon className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" />}
      </div>

      {!canManage && (
        <p className="text-sm text-muted-foreground italic">
          {t('config.read_only', 'Només els gestors i propietaris poden modificar la configuració.')}
        </p>
      )}

      {canManage && (
        <div className="flex justify-end">
          <Button type="button" variant="outline" size="sm" onClick={() => setSubtypeOpen(true)}>
            <PlusIcon className="h-4 w-4 mr-1.5" />
            {t('config.absence_types.add_subtype', 'Afegir subtipus')}
          </Button>
        </div>
      )}

      {isLoading ? (
        <div className="h-24 rounded-lg bg-muted animate-pulse" />
      ) : (
        <div className="space-y-6">
          {PARENT_ORDER.filter((pk) => grouped.has(pk)).map((parentKey) => {
            const items = grouped.get(parentKey) ?? []
            return (
              <div key={parentKey} className="space-y-2">
                <h3 className="text-sm font-medium text-foreground">
                  {t(`config.absence_types.parent.${parentKey}`, PARENT_I18N[parentKey])}
                </h3>
                <div className="rounded-lg border overflow-hidden">
                  <table className="w-full text-sm">
                    <thead className="bg-muted/50 text-muted-foreground">
                      <tr>
                        <th className="text-left font-medium px-3 py-2">
                          {t('config.absence_types.col_type', 'Tipus')}
                        </th>
                        <th className="text-left font-medium px-3 py-2 hidden sm:table-cell">
                          {t('config.absence_types.col_subtype', 'Subtipus')}
                        </th>
                        <th className="text-left font-medium px-3 py-2 w-28">
                          {t('config.absence_types.col_export', 'Codi export')}
                        </th>
                        {canManage && <th className="w-20" />}
                      </tr>
                    </thead>
                    <tbody>
                      {items.map((cfg) => {
                        const dirty =
                          draftCodes[cfg.absence_type] !== undefined &&
                          draftCodes[cfg.absence_type] !== (cfg.export_code ?? '')
                        return (
                          <tr key={cfg.absence_type} className="border-t">
                            <td className="px-3 py-2">
                              <div className="flex items-center gap-2">
                                <span>{absenceTypeLabel(cfg, cfg.absence_type, lang)}</span>
                                {cfg.is_system && (
                                  <Badge variant="secondary" className="text-[10px] px-1.5 py-0">
                                    {t('config.absence_types.system', 'Sistema')}
                                  </Badge>
                                )}
                              </div>
                              <p className="text-xs text-muted-foreground font-mono">{cfg.absence_type}</p>
                            </td>
                            <td className="px-3 py-2 hidden sm:table-cell text-muted-foreground font-mono text-xs">
                              {cfg.subtype_key ?? '—'}
                            </td>
                            <td className="px-3 py-2">
                              <Input
                                value={codeFor(cfg)}
                                onChange={(e) => setCode(cfg.absence_type, e.target.value.toUpperCase())}
                                disabled={!canManage}
                                className="h-8 font-mono text-xs uppercase max-w-[7rem]"
                                maxLength={12}
                                placeholder="VA"
                              />
                            </td>
                            {canManage && (
                              <td className="px-2 py-2 text-right">
                                <Button
                                  type="button"
                                  variant="ghost"
                                  size="icon"
                                  className="h-8 w-8"
                                  disabled={!dirty || saveExport.isPending}
                                  onClick={() => saveRow(cfg)}
                                  title={t('config.absence_types.save_row', 'Desar codi')}
                                >
                                  <SaveIcon className="h-4 w-4" />
                                </Button>
                              </td>
                            )}
                          </tr>
                        )
                      })}
                    </tbody>
                  </table>
                </div>
              </div>
            )
          })}
        </div>
      )}

      <Dialog open={subtypeOpen} onOpenChange={setSubtypeOpen}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>{t('config.absence_types.add_subtype', 'Afegir subtipus')}</DialogTitle>
            <DialogDescription>
              {t(
                'config.absence_types.add_subtype_desc',
                'Crea un tipus d’absència propi del tenant sota una família existent.',
              )}
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-3 py-2">
            <div className="space-y-1.5">
              <Label>{t('config.absence_types.field_parent', 'Família')}</Label>
              <select
                value={subtypeParent}
                onChange={(e) => setSubtypeParent(e.target.value as AbsenceParentKey)}
                className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
              >
                {PARENT_ORDER.map((pk) => (
                  <option key={pk} value={pk}>
                    {t(`config.absence_types.parent.${pk}`, PARENT_I18N[pk])}
                  </option>
                ))}
              </select>
            </div>
            <div className="space-y-1.5">
              <Label>{t('config.absence_types.field_name', 'Nom visible')}</Label>
              <Input value={subtypeName} onChange={(e) => setSubtypeName(e.target.value)} />
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1.5">
                <Label>{t('config.absence_types.field_subtype_key', 'Clau subtipus')}</Label>
                <Input
                  value={subtypeKey}
                  onChange={(e) => setSubtypeKey(e.target.value)}
                  placeholder="custom_leave"
                />
              </div>
              <div className="space-y-1.5">
                <Label>{t('config.absence_types.field_absence_type', 'Clau interna')}</Label>
                <Input
                  value={subtypeAbsenceType}
                  onChange={(e) => setSubtypeAbsenceType(e.target.value)}
                  placeholder="custom_leave"
                />
              </div>
            </div>
            <div className="space-y-1.5">
              <Label>{t('config.absence_types.col_export', 'Codi export')}</Label>
              <Input
                value={subtypeExportCode}
                onChange={(e) => setSubtypeExportCode(e.target.value.toUpperCase())}
                className="font-mono uppercase"
                maxLength={12}
              />
            </div>
          </div>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => setSubtypeOpen(false)}>
              {t('common.cancel', 'Cancel·lar')}
            </Button>
            <Button
              type="button"
              onClick={handleCreateSubtype}
              disabled={createSubtype.isPending}
            >
              {t('config.absence_types.create', 'Crear')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </section>
  )
}
