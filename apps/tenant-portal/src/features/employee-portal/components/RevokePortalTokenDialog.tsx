import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Loader2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import { Input } from '@/components/ui/input'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useRevokeEmployeePortalToken } from '../api/useEmployeePortalTokens'
import type { EmployeePortalToken } from '../api/employeePortalTypes'

interface RevokePortalTokenDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  employeeId: string
  token: EmployeePortalToken | null
}

export function RevokePortalTokenDialog({
  open,
  onOpenChange,
  employeeId,
  token,
}: RevokePortalTokenDialogProps) {
  const { t } = useTranslation('employees')
  const { mutate, isPending } = useRevokeEmployeePortalToken(employeeId)
  const [reason, setReason] = useState('')
  const [compromised, setCompromised] = useState(false)

  useEffect(() => {
    if (!open) return
    setReason('')
    setCompromised(false)
  }, [open, token?.id])

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!token?.id) return
    mutate(
      { tokenId: token.id, reason, compromised },
      { onSuccess: () => onOpenChange(false) },
    )
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <form onSubmit={handleSubmit}>
          <DialogHeader>
            <DialogTitle>
              {t('employees.portal_access.revoke_title', 'Revocar enllaç')}
            </DialogTitle>
            <DialogDescription>
              {token?.label
                ? t('employees.portal_access.revoke_description_label', 'Etiqueta: {{label}}', {
                    label: token.label,
                  })
                : t('employees.portal_access.revoke_description', 'L\'empleat no podrà renovar la sessió.')}
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-4 py-4">
            <div className="space-y-1">
              <label className="text-sm font-medium">
                {t('employees.portal_access.revoke_reason', 'Motiu (opcional)')}
              </label>
              <Input
                value={reason}
                onChange={(e) => setReason(e.target.value)}
                disabled={isPending}
              />
            </div>

            <div className="flex items-start gap-2">
              <Checkbox
                id="portal-compromised"
                checked={compromised}
                onCheckedChange={(v) => setCompromised(v === true)}
                disabled={isPending}
              />
              <div className="space-y-1">
                <label htmlFor="portal-compromised" className="text-sm font-medium leading-none">
                  {t('employees.portal_access.compromised', 'Token compromès / robat')}
                </label>
                <p className="text-xs text-muted-foreground">
                  {t(
                    'employees.portal_access.compromised_hint',
                    'Invalida qualsevol sessió al següent refresh (emergència).',
                  )}
                </p>
              </div>
            </div>
          </div>

          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)} disabled={isPending}>
              {t('employees.form.cancel', 'Cancel·lar')}
            </Button>
            <Button type="submit" variant="destructive" disabled={isPending || !token}>
              {isPending && <Loader2 className="h-4 w-4 mr-2 animate-spin" />}
              {t('employees.portal_access.revoke_submit', 'Revocar')}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}
