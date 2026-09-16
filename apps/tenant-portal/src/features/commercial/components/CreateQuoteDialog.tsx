import { useEffect, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Search } from 'lucide-react'
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
import { useTenant } from '@/contexts/TenantContext'
import { useIsFieldService } from '@/hooks/useSectorLabel'
import { getProjectsPage } from '@/features/projects/api/projectsService'
import { issueCommercialDocument } from '../api/commercialFlowService'

interface CreateQuoteDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  onCreated: (documentId: string) => void
}

function useDebouncedValue<T>(value: T, delayMs: number): T {
  const [debounced, setDebounced] = useState(value)
  useEffect(() => {
    const id = window.setTimeout(() => setDebounced(value), delayMs)
    return () => window.clearTimeout(id)
  }, [value, delayMs])
  return debounced
}

export function CreateQuoteDialog({
  open,
  onOpenChange,
  onCreated,
}: CreateQuoteDialogProps) {
  const { t } = useTranslation('projects')
  const { activeTenant } = useTenant()
  const isFieldService = useIsFieldService()
  const [q, setQ] = useState('')
  const debouncedQ = useDebouncedValue(q, 250)
  const [selectedProjectId, setSelectedProjectId] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!open) {
      setQ('')
      setSelectedProjectId(null)
      setBusy(false)
      setError(null)
    }
  }, [open])

  const { data, isLoading } = useQuery({
    queryKey: [
      'projects',
      'quote-create-picker',
      activeTenant?.id,
      debouncedQ,
      isFieldService,
    ],
    queryFn: () =>
      getProjectsPage(activeTenant!.id, {
        page: 1,
        pageSize: 20,
        q: debouncedQ,
        status: '',
        type: isFieldService ? 'work_order' : '',
        siteId: '',
        departmentId: '',
        plannedStartFrom: '',
        plannedStartTo: '',
        sortField: 'created_at',
        sortDirection: 'desc',
        openOnly: true,
      }),
    enabled: open && !!activeTenant?.id,
  })

  const items = data?.items ?? []

  async function handleCreate() {
    if (!selectedProjectId || busy) return
    setBusy(true)
    setError(null)
    try {
      const documentId = await issueCommercialDocument({
        projectId: selectedProjectId,
        docType: 'quote',
      })
      onCreated(documentId)
      onOpenChange(false)
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      setError(
        message.includes('project_client_required')
          ? t(
              'projects.quotes.create_needs_client',
              'Aquesta ordre no té client. Obre l’ordre i assigna’n un.',
            )
          : t(
              'projects.quotes.create_failed',
              'No s’ha pogut emetre el pressupost. Comprova que l’ordre tingui línies de preu.',
            ),
      )
    } finally {
      setBusy(false)
    }
  }

  return (
    <Dialog open={open} onOpenChange={(next) => !busy && onOpenChange(next)}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>
            {t('projects.quotes.create_title', 'Nou pressupost')}
          </DialogTitle>
          <DialogDescription>
            {t(
              'projects.quotes.create_help',
              'Tria una ordre amb full de preus. El pressupost s’emetrà amb les línies actuals.',
            )}
          </DialogDescription>
        </DialogHeader>

        <label className="relative block">
          <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            className="pl-9"
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder={t(
              'projects.quotes.create_search_placeholder',
              'Cerca pel nom de l’ordre…',
            )}
            aria-label={t(
              'projects.quotes.create_search_aria',
              'Cerca ordre per emetre pressupost',
            )}
          />
        </label>

        <ul className="max-h-64 overflow-y-auto divide-y divide-border rounded-lg border border-border">
          {isLoading && (
            <li className="px-3 py-4 text-sm text-muted-foreground">
              {t('projects.quotes.loading', 'Carregant…')}
            </li>
          )}
          {!isLoading && items.length === 0 && (
            <li className="px-3 py-4 text-sm text-muted-foreground">
              {t(
                'projects.quotes.create_empty',
                'Cap ordre oberta no coincideix amb la cerca.',
              )}
            </li>
          )}
          {items.map((project) => {
            const selected = selectedProjectId === project.id
            const subtitle = [
              project.client_display_name,
              project.contact_site_city,
            ]
              .filter(Boolean)
              .join(' · ')
            return (
              <li key={project.id}>
                <button
                  type="button"
                  className={`w-full px-3 py-2.5 text-left transition-colors ${
                    selected
                      ? 'bg-muted'
                      : 'hover:bg-muted/60'
                  }`}
                  onClick={() => setSelectedProjectId(project.id)}
                >
                  <p className="text-sm font-medium text-foreground truncate">
                    {project.name || project.id}
                  </p>
                  {subtitle ? (
                    <p className="text-xs text-muted-foreground truncate">
                      {subtitle}
                    </p>
                  ) : null}
                </button>
              </li>
            )
          })}
        </ul>

        {error ? (
          <p className="text-sm text-destructive" role="alert">
            {error}
          </p>
        ) : null}

        <DialogFooter>
          <Button
            type="button"
            variant="outline"
            disabled={busy}
            onClick={() => onOpenChange(false)}
          >
            {t('common.cancel', 'Cancel·lar')}
          </Button>
          <Button
            type="button"
            disabled={busy || !selectedProjectId}
            onClick={() => void handleCreate()}
          >
            {busy
              ? t('projects.commercial.reissue_busy', 'Creant…')
              : t('projects.quotes.create_confirm', 'Emetre pressupost')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
