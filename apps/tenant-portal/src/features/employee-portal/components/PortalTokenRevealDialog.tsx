import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Check, Copy, Download, Loader2, Mail, Printer } from 'lucide-react'
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
import { PortalSendAccessEmailDialog } from './PortalSendAccessEmailDialog'
import { generatePortalQrDataUrl } from '../utils/portalQrGenerate'
import { downloadPortalLabelCsv } from '../utils/portalLabelExport'
import { printPortalQrCard } from '../utils/portalQrPrint'

interface PortalTokenRevealDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  bootstrapUrl: string
  employeeName?: string
  employeeCode?: string | null
  tokenLabel?: string | null
  supersededPreviousLink?: boolean
  urlUnavailable?: boolean
  tenantId?: string
  employeeId?: string
  tokenId?: string
  secret?: string
  employeeEmail?: string | null
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

export function PortalTokenRevealDialog({
  open,
  onOpenChange,
  bootstrapUrl,
  employeeName,
  employeeCode,
  tokenLabel,
  supersededPreviousLink = false,
  urlUnavailable = false,
  tenantId,
  employeeId,
  tokenId,
  secret,
  employeeEmail,
}: PortalTokenRevealDialogProps) {
  const { t } = useTranslation('employees')
  const [emailOpen, setEmailOpen] = useState(false)
  const [emailSent, setEmailSent] = useState(false)
  const [printing, setPrinting] = useState(false)

  const canSendEmail = Boolean(
    tenantId && employeeId && tokenId && secret && bootstrapUrl && !urlUnavailable,
  )
  const canExportOrPrint = Boolean(bootstrapUrl && !urlUnavailable)

  async function handlePrint() {
    if (!bootstrapUrl) return
    setPrinting(true)
    try {
      await printPortalQrCard({
        employeeName: employeeName?.trim() || t('employees.portal_access.print_unknown_name', 'Empleat'),
        portalUrl: bootstrapUrl,
        scanHint: t('employees.portal_access.print_scan_hint', 'Escaneja per accedir al portal.'),
      })
    } finally {
      setPrinting(false)
    }
  }

  function handleExportCsv() {
    if (!bootstrapUrl) return
    downloadPortalLabelCsv([
      {
        employeeName: employeeName?.trim() || '',
        employeeCode: employeeCode?.trim() || '',
        portalUrl: bootstrapUrl,
        label: tokenLabel?.trim() || '',
      },
    ])
  }

  return (
    <>
      <Dialog open={open} onOpenChange={onOpenChange}>
        <DialogContent className="sm:max-w-lg">
          <DialogHeader>
            <DialogTitle>
              {t('employees.portal_access.reveal_title', 'Enllaç generat')}
            </DialogTitle>
            <DialogDescription>
              {t(
                'employees.portal_access.reveal_description_prod',
                'Copia l\'URL ara i envia-la a l\'empleat. No es tornarà a mostrar.',
              )}
            </DialogDescription>
          </DialogHeader>

          {supersededPreviousLink ? (
            <p className="text-sm text-amber-800 dark:text-amber-200 rounded-md border border-amber-500/40 bg-amber-50 dark:bg-amber-950/30 px-3 py-2">
              {t(
                'employees.portal_access.superseded_notice',
                'S\'ha revocat l\'enllaç anterior del mateix tipus.',
              )}
            </p>
          ) : null}

          {urlUnavailable ? (
            <p className="text-sm text-destructive rounded-md border border-destructive/40 bg-destructive/5 px-3 py-2">
              {t(
                'employees.portal_access.url_unavailable',
                'No s\'ha pogut generar l\'enllaç d\'accés. Comprova que l\'empresa tingui una adreça web publicada.',
              )}
            </p>
          ) : null}

          <div className="space-y-4 py-2">
            {bootstrapUrl ? (
              <CopyField
                label={t('employees.portal_access.url_field', 'URL del portal')}
                value={bootstrapUrl}
              />
            ) : null}
            {bootstrapUrl ? (
              <div className="flex flex-col items-center gap-2 rounded-md border p-4">
                <PortalQrImage url={bootstrapUrl} size={160} />
                <p className="text-xs text-muted-foreground text-center">
                  {t('employees.portal_access.qr_hint', 'QR per imprimir o enviar per WhatsApp')}
                </p>
              </div>
            ) : null}
          </div>

          {emailSent ? (
            <p className="text-sm text-emerald-700 dark:text-emerald-400 rounded-md border border-emerald-500/40 bg-emerald-50 dark:bg-emerald-950/20 px-3 py-2">
              {t('employees.portal_access.email_sent_notice', 'Correu enviat correctament.')}
            </p>
          ) : null}

          <DialogFooter className="flex-col sm:flex-row gap-2 sm:flex-wrap">
            {canExportOrPrint ? (
              <div className="flex flex-wrap gap-2 sm:mr-auto">
                <Button
                  type="button"
                  variant="outline"
                  onClick={() => void handlePrint()}
                  disabled={printing}
                >
                  {printing ? (
                    <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                  ) : (
                    <Printer className="h-4 w-4 mr-2" />
                  )}
                  {t('employees.portal_access.print_qr', 'Imprimir QR')}
                </Button>
                <Button type="button" variant="outline" onClick={handleExportCsv}>
                  <Download className="h-4 w-4 mr-2" />
                  {t('employees.portal_access.export_csv', 'Exportar CSV')}
                </Button>
              </div>
            ) : null}
            {canSendEmail ? (
              <Button type="button" variant="outline" onClick={() => setEmailOpen(true)}>
                <Mail className="h-4 w-4 mr-2" />
                {t('employees.portal_access.email_send', 'Enviar correu')}
              </Button>
            ) : null}
            <Button type="button" onClick={() => onOpenChange(false)}>
              {t('employees.portal_access.reveal_done', 'Entesos, ja l\'he copiat')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {canSendEmail ? (
        <PortalSendAccessEmailDialog
          open={emailOpen}
          onOpenChange={setEmailOpen}
          tenantId={tenantId!}
          employeeId={employeeId!}
          tokenId={tokenId!}
          secret={secret!}
          defaultRecipient={employeeEmail}
          onSent={() => setEmailSent(true)}
        />
      ) : null}
    </>
  )
}
