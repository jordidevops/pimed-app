import { useState } from 'react'
import { Link } from 'react-router-dom'
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
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { useToast } from '@/hooks/use-toast'
import { useImportApplicationsBulk } from '../api/useRecruitment'
import type { ApplicantImportRecord } from '../import/applicantImportTypes'
import { downloadCsvTemplate, csvRowsToImportRecords, parseCsv } from '../import/parseApplicantCsv'

interface Props {
  open: boolean
  onOpenChange: (open: boolean) => void
  jobPostingId: string
  legalBasis?: string | null
  legalBasisNote?: string | null
}

export function ImportApplicationsCsvDialog({
  open,
  onOpenChange,
  jobPostingId,
  legalBasis,
  legalBasisNote,
}: Props) {
  const { t } = useTranslation('recruitment')
  const { toast } = useToast()
  const importMutation = useImportApplicationsBulk(jobPostingId)

  const [records, setRecords] = useState<ApplicantImportRecord[]>([])
  const [parseErrors, setParseErrors] = useState<string[]>([])
  const [fileName, setFileName] = useState<string | null>(null)
  const [sourceLabel, setSourceLabel] = useState('')

  const basisBlocked =
    legalBasis === 'other' && !String(legalBasisNote ?? '').trim()

  function resetState() {
    setRecords([])
    setParseErrors([])
    setFileName(null)
    setSourceLabel('')
  }

  async function handleFile(file: File) {
    const text = await file.text()
    const rows = parseCsv(text)
    const { records: parsed, errors } = csvRowsToImportRecords(rows)
    setFileName(file.name)
    setRecords(parsed)
    setParseErrors(errors)
  }

  async function confirmImport() {
    if (records.length === 0 || basisBlocked) return
    try {
      const result = await importMutation.mutateAsync({
        jobPostingId,
        rows: records,
        importSourceLabel: sourceLabel.trim() || null,
      })
      toast({
        description: t('import.done', {
          created: result.created,
          skipped: result.skipped_duplicate,
          art14: result.art14_queued,
          errors: result.errors.length,
        }),
      })
      resetState()
      onOpenChange(false)
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('import.error'),
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
      <DialogContent className="max-w-2xl max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{t('import.title')}</DialogTitle>
          <DialogDescription>{t('import.description')}</DialogDescription>
        </DialogHeader>

        <div className="space-y-4">
          {basisBlocked ? (
            <p className="rounded-md border border-destructive/40 bg-destructive/5 p-3 text-sm">
              {t('import.legal_basis_blocked')}{' '}
              <Link to="/recruitment/settings?section=capture" className="underline">
                {t('import.open_settings')}
              </Link>
            </p>
          ) : (
            <p className="text-sm text-muted-foreground">
              {t('import.legal_basis_current', {
                basis: t(`settings.legal_basis_${legalBasis ?? 'legitimate_interest'}`),
              })}
            </p>
          )}

          <div className="space-y-2">
            <Label>{t('import.source_label')}</Label>
            <Input
              placeholder={t('import.source_label_placeholder')}
              value={sourceLabel}
              onChange={(e) => setSourceLabel(e.target.value)}
              maxLength={80}
            />
            <p className="text-xs text-muted-foreground">{t('import.source_label_hint')}</p>
          </div>

          <div className="flex flex-wrap gap-2 items-center">
            <Button type="button" variant="outline" className="gap-2" onClick={() => downloadCsvTemplate()}>
              <Download className="h-4 w-4" />
              {t('import.download_template')}
            </Button>
            <label className="inline-flex items-center gap-2 rounded-md border border-input bg-background px-3 py-2 text-sm cursor-pointer hover:bg-accent">
              <Upload className="h-4 w-4" />
              {t('import.choose_file')}
              <input
                type="file"
                accept=".csv,text/csv"
                className="hidden"
                onChange={(e) => {
                  const f = e.target.files?.[0]
                  if (f) void handleFile(f)
                  e.target.value = ''
                }}
              />
            </label>
            {fileName && <span className="text-sm text-muted-foreground">{fileName}</span>}
          </div>

          {parseErrors.length > 0 && (
            <ul className="text-sm text-destructive list-disc pl-5 max-h-32 overflow-y-auto">
              {parseErrors.map((e) => (
                <li key={e}>{e}</li>
              ))}
            </ul>
          )}

          {records.length > 0 && (
            <div className="rounded-md border p-3 text-sm space-y-1">
              <p>{t('import.preview_count', { count: records.length })}</p>
              <ul className="max-h-40 overflow-y-auto text-muted-foreground">
                {records.slice(0, 8).map((r) => (
                  <li key={r.email}>
                    {r.full_name} — {r.email}
                  </li>
                ))}
                {records.length > 8 && <li>…</li>}
              </ul>
            </div>
          )}
        </div>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
            {t('import.cancel')}
          </Button>
          <Button
            type="button"
            disabled={
              records.length === 0 || basisBlocked || importMutation.isPending
            }
            onClick={() => void confirmImport()}
          >
            {importMutation.isPending ? t('import.working') : t('import.confirm')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
