import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { AlertTriangle, Loader2 } from 'lucide-react'
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
import { useCreateEmployeePortalToken } from '../api/useEmployeePortalTokens'
import { normalizeEmployeePortalError } from '../api/employeePortalService'
import { ATTENDANCE_STATIONS_PLAN_URL } from '../constants/portalAccessDocs'
import { isValidPortalPin } from '../utils/portalCrypto'
import { hasEmployeeDocumentId } from '../utils/portalDocumentId'
import type { EmployeePortalToken } from '../api/employeePortalTypes'

function isActivePortalToken(token: EmployeePortalToken): boolean {
  return token.is_active && !token.revoked_at
}

interface CreatePortalTokenDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  employeeId: string
  employeeActive: boolean
  employeeDocumentId?: string | null
  onOpenProfileTab?: () => void
  existingTokens: EmployeePortalToken[]
  onCreated: (result: {
    tokenId: string
    secret: string
    supersededTokenId: string | null
    label: string
  }) => void
}

export function CreatePortalTokenDialog({
  open,
  onOpenChange,
  employeeId,
  employeeActive,
  employeeDocumentId,
  onOpenProfileTab,
  existingTokens,
  onCreated,
}: CreatePortalTokenDialogProps) {
  const { t } = useTranslation('employees')
  const { mutate, isPending } = useCreateEmployeePortalToken(employeeId)

  const [label, setLabel] = useState('WhatsApp')
  const [pinRequired, setPinRequired] = useState(true)
  const [legacyManagerPin, setLegacyManagerPin] = useState(false)
  const [pin, setPin] = useState('')
  const [expiresAt, setExpiresAt] = useState('')
  const [error, setError] = useState<string | null>(null)

  const hasDocumentId = hasEmployeeDocumentId(employeeDocumentId)

  const willSupersedeActive = existingTokens.some((token) => isActivePortalToken(token))

  useEffect(() => {
    if (!open) return
    setLabel('WhatsApp')
    setPinRequired(true)
    setLegacyManagerPin(false)
    setPin('')
    setExpiresAt('')
    setError(null)
  }, [open])

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!employeeActive || !hasDocumentId) return

    if (pinRequired && legacyManagerPin && !isValidPortalPin(pin)) {
      setError(t('employees.portal_access.pin_invalid', 'El PIN ha de tenir 4 a 6 dígits.'))
      return
    }

    mutate(
      {
        label: label.trim() || undefined,
        pin: pinRequired && legacyManagerPin ? pin : null,
        pinRequired,
        pinMustSet: pinRequired && !legacyManagerPin,
        expiresAt: expiresAt || null,
      },
      {
        onSuccess: (result) => {
          onOpenChange(false)
          onCreated({ ...result, label: label.trim() || 'WhatsApp' })
        },
        onError: (err) => {
          const code = normalizeEmployeePortalError(err)
          if (code === 'duplicate_active_label') {
            setError(
              t(
                'employees.portal_access.duplicate_label',
                'Ja existeix un enllaç permanent actiu amb aquesta etiqueta.',
              ),
            )
            return
          }
          if (code === 'employee_not_active') {
            setError(
              t(
                'employees.portal_access.employee_not_active',
                'Només es poden generar enllaços per empleats actius.',
              ),
            )
            return
          }
          if (code === 'employee_missing_document_id') {
            setError(
              t(
                'employees.portal_access.missing_document_id',
                'Afegeix el DNI/NIE a la fitxa de l\'empleat abans de generar l\'accés.',
              ),
            )
            return
          }
          setError(t('employees.portal_access.create_error', 'No s\'ha pogut generar l\'enllaç.'))
        },
      },
    )
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <form onSubmit={handleSubmit}>
          <DialogHeader>
            <DialogTitle>
              {t('employees.portal_access.create_title', 'Nou enllaç del portal')}
            </DialogTitle>
            <DialogDescription>
              {t(
                'employees.portal_access.create_description',
                'L\'URL només es mostrarà una vegada després de crear-lo.',
              )}
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-4 py-4">
            {!hasDocumentId && (
              <div className="flex gap-2 rounded-md border border-amber-500/50 bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950/30 dark:text-amber-100">
                <AlertTriangle className="h-4 w-4 shrink-0 mt-0.5" />
                <div className="space-y-2">
                  <p>
                    {t(
                      'employees.portal_access.missing_document_id',
                      'Afegeix el DNI/NIE a la fitxa de l\'empleat abans de generar l\'accés.',
                    )}
                  </p>
                  {onOpenProfileTab ? (
                    <Button type="button" variant="link" className="h-auto p-0 text-sm" onClick={onOpenProfileTab}>
                      {t('employees.portal_access.open_profile_tab', 'Anar a la fitxa de l\'empleat')}
                    </Button>
                  ) : null}
                </div>
              </div>
            )}

            <div className="space-y-1">
              <label className="text-sm font-medium">
                {t('employees.portal_access.label_field', 'Etiqueta')}
              </label>
              <Input
                value={label}
                onChange={(e) => setLabel(e.target.value)}
                placeholder={t('employees.portal_access.label_placeholder', 'WhatsApp, QR vestuari…')}
                disabled={isPending}
              />
            </div>

            <div className="flex items-start gap-2">
              <Checkbox
                id="portal-pin-required"
                checked={pinRequired}
                onCheckedChange={(v) => {
                  const enabled = v === true
                  setPinRequired(enabled)
                  if (!enabled) setLegacyManagerPin(false)
                }}
                disabled={isPending}
              />
              <div className="space-y-1">
                <label htmlFor="portal-pin-required" className="text-sm font-medium leading-none">
                  {t('employees.portal_access.pin_enabled', 'Requerir PIN de 4–6 dígits')}
                </label>
                <p className="text-xs text-muted-foreground">
                  {t(
                    'employees.portal_access.pin_enabled_hint',
                    'Recomanat: protegeix l\'accés si l\'URL es comparteix.',
                  )}
                </p>
              </div>
            </div>

            {!pinRequired && (
              <div className="flex gap-2 rounded-md border border-amber-500/50 bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950/30 dark:text-amber-100">
                <AlertTriangle className="h-4 w-4 shrink-0 mt-0.5" />
                <p>
                  {t(
                    'employees.portal_access.no_pin_warning',
                    'Sense PIN, qualsevol persona amb l\'URL podrà fitxar en nom d\'aquest empleat.',
                  )}
                </p>
              </div>
            )}

            {pinRequired && !legacyManagerPin && (
              <p className="text-muted-foreground rounded-md border px-3 py-2 text-sm">
                {t(
                  'employees.portal_access.pin_employee_setup_hint',
                  'L\'empleat definirà el seu propi PIN al primer accés. Tu no el veuràs.',
                )}
              </p>
            )}

            {pinRequired && (
              <div className="flex items-start gap-2">
                <Checkbox
                  id="portal-legacy-manager-pin"
                  checked={legacyManagerPin}
                  onCheckedChange={(v) => setLegacyManagerPin(v === true)}
                  disabled={isPending}
                />
                <div className="space-y-1">
                  <label htmlFor="portal-legacy-manager-pin" className="text-sm font-medium leading-none">
                    {t(
                      'employees.portal_access.legacy_manager_pin',
                      'Definir PIN jo (legacy)',
                    )}
                  </label>
                  <p className="text-xs text-muted-foreground">
                    {t(
                      'employees.portal_access.legacy_manager_pin_hint',
                      'Només per casos excepcionals. L\'empresa coneixerà el PIN.',
                    )}
                  </p>
                </div>
              </div>
            )}

            {pinRequired && legacyManagerPin && (
              <div className="space-y-1">
                <label className="text-sm font-medium">
                  {t('employees.portal_access.pin_field', 'PIN')}
                </label>
                <Input
                  type="password"
                  inputMode="numeric"
                  autoComplete="off"
                  maxLength={6}
                  value={pin}
                  onChange={(e) => setPin(e.target.value.replace(/\D/g, ''))}
                  disabled={isPending}
                />
              </div>
            )}

            <p className="text-xs text-muted-foreground rounded-md border px-3 py-2">
              {t(
                'employees.portal_access.stations_hint',
                'Per fitxar des d\'un dispositiu compartit al vestuari, usa una estació de fitxatge (/station) en lloc d\'un enllaç personal.',
              )}{' '}
              <a
                href={ATTENDANCE_STATIONS_PLAN_URL}
                target="_blank"
                rel="noopener noreferrer"
                className="text-primary hover:underline"
              >
                {t(
                  'employees.portal_access.stations_plan_link_label',
                  'Pla d\'estacions de fitxatge',
                )}
              </a>
            </p>

            <div className="space-y-1">
              <label className="text-sm font-medium">
                {t('employees.portal_access.expires_at', 'Caducitat (opcional)')}
              </label>
              <Input
                type="date"
                value={expiresAt}
                onChange={(e) => setExpiresAt(e.target.value)}
                disabled={isPending}
              />
            </div>

            {willSupersedeActive && (
              <div className="flex gap-2 rounded-md border border-amber-500/50 bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950/30 dark:text-amber-100">
                <AlertTriangle className="h-4 w-4 shrink-0 mt-0.5" />
                <p>
                  {t(
                    'employees.portal_access.supersede_warning_personal',
                    'Ja hi ha un enllaç personal actiu. En crear-ne un de nou, l\'anterior quedarà revocat.',
                  )}
                </p>
              </div>
            )}

            {error && <p className="text-sm text-destructive">{error}</p>}
          </div>

          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)} disabled={isPending}>
              {t('employees.form.cancel', 'Cancel·lar')}
            </Button>
            <Button type="submit" disabled={isPending || !employeeActive || !hasDocumentId}>
              {isPending && <Loader2 className="h-4 w-4 mr-2 animate-spin" />}
              {t('employees.portal_access.create_submit', 'Generar enllaç')}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}
