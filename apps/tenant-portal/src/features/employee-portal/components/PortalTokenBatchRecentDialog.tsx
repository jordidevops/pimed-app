import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { History, Loader2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { recoverEmployeePortalTokenBatch } from '../api/employeePortalBatchService'
import type {
  FetchPortalTokenBatchResults,
  PortalTokenBatchListItem,
  StartPortalTokenBatchResult,
} from '../api/employeePortalBatchTypes'
import { useEmployeePortalBatchList } from '../api/useEmployeePortalBatch'

interface PortalTokenBatchRecentDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  onRecover: (payload: {
    start: StartPortalTokenBatchResult
    results: FetchPortalTokenBatchResults
  }) => void
}

function batchListTitle(item: PortalTokenBatchListItem, locale: string): string {
  if (item.label?.trim()) return item.label.trim()
  return new Date(item.createdAt).toLocaleString(locale)
}

export function PortalTokenBatchRecentDialog({
  open,
  onOpenChange,
  onRecover,
}: PortalTokenBatchRecentDialogProps) {
  const { t, i18n } = useTranslation('employees')
  const { data: batches = [], isLoading, isError, refetch } = useEmployeePortalBatchList(open)
  const [openingBatchId, setOpeningBatchId] = useState<string | null>(null)
  const [openError, setOpenError] = useState<string | null>(null)

  useEffect(() => {
    if (!open) {
      setOpenError(null)
      setOpeningBatchId(null)
    }
  }, [open])

  async function handleOpenBatch(item: PortalTokenBatchListItem) {
    setOpeningBatchId(item.batchId)
    setOpenError(null)
    try {
      const payload = await recoverEmployeePortalTokenBatch(item.batchId, item.expiresAt)
      onRecover(payload)
      onOpenChange(false)
    } catch {
      setOpenError(
        t(
          'employees.portal_access.batch_recovery_expired',
          'El lot ja no es pot recuperar (ha expirat).',
        ),
      )
      void refetch()
    } finally {
      setOpeningBatchId(null)
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-lg max-h-[85vh] flex flex-col">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <History className="h-5 w-5" aria-hidden />
            {t('employees.portal_access.batch_recent_title', 'Lots recents')}
          </DialogTitle>
          <DialogDescription>
            {t(
              'employees.portal_access.batch_recent_description',
              'Lots d\'accés al portal generats durant l\'última hora. Obre\'n un per copiar, exportar o imprimir de nou.',
            )}
          </DialogDescription>
        </DialogHeader>

        {openError ? (
          <p className="text-sm text-destructive rounded-md border border-destructive/40 bg-destructive/5 px-3 py-2">
            {openError}
          </p>
        ) : null}

        <div className="overflow-auto flex-1 min-h-0 -mx-1 px-1">
          {isLoading ? (
            <div className="flex justify-center py-10">
              <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
            </div>
          ) : isError ? (
            <p className="text-sm text-destructive text-center py-8">
              {t('employees.portal_access.batch_recent_load_error', 'No s\'han pogut carregar els lots.')}
            </p>
          ) : batches.length === 0 ? (
            <p className="text-sm text-muted-foreground text-center py-8">
              {t(
                'employees.portal_access.batch_recent_empty',
                'No hi ha lots recents disponibles (caduquen al cap d\'1 hora).',
              )}
            </p>
          ) : (
            <ul className="space-y-2">
              {batches.map((item) => {
                const expiresLabel = new Date(item.expiresAt).toLocaleString(i18n.language)
                const isOpening = openingBatchId === item.batchId

                return (
                  <li
                    key={item.batchId}
                    className="rounded-lg border bg-card px-3 py-3 flex flex-col sm:flex-row sm:items-center gap-3"
                  >
                    <div className="flex-1 min-w-0 space-y-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <p className="font-medium text-sm truncate">
                          {batchListTitle(item, i18n.language)}
                        </p>
                      </div>
                      <p className="text-xs text-muted-foreground">
                        {t(
                          'employees.portal_access.batch_recent_summary',
                          '{{created}} creats de {{total}} · caduca {{expires}}',
                          {
                            created: item.createdCount,
                            total: item.employeeCount,
                            expires: expiresLabel,
                          },
                        )}
                      </p>
                    </div>
                    <Button
                      type="button"
                      size="sm"
                      className="shrink-0"
                      disabled={isOpening || openingBatchId !== null}
                      onClick={() => void handleOpenBatch(item)}
                    >
                      {isOpening ? (
                        <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                      ) : null}
                      {t('employees.portal_access.batch_recent_open_action', 'Obrir')}
                    </Button>
                  </li>
                )
              })}
            </ul>
          )}
        </div>
      </DialogContent>
    </Dialog>
  )
}
