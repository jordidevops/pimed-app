import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Download, Upload } from 'lucide-react'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { downloadCsvTemplate, csvRowsToImportRecords, parseCsv } from '../import/parseEmployeeCsv'
import { useImportEmployeesBulk } from '../import/useEmployeeImport'
import type { EmployeeImportRecord, ImportEmployeesBulkResult } from '../import/employeeImportTypes'

interface EmployeeImportCsvDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function EmployeeImportCsvDialog({ open, onOpenChange }: EmployeeImportCsvDialogProps) {
  const { t } = useTranslation('employees')
  const { toast } = useToast()
  const { sites, selectedSiteId } = useTenant()
  const importMutation = useImportEmployeesBulk()

  const [records, setRecords] = useState<EmployeeImportRecord[]>([])
  const [parseErrors, setParseErrors] = useState<string[]>([])
  const [preview, setPreview] = useState<ImportEmployeesBulkResult | null>(null)
  const [fileName, setFileName] = useState<string | null>(null)
  const [defaultSiteId, setDefaultSiteId] = useState(selectedSiteId ?? '')

  const actionLabel = useMemo(
    () => ({
      create: t('employees.import.action_create', 'Crear'),
      update: t('employees.import.action_update', 'Actualitzar'),
      needs_review: t('employees.import.action_needs_review', 'Revisió'),
      error: t('employees.import.action_error', 'Error'),
    }),
    [t],
  )

  function domainPrivateLabel(v: unknown) {
    if (v === true || v === 'applied' || v === 'true') {
      return t('employees.import.domain_private_yes', 'Privat: sí')
    }
    if (v === 'no_permission') {
      return t('employees.import.domain_private_no_perm', 'Privat: sense permís')
    }
    return t('employees.import.domain_private_no', 'Privat: —')
  }

  function domainContractLabel(v: unknown) {
    if (v === 'needs_review') {
      return t('employees.import.domain_contract_review', 'Contracte: revisió')
    }
    if (v === 'no_conflict') {
      return t('employees.import.domain_contract_ok', 'Contracte: ok')
    }
    return t('employees.import.domain_contract_deferred', 'Contracte: EC (diferit)')
  }

  function resetState() {
    setRecords([])
    setParseErrors([])
    setPreview(null)
    setFileName(null)
  }

  async function handleFile(file: File) {
    const text = await file.text()
    const rows = parseCsv(text)
    const { records: parsed, errors } = csvRowsToImportRecords(rows)
    setFileName(file.name)
    setRecords(parsed)
    setParseErrors(errors)
    setPreview(null)

    if (parsed.length === 0) return

    try {
      const result = await importMutation.mutateAsync({
        rows: parsed,
        options: {
          dry_run: true,
          default_site_id: defaultSiteId || null,
          default_provider: 'csv',
        },
      })
      setPreview(result)
    } catch {
      toast({
        title: t('employees.import.preview_failed', 'No s\'ha pogut previsualitzar'),
        variant: 'destructive',
      })
    }
  }

  async function confirmImport() {
    if (records.length === 0) return
    try {
      const result = await importMutation.mutateAsync({
        rows: records,
        options: {
          dry_run: false,
          default_site_id: defaultSiteId || null,
          default_provider: 'csv',
        },
      })
      toast({
        title: t('employees.import.done_title', 'Importació completada'),
        description: t('employees.import.done_desc', '{{created}} creats, {{updated}} actualitzats, {{skipped}} omesos', {
          created: result.created,
          updated: result.updated,
          skipped: result.skipped,
        }),
      })
      resetState()
      onOpenChange(false)
    } catch {
      toast({
        title: t('employees.import.failed', 'Error en importar'),
        variant: 'destructive',
      })
    }
  }

