import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useQueries } from '@tanstack/react-query'
import { AlertTriangle, Link2, Loader2 } from 'lucide-react'
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
import {
  createBatchIdempotencyKey,
  getStoredBatchIdempotencyKey,
  normalizePortalTokenBatchError,
} from '../api/employeePortalBatchService'
import { useRunEmployeePortalBatch } from '../api/useEmployeePortalBatch'
import { listEmployeePortalTokens } from '../api/employeePortalService'
import { employeePortalKeys } from '../api/employeePortalKeys'
import type {
  FetchPortalTokenBatchResults,
  StartPortalTokenBatchResult,
} from '../api/employeePortalBatchTypes'

function isActivePortalToken(token: {
  is_active: boolean | null
  revoked_at: string | null
}): boolean {
  return Boolean(token.is_active && !token.revoked_at)
}

interface PortalTokenBatchDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  employees: Array<{ id: string | null }>
  onCompleted: (payload: {
    start: StartPortalTokenBatchResult
    results: FetchPortalTokenBatchResults | null
  }) => void
}

export function PortalTokenBatchDialog({
  open,
  onOpenChange,
  employees,
  onCompleted,
}: PortalTokenBatchDialogProps) {
  const { t } = useTranslation('employees')
  const { mutate, isPending, reset } = useRunEmployeePortalBatch()

  const [label, setLabel] = useState('WhatsApp')
  const [pinRequired, setPinRequired] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [retryKey, setRetryKey] = useState<string | null>(null)

  const employeeIds = useMemo(
    () => employees.map((e) => e.id).filter((id): id is string => Boolean(id)),
    [employees],
  )

  const tokenQueries = useQueries({
    queries: employeeIds.map((employeeId) => ({
      queryKey: employeePortalKeys.tokens(employeeId),
      queryFn: () => listEmployeePortalTokens(employeeId),
      enabled: open && employeeIds.length > 0,
      staleTime: 30_000,
    })),
  })

  const willSupersedeCount = useMemo(() => {
    let count = 0
    for (const query of tokenQueries) {
      const tokens = query.data ?? []
      if (tokens.some((token) => isActivePortalToken(token))) {
        count += 1
      }
    }
    return count
  }, [tokenQueries])

  useEffect(() => {
    if (!open) return
    setLabel('WhatsApp')
    setPinRequired(true)
    setError(null)
    setRetryKey(null)
    reset()
  }, [open, reset])

  function runBatch(idempotencyKey: string) {
    setError(null)
    mutate(
      {
        employeeIds,
        pinMustSet: pinRequired,
        label: label.trim() || undefined,
        skipInactive: true,
        idempotencyKey,
      },
      {
        onSuccess: (payload) => {
          onOpenChange(false)
          onCompleted(payload)
        },
        onError: (err) => {
          const code = normalizePortalTokenBatchError(err)
          if (code === 'batch_too_large') {
            setError(
              t(
                'employees.portal_access.batch_error_too_large',
                'Màxim 100 empleats per lot.',
              ),
            )
          } else if (code === 'batch_rate_limited') {
            setError(
              t(
                'employees.portal_access.batch_error_rate_limited',
                'Màxim 5 lots per hora. Espera una estona o obre un lot recent.',
              ),
            )
          } else if (code === 'unauthorized') {
            setError(
              t(
                'employees.portal_access.portal_url_permission_error',
                'No tens permís attendance.manage per generar enllaços.',
              ),
            )
          } else {
            setError(
              t('employees.portal_access.batch_error_generic', 'No s\'ha pogut generar el lot.'),
            )
          }
        },
      },
    )
  }

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (employeeIds.length === 0 || isPending) return

    const idempotencyKey = retryKey ?? getStoredBatchIdempotencyKey() ?? createBatchIdempotencyKey()
    if (!retryKey) setRetryKey(idempotencyKey)
    runBatch(idempotencyKey)
  }

  function handleRetry() {
    const key = retryKey ?? getStoredBatchIdempotencyKey()
    if (!key) return
    setRetryKey(key)
    runBatch(key)
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-lg">
        <form onSubmit={handleSubmit}>
          <DialogHeader>
            <DialogTitle>
              {t('employees.portal_access.batch_create_title', 'Generar enllaços en massa')}
            </DialogTitle>
            <DialogDescription>
              {t(
                'employees.portal_access.batch_create_description',
                'Es generaran enllaços nous per als empleats seleccionats. Pots tornar a descarregar el resultat durant 1 hora.',
              )}
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-4 py-2">
            <p className="text-sm rounded-md border bg-muted/40 px-3 py-2">
              {t(
                'employees.portal_access.batch_summary',
                'S\'generaran enllaços per {{count}} empleats. {{supersede}} tenen un enllaç actiu del mateix tipus que quedarà revocat.',
                { count: employeeIds.length, supersede: willSupersedeCount },
              )}
            </p>

            {employeeIds.length > 100 ? (
              <p className="text-sm text-destructive rounded-md border border-destructive/40 bg-destructive/5 px-3 py-2">
                {t(
                  'employees.portal_access.batch_error_too_large',
                  'Màxim 100 empleats per lot.',
                )}
              </p>
            ) : null}

            <div className="space-y-2">
              <label className="text-sm font-medium" htmlFor="batch-label">
                {t('employees.portal_access.label_field', 'Etiqueta')}
              </label>
              <Input
                id="batch-label"
                value={label}
                onChange={(e) => setLabel(e.target.value)}
                placeholder={t('employees.portal_access.label_placeholder', 'WhatsApp, QR vestuari…')}
              />
            </div>

            <div className="flex items-start gap-2">
              <Checkbox
                id="batch-pin-required"
                checked={pinRequired}
                onCheckedChange={(checked) => setPinRequired(checked === true)}
              />
              <div className="space-y-1">
                <label htmlFor="batch-pin-required" className="text-sm font-medium leading-none">
                  {t('employees.portal_access.pin_enabled', 'Requerir PIN de 4–6 dígits')}
                </label>
                <p className="text-xs text-muted-foreground">
                  {t(
                    'employees.portal_access.pin_employee_setup_hint',
                    'L\'empleat definirà el seu propi PIN al primer accés. Tu no el veuràs.',
                  )}
                </p>
              </div>
            </div>

            {!pinRequired ? (
              <p className="text-sm text-amber-800 dark:text-amber-200 rounded-md border border-amber-500/40 bg-amber-50 dark:bg-amber-950/30 px-3 py-2 flex gap-2">
                <AlertTriangle className="h-4 w-4 shrink-0 mt-0.5" aria-hidden />
                {t(
                  'employees.portal_access.no_pin_warning',
                  'Sense PIN, qualsevol persona amb l\'URL podrà fitxar en nom d\'aquest empleat.',
                )}
              </p>
            ) : null}

            {error ? (
              <p className="text-sm text-destructive rounded-md border border-destructive/40 bg-destructive/5 px-3 py-2">
                {error}
              </p>
            ) : null}
          </div>

          <DialogFooter className="gap-2 sm:gap-0">
            {error && retryKey ? (
              <Button type="button" variant="outline" onClick={handleRetry} disabled={isPending}>
                {t('employees.portal_access.batch_retry', 'Reintentar')}
              </Button>
            ) : null}
            <Button
              type="submit"
              disabled={isPending || employeeIds.length === 0 || employeeIds.length > 100}
              className="gap-2"
            >
              {isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : <Link2 className="h-4 w-4" />}
              {isPending
                ? t('employees.portal_access.batch_running', 'Generant…')
                : t('employees.portal_access.batch_submit', 'Generar enllaços')}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}
