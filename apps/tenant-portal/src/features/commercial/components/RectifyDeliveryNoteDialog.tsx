import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import {
  previewRectifyDeliveryNote,
  rectifyCommercialDelivery,
  type RectifyDeliveryPreview,
  type RectifyLinePatch,
} from '../api/commercialFlowService'
import { commercialErrorMessage } from '../utils/commercialErrorMessage'
import { centsToEuros } from '../utils/paymentReceipt'

const moneyFmt = new Intl.NumberFormat('ca-ES', {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
})

type Props = {
  documentId: string | null
  open: boolean
  busy?: boolean
  onClose: () => void
  onCompleted: () => void
  onBusyChange?: (busy: boolean) => void
}

export function RectifyDeliveryNoteDialog({
  documentId,
  open,
  busy = false,
  onClose,
  onCompleted,
  onBusyChange,
}: Props) {
  const { t } = useTranslation(['projects', 'common'])
  const { toast } = useToast()
  const [reason, setReason] = useState('')
  const [preview, setPreview] = useState<RectifyDeliveryPreview | null>(null)
  const [osDraft, setOsDraft] = useState<Record<string, string>>({})
  const [loadingPreview, setLoadingPreview] = useState(false)
  const [localBusy, setLocalBusy] = useState(false)

  const submitting = busy || localBusy

  useEffect(() => {
    if (!open || !documentId) {
      setReason('')
      setPreview(null)
      setOsDraft({})
      return
    }
    let cancelled = false
    setLoadingPreview(true)
    void previewRectifyDeliveryNote({ documentId })
      .then((data) => {
        if (cancelled) return
        setPreview(data)
        const draft: Record<string, string> = {}
        for (const line of data.lines) {
          draft[line.project_line_id] = String(line.os_quantity)
        }
        setOsDraft(draft)
      })
      .catch((err: unknown) => {
        if (cancelled) return
        toast({
          variant: 'destructive',
          title: t('projects.commercial.error', 'Error comercial'),
          description: commercialErrorMessage(err),
        })
        onClose()
      })
      .finally(() => {
        if (!cancelled) setLoadingPreview(false)
      })
    return () => {
      cancelled = true
    }
  }, [open, documentId, onClose, t, toast])

  function buildPatches(): RectifyLinePatch[] {
    if (!preview) return []
    const patches: RectifyLinePatch[] = []
    for (const line of preview.lines) {
      const raw = osDraft[line.project_line_id]
      const qty = Number(String(raw ?? '').replace(',', '.'))
      if (!Number.isFinite(qty)) continue
      if (qty === line.os_quantity) continue
      patches.push({ project_line_id: line.project_line_id, quantity: qty })
    }
    return patches
  }

  async function refreshPreview(patches: RectifyLinePatch[]) {
    if (!documentId) return
    setLoadingPreview(true)
    try {
      const data = await previewRectifyDeliveryNote({ documentId, linePatches: patches })
      setPreview(data)
    } catch (err: unknown) {
      toast({
        variant: 'destructive',
        title: t('projects.commercial.error', 'Error comercial'),
        description: commercialErrorMessage(err),
      })
    } finally {
      setLoadingPreview(false)
    }
  }

  async function submit() {
    if (!documentId || reason.trim().length === 0) return
    const patches = buildPatches()
    setLocalBusy(true)
    onBusyChange?.(true)
    try {
      await rectifyCommercialDelivery({
        documentId,
        reason: reason.trim(),
        linePatches: patches,
      })
      onCompleted()
      onClose()
    } catch (err: unknown) {
      toast({
        variant: 'destructive',
        title: t('projects.commercial.error', 'Error comercial'),
        description: commercialErrorMessage(err),
      })
    } finally {
      setLocalBusy(false)
      onBusyChange?.(false)
    }
  }

  return (
    <Dialog open={open} onOpenChange={(next) => !submitting && !next && onClose()}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle>{t('projects.commercial.rectify_title', 'Rectificar aquest albarà?')}</DialogTitle>
          <DialogDescription>
            {t(
              'projects.commercial.rectify_help',
              'S’anul·la i se n’emet un de nou. Pots baixar la quantitat de l’ordre (mínim = ja entregat en altres albarans). Els cobraments es queden a l’original i compten al substitut.',
            )}
          </DialogDescription>
        </DialogHeader>

        {loadingPreview && !preview ? (
          <p className="text-sm text-muted-foreground">{t('projects.quotes.loading', 'Carregant…')}</p>
        ) : null}

        {preview ? (
          <div className="space-y-3">
            <ul className="max-h-56 space-y-2 overflow-y-auto rounded-lg border border-border p-2">
              {preview.lines.map((line) => (
                <li key={line.project_line_id} className="grid gap-1 text-sm">
                  <div className="flex items-center justify-between gap-2">
                    <span className="font-medium">{line.name}</span>
                    <span className="tabular-nums text-muted-foreground">
                      {moneyFmt.format(line.line_total)} €
                    </span>
                  </div>
                  <div className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
                    <label className="flex items-center gap-1">
                      {t('projects.commercial.rectify_os_qty', 'Quantitat OS')}
                      <Input
                        className="h-8 w-20"
                        inputMode="decimal"
                        disabled={submitting}
                        value={osDraft[line.project_line_id] ?? String(line.os_quantity)}
                        onChange={(event) =>
                          setOsDraft((current) => ({
                            ...current,
                            [line.project_line_id]: event.target.value,
                          }))
                        }
                        onBlur={() => void refreshPreview(buildPatches())}
                      />
                    </label>
                    <span>
                      {t('projects.commercial.rectify_new_qty', 'Albarà nou')}: {line.quantity}
                    </span>
                    <span>
                      {t('projects.commercial.rectify_min_qty', 'Mín.')}: {line.min_os_quantity}
                    </span>
                  </div>
                </li>
              ))}
            </ul>
            <p className="text-sm">
              {t('projects.commercial.rectify_preview_total', 'Total previst')}:{' '}
              <span className="font-semibold tabular-nums">
                {moneyFmt.format(centsToEuros(preview.total_cents))} €
              </span>
              {preview.inherited_paid_cents > 0 ? (
                <span className="text-muted-foreground">
                  {' '}
                  · {t('projects.commercial.rectify_inherited', 'Heretat')}{' '}
                  {moneyFmt.format(centsToEuros(preview.inherited_paid_cents))} €
                </span>
              ) : null}
            </p>
            {preview.payments_exceed_total ? (
              <p className="text-sm text-destructive">
                {t(
                  'projects.commercial.rectify_payments_exceed',
                  'Els cobraments heretats superen el total nou.',
                )}
              </p>
            ) : null}
          </div>
        ) : null}

        <Input
          value={reason}
          disabled={submitting}
          onChange={(event) => setReason(event.target.value)}
          placeholder={t('projects.commercial.rectify_reason', 'Motiu')}
        />
        <DialogFooter>
          <Button type="button" variant="outline" disabled={submitting} onClick={onClose}>
            {t('common.cancel', 'Cancel·lar')}
          </Button>
          <Button
            type="button"
            disabled={
              submitting ||
              loadingPreview ||
              reason.trim().length === 0 ||
              !preview ||
              preview.payments_exceed_total ||
              !preview.lines.some((line) => line.quantity > 0)
            }
            onClick={() => void submit()}
          >
            {t('projects.commercial.rectify', 'Rectificar')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
