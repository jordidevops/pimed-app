import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Loader2, Mail } from 'lucide-react'
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
import { sendEmployeePortalAccessEmail } from '../api/employeePortalService'

interface PortalSendAccessEmailDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  tenantId: string
  employeeId: string
  tokenId: string
  secret: string
  defaultRecipient?: string | null
  onSent?: (recipient: string) => void
}

function isValidEmail(value: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value.trim())
}

export function PortalSendAccessEmailDialog({
  open,
  onOpenChange,
  tenantId,
  employeeId,
  tokenId,
  secret,
  defaultRecipient,
  onSent,
}: PortalSendAccessEmailDialogProps) {
  const { t } = useTranslation('employees')
  const [recipient, setRecipient] = useState('')
  const [confirmOverride, setConfirmOverride] = useState(false)
  const [sending, setSending] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const normalizedDefault = defaultRecipient?.trim().toLowerCase() ?? ''
  const normalizedRecipient = recipient.trim().toLowerCase()
  const recipientOverride = Boolean(
    normalizedDefault && normalizedRecipient && normalizedRecipient !== normalizedDefault,
  )

  useEffect(() => {
    if (!open) return
    setRecipient(defaultRecipient?.trim() ?? '')
    setConfirmOverride(false)
    setSending(false)
    setError(null)
  }, [open, defaultRecipient])

  async function handleSend() {
    if (!isValidEmail(recipient)) {
      setError(t('employees.portal_access.email_invalid', 'Introdueix un correu vàlid.'))
      return
    }
    if (recipientOverride && !confirmOverride) {
      setError(
        t(
          'employees.portal_access.email_override_required',
          'Confirma que vols enviar a un correu diferent del de l\'empleat.',
        ),
      )
      return
    }

    setSending(true)
    setError(null)
    try {
      const result = await sendEmployeePortalAccessEmail({
        tenantId,
        employeeId,
        tokenId,
        secret,
        recipient: recipient.trim(),
      })
      onSent?.(result.recipient)
      onOpenChange(false)
    } catch (err) {
      setError(
        err instanceof Error
          ? err.message
          : t('employees.portal_access.email_send_error', 'No s\'ha pogut enviar el correu.'),
      )
    } finally {
      setSending(false)
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>
            {t('employees.portal_access.email_title', 'Enviar accés per correu')}
          </DialogTitle>
          <DialogDescription>
            {t(
              'employees.portal_access.email_description',
              'S\'enviarà l\'enllaç i el QR al correu indicat. L\'URL no es tornarà a mostrar després.',
            )}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-3 py-2">
          <div className="space-y-1">
            <label className="text-sm font-medium" htmlFor="portal-email-recipient">
              {t('employees.portal_access.email_recipient', 'Destinatari')}
            </label>
            <Input
              id="portal-email-recipient"
              type="email"
              value={recipient}
              onChange={(e) => setRecipient(e.target.value)}
              placeholder={t('employees.portal_access.email_recipient_placeholder', 'empleat@empresa.com')}
              disabled={sending}
            />
          </div>

          {recipientOverride ? (
            <label className="flex items-start gap-2 text-sm rounded-md border border-amber-500/40 bg-amber-50 dark:bg-amber-950/20 px-3 py-2">
              <input
                type="checkbox"
                className="mt-1"
                checked={confirmOverride}
                onChange={(e) => setConfirmOverride(e.target.checked)}
                disabled={sending}
              />
              <span>
                {t(
                  'employees.portal_access.email_override_confirm',
                  'Confirmo enviar a un correu diferent del registrat a l\'empleat ({{email}}).',
                  { email: normalizedDefault },
                )}
              </span>
            </label>
          ) : null}

          {error ? <p className="text-sm text-destructive">{error}</p> : null}
        </div>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)} disabled={sending}>
            {t('employees.portal_access.email_cancel', 'Cancel·lar')}
          </Button>
          <Button type="button" onClick={() => void handleSend()} disabled={sending}>
            {sending ? (
              <Loader2 className="h-4 w-4 mr-2 animate-spin" />
            ) : (
              <Mail className="h-4 w-4 mr-2" />
            )}
            {t('employees.portal_access.email_send', 'Enviar correu')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
