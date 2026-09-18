import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { usePriceSheetTitle } from '@/hooks/useSectorLabel'
import { createQuoteWaiver } from '../api/commercialFlowService'
import { priceSheetRpcErrorCopy, priceSheetRpcErrorTitle } from '../utils/rpcError'

const DEFAULT_WAIVER_TEXT_CA =
  'Renuncio a l’elaboració del pressupost previ i autorizo a realitzar els treballs necessaris per al servei sol·licitat, conforme a la descripció indicada.'

interface QuoteWaiverDialogProps {
  projectId: string
  open: boolean
  onClose: () => void
  onSaved: () => void
}

export function QuoteWaiverDialog({
  projectId,
  open,
  onClose,
  onSaved,
}: QuoteWaiverDialogProps) {
  const { t } = useTranslation('projects')
  const { toast } = useToast()
  const priceSheetTitle = usePriceSheetTitle()
  const [workDescription, setWorkDescription] = useState('')
  const [signerName, setSignerName] = useState('')
  const [accepted, setAccepted] = useState(false)
  const [submitting, setSubmitting] = useState(false)

  if (!open) return null

  async function handleSave() {
    if (!accepted || !workDescription.trim() || !signerName.trim()) {
      toast({
        variant: 'destructive',
        title: t(
          'projects.commercial.waiver_incomplete',
          'Cal descripció, nom i acceptació de la renúncia',
        ),
      })
      return
    }
    setSubmitting(true)
    try {
      await createQuoteWaiver({
        projectId,
        workDescription: workDescription.trim(),
        legalText: DEFAULT_WAIVER_TEXT_CA,
        signature: {
          method: 'staff_ui',
          signer_name: signerName.trim(),
          accepted: true,
          signed_at: new Date().toISOString(),
        },
      })
      toast({
        title: t('projects.commercial.waiver_saved', 'Renúncia registrada'),
      })
      setWorkDescription('')
      setSignerName('')
      setAccepted(false)
      onSaved()
      onClose()
    } catch (err) {
      const copy = priceSheetRpcErrorCopy(err, priceSheetTitle)
      toast({
        variant: 'destructive',
        title: priceSheetRpcErrorTitle(t, copy),
        description: t(copy.descriptionKey, copy.descriptionFallback),
      })
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-end sm:items-center justify-center bg-black/40 p-0 sm:p-4">
      <div className="w-full max-w-lg rounded-t-2xl sm:rounded-xl border border-border bg-background p-4 sm:p-6 shadow-lg max-h-[90vh] overflow-y-auto space-y-4">
        <div>
          <h3 className="text-lg font-semibold text-foreground">
            {t('projects.commercial.work_without_quote', 'Treballar sense pressupost')}
          </h3>
          <p className="text-sm text-muted-foreground mt-1">
            {t(
              'projects.commercial.waiver_help',
              'Per a urgències: el client renuncia al pressupost i autoritza la feina descrita.',
            )}
          </p>
        </div>

        <div className="rounded-lg border border-border bg-muted/30 p-3 text-sm text-foreground">
          {DEFAULT_WAIVER_TEXT_CA}
        </div>

        <div>
          <label className="text-sm font-medium block mb-1.5">
            {t('projects.commercial.waiver_work', 'Descripció de la feina autoritzada')}
            <span className="text-destructive ml-1">*</span>
          </label>
          <textarea
            rows={3}
            value={workDescription}
            onChange={(e) => setWorkDescription(e.target.value)}
            className="w-full rounded-md border border-border bg-background px-3 py-2 text-sm"
          />
        </div>

        <div>
          <label className="text-sm font-medium block mb-1.5">
            {t('projects.commercial.waiver_signer', 'Nom de qui signa')}
            <span className="text-destructive ml-1">*</span>
          </label>
          <Input value={signerName} onChange={(e) => setSignerName(e.target.value)} />
        </div>

        <label className="flex items-start gap-2 text-sm">
          <input
            type="checkbox"
            className="mt-1"
            checked={accepted}
            onChange={(e) => setAccepted(e.target.checked)}
          />
          <span>
            {t(
              'projects.commercial.waiver_accept',
              'Confirmo que el client ha llegit i accepta la renúncia.',
            )}
          </span>
        </label>

        <div className="flex justify-end gap-2">
          <Button type="button" variant="outline" onClick={onClose} disabled={submitting}>
            {t('projects.lines.form.cancel', 'Cancel·lar')}
          </Button>
          <Button type="button" onClick={() => void handleSave()} disabled={submitting}>
            {t('projects.commercial.waiver_save', 'Registrar renúncia')}
          </Button>
        </div>
      </div>
    </div>
  )
}
