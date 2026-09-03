import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Check, Copy, Loader2, Printer } from 'lucide-react'
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
import { generatePortalQrDataUrl } from '../utils/portalQrGenerate'
import { printPortalQrCard } from '../utils/portalQrPrint'

interface PortalPinResetRevealDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  resetUrl: string
  expiresAt: string
  employeeName?: string
}

function CopyField({ value, label }: { value: string; label: string }) {
  const [copied, setCopied] = useState(false)

  async function handleCopy() {
    await navigator.clipboard.writeText(value)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  return (
    <div className="space-y-1">
      <label className="text-sm font-medium">{label}</label>
      <div className="flex gap-2">
        <Input readOnly value={value} className="font-mono text-xs" />
        <Button type="button" variant="outline" size="icon" onClick={() => void handleCopy()} aria-label={label}>
          {copied ? <Check className="h-4 w-4 text-green-600" /> : <Copy className="h-4 w-4" />}
        </Button>
      </div>
    </div>
  )
}

function PortalQrImage({ url, size }: { url: string; size: number }) {
  const [dataUrl, setDataUrl] = useState<string | null>(null)
  const [failed, setFailed] = useState(false)

  useEffect(() => {
    let cancelled = false
    setDataUrl(null)
    setFailed(false)

    void generatePortalQrDataUrl(url, size)
      .then((result) => {
        if (!cancelled) setDataUrl(result)
      })
      .catch(() => {
        if (!cancelled) setFailed(true)
      })

    return () => {
      cancelled = true
    }
  }, [url, size])

  if (failed) {
    return (
      <div
        className="rounded border border-destructive/40 bg-destructive/5 text-destructive text-xs flex items-center justify-center p-2 text-center"
        style={{ width: size, height: size }}
      >
        QR
      </div>
    )
  }

  if (!dataUrl) {
    return (
      <div
        className="rounded bg-muted animate-pulse flex items-center justify-center"
        style={{ width: size, height: size }}
      >
        <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
      </div>
    )
  }

  return <img src={dataUrl} alt="" width={size} height={size} className="rounded" />
}

function formatExpiry(value: string): string {
  try {
    return new Date(value).toLocaleString()
  } catch {
    return value
  }
}

export function PortalPinResetRevealDialog({
  open,
  onOpenChange,
  resetUrl,
  expiresAt,
  employeeName,
}: PortalPinResetRevealDialogProps) {
  const { t } = useTranslation('employees')
  const [printing, setPrinting] = useState(false)

  async function handlePrint() {
    if (!resetUrl) return
    setPrinting(true)
    try {
      await printPortalQrCard({
        employeeName: employeeName?.trim() || t('employees.portal_access.print_unknown_name', 'Empleat'),
        portalUrl: resetUrl,
        scanHint: t(
          'employees.portal_access.pin_reset_print_hint',
          'Escaneja per triar un PIN nou. Vàlid 30 minuts.',
        ),
      })
    } finally {
      setPrinting(false)
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>
            {t('employees.portal_access.pin_reset_reveal_title', 'Enllaç de restabliment de PIN')}
          </DialogTitle>
          <DialogDescription>
            {t(
              'employees.portal_access.pin_reset_reveal_description',
              'Envia o imprimeix aquest enllaç. Només es pot usar una vegada i caduca en 30 minuts. No substitueix l\'enllaç d\'accés habitual.',
            )}
          </DialogDescription>
        </DialogHeader>

        <p className="text-sm text-amber-800 dark:text-amber-200 rounded-md border border-amber-500/40 bg-amber-50 dark:bg-amber-950/30 px-3 py-2">
          {t('employees.portal_access.pin_reset_expires_notice', 'Caduca: {{expires}}', {
            expires: formatExpiry(expiresAt),
          })}
        </p>

        <div className="space-y-4 py-2">
          <CopyField
            value={resetUrl}
            label={t('employees.portal_access.pin_reset_url_field', 'URL de restabliment')}
          />
          <div className="flex flex-col items-center gap-3 rounded-md border p-6">
            <PortalQrImage url={resetUrl} size={220} />
            <p className="text-sm text-center text-muted-foreground max-w-xs">
              {t(
                'employees.portal_access.pin_reset_qr_hint',
                'QR per restablir el PIN. L\'empleat haurà de tornar a entrar amb el seu enllaç d\'accés habitual.',
              )}
            </p>
          </div>
        </div>

        <DialogFooter className="flex-col sm:flex-row gap-2">
          <Button type="button" variant="outline" onClick={() => void handlePrint()} disabled={printing}>
            {printing ? <Loader2 className="h-4 w-4 mr-2 animate-spin" /> : <Printer className="h-4 w-4 mr-2" />}
            {t('employees.portal_access.print_qr', 'Imprimir QR')}
          </Button>
          <Button type="button" onClick={() => onOpenChange(false)}>
            {t('employees.portal_access.pin_reset_done', 'Entesos')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