  return (
    <Dialog
      open={open}
      onOpenChange={(v) => {
        if (!v) resetState()
        onOpenChange(v)
      }}
    >
      <DialogContent className="max-w-3xl max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{t('employees.import.title', 'Importar empleats (CSV)')}</DialogTitle>
          <DialogDescription>
            {t(
              'employees.import.description',
              'Puja un CSV (persona/directori). Match: mapping → codi → NIF → email. Contractes i connectors (Holded/PayFit) queden fora d’aquest flux.',
            )}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4">
          <div className="flex flex-wrap gap-2 items-center">
            <Button type="button" variant="outline" className="gap-2" onClick={() => downloadCsvTemplate()}>
              <Download className="h-4 w-4" />
              {t('employees.import.download_template', 'Descarregar plantilla')}
            </Button>
            <label className="inline-flex items-center gap-2 rounded-md border border-input bg-background px-3 py-2 text-sm cursor-pointer hover:bg-accent">
              <Upload className="h-4 w-4" />
              {t('employees.import.choose_file', 'Triar fitxer')}
              <input
                type="file"
                accept=".csv,text/csv"
                className="sr-only"
                onChange={(e) => {
                  const f = e.target.files?.[0]
                  if (f) void handleFile(f)
                  e.target.value = ''
                }}
              />
            </label>
          </div>

          {sites.length > 0 ? (
            <div className="space-y-1">
              <label className="text-sm font-medium">
                {t('employees.import.default_site', 'Local per defecte (nous empleats)')}
              </label>
              <select
                value={defaultSiteId}
                onChange={(e) => setDefaultSiteId(e.target.value)}
                className="w-full max-w-sm rounded-md border border-input bg-background px-3 py-2 text-sm"
              >
                <option value="">{t('employees.form.no_site_assigned', '(Sense local assignat)')}</option>
                {sites.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.name}
                  </option>
                ))}
              </select>
            </div>
          ) : null}

          {fileName ? (
            <p className="text-sm text-muted-foreground">
              {t('employees.import.file_loaded', 'Fitxer: {{name}} ({{count}} files)', {
                name: fileName,
                count: records.length,
              })}
            </p>
          ) : null}

          {parseErrors.length > 0 ? (
            <ul className="text-sm text-destructive list-disc pl-5">
              {parseErrors.map((err) => (
                <li key={err}>{err}</li>
              ))}
            </ul>
          ) : null}

          {preview ? (
            <div className="space-y-2">
              <p className="text-sm font-medium">
                {t(
                  'employees.import.preview_summary',
                  'Previsualització: {{created}} crear, {{updated}} actualitzar, {{review}} revisió, {{skipped}} errors',
                  {
                    created: preview.created,
                    updated: preview.updated,
                    review: preview.needs_review ?? 0,
                    skipped: preview.skipped,
                  },
                )}
              </p>
              <p className="text-xs text-muted-foreground">
                {t(
                  'employees.import.domains_hint',
                  'Dominis: empleat (directori) · perfil privat (si tens permís) · contracte (delegat EC; conflictes firmats → revisió).',
                )}
              </p>
              <div className="rounded-md border border-border overflow-x-auto max-h-64">
                <table className="w-full text-sm">
                  <thead className="bg-muted/50 sticky top-0">
                    <tr>
                      <th className="text-left p-2">#</th>
                      <th className="text-left p-2">{t('employees.import.col_action', 'Acció')}</th>
                      <th className="text-left p-2">{t('employees.form.full_name_label', 'Nom')}</th>
                      <th className="text-left p-2">{t('employees.import.col_match', 'Match')}</th>
                      <th className="text-left p-2">{t('employees.import.col_domains', 'Dominis')}</th>
                    </tr>
                  </thead>
                  <tbody>
                    {preview.results.map((r) => (
                      <tr key={`${r.row}-${r.action}`} className="border-t border-border">
                        <td className="p-2">{r.row}</td>
                        <td className="p-2">
                          {actionLabel[r.action as keyof typeof actionLabel] ?? r.action}
                          {r.code ? ` (${r.code})` : ''}
                        </td>
                        <td className="p-2">{r.full_name ?? '—'}</td>
                        <td className="p-2 text-muted-foreground">{r.matched_by ?? '—'}</td>
                        <td className="p-2 text-xs text-muted-foreground">
                          {r.domains
                            ? [
                                r.domains.employee
                                  ? t('employees.import.domain_employee', 'Empleat')
                                  : null,
                                domainPrivateLabel(r.domains.private),
                                domainContractLabel(r.domains.contract),
                              ]
                                .filter(Boolean)
                                .join(' · ')
                            : '—'}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          ) : null}
        </div>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
            {t('employees.form.cancel', 'Cancel·lar')}
          </Button>
          <Button
            type="button"
            disabled={!preview || records.length === 0 || importMutation.isPending}
            onClick={() => void confirmImport()}
          >
            {importMutation.isPending
              ? t('employees.import.importing', 'Important…')
              : t('employees.import.confirm', 'Confirmar importació')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
