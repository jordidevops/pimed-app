import { useEffect, useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
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
import { useToast } from '@/hooks/use-toast'
import { useEffectiveSettings } from '@/hooks/useSettings'
import { getContactSites, searchContacts } from '@/features/contacts/api/contactsService'
import { useDocumentTemplates } from '@/features/signing/api/useDocumentTemplates'
import { createOrphanQuoteDraft } from '../api/commercialFlowService'
import { commercialErrorMessage } from '../utils/commercialErrorMessage'
import {
  parseFormalizationModeDefault,
  type FormalizationMode,
} from '../utils/deviationApprovalThreshold'
import { QuoteFormalizationFields } from './QuoteFormalizationFields'
import { supabase } from '@/lib/supabase'
import { cn } from '@/lib/utils'

interface CreateOrphanQuoteDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  clientId?: string | null
  clientName?: string | null
  onBack?: () => void
}

function useDebouncedValue<T>(value: T, delayMs: number): T {
  const [debounced, setDebounced] = useState(value)
  useEffect(() => {
    const id = window.setTimeout(() => setDebounced(value), delayMs)
    return () => window.clearTimeout(id)
  }, [value, delayMs])
  return debounced
}

const JOURNEY = [
  { id: 'contact', labelKey: 'projects.orphan.journey_contact', fallback: 'Contacte' },
  { id: 'lines', labelKey: 'projects.orphan.journey_lines', fallback: 'Full de preus' },
  { id: 'issue', labelKey: 'projects.orphan.journey_issue', fallback: 'Emetre' },
  { id: 'reply', labelKey: 'projects.orphan.journey_reply', fallback: 'Resposta' },
  { id: 'os', labelKey: 'projects.orphan.journey_os', fallback: 'Ordre' },
] as const

async function countOpenIssuedOrphans(clientId: string): Promise<number> {
  const { count, error } = await supabase
    .from('commercial_documents' as never)
    .select('id', { count: 'exact', head: true })
    .eq('client_id', clientId)
    .eq('doc_type', 'quote')
    .eq('status', 'issued')
    .is('project_id', null)
  if (error) throw error
  return count ?? 0
}

export function CreateOrphanQuoteDialog({
  open,
  onOpenChange,
  clientId: fixedClientId = null,
  clientName: fixedClientName = null,
  onBack,
}: CreateOrphanQuoteDialogProps) {
  const { t } = useTranslation(['projects', 'common'])
  const { activeTenant, sites: tenantSites, selectedSiteId } = useTenant()
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const [pickedId, setPickedId] = useState<string | null>(fixedClientId)
  const [pickedName, setPickedName] = useState<string | null>(fixedClientName)
  const [contactSiteId, setContactSiteId] = useState<string | null>(null)
  const [query, setQuery] = useState('')
  const debounced = useDebouncedValue(query, 250)
  const [busy, setBusy] = useState(false)
  const [mode, setMode] = useState<FormalizationMode>('signed_quote')
  const [modeTouched, setModeTouched] = useState(false)
  const [templateId, setTemplateId] = useState('')

  const clientId = fixedClientId ?? pickedId

  const { data: effective } = useEffectiveSettings(
    { tenantId: activeTenant?.id ?? '' },
    { enabled: open && !!activeTenant?.id },
  )
  const { data: templates = [] } = useDocumentTemplates(open ? activeTenant?.id : undefined)

  const contactsQuery = useQuery({
    queryKey: ['contacts', 'search', 'orphan-wizard', debounced],
    queryFn: () => searchContacts({ q: debounced, limit: 20 }),
    enabled: open && !fixedClientId,
  })

  const sitesQuery = useQuery({
    queryKey: ['contact_sites', 'orphan-wizard', clientId],
    queryFn: () => getContactSites(clientId!),
    enabled: open && !!clientId,
  })

  const openIssuedQuery = useQuery({
    queryKey: ['commercial', 'orphan-open-issued', clientId],
    queryFn: () => countOpenIssuedOrphans(clientId!),
    enabled: open && !!clientId,
  })

  const options = useMemo(
    () => (contactsQuery.data ?? []).filter((c) => !!c.id),
    [contactsQuery.data],
  )

  const contactSites = (sitesQuery.data ?? []).filter((s) => !!s.id)
  const showContactSitePicker = contactSites.length > 1
  const resolvedTenantSiteId =
    selectedSiteId ?? (tenantSites.length === 1 ? tenantSites[0]?.id ?? null : null)

  useEffect(() => {
    if (!open) return
    setPickedId(fixedClientId)
    setPickedName(fixedClientName)
    setContactSiteId(null)
    setQuery('')
    setBusy(false)
    setMode('signed_quote')
    setModeTouched(false)
    setTemplateId('')
  }, [open, fixedClientId, fixedClientName])

  useEffect(() => {
    if (!open || modeTouched) return
    setMode(parseFormalizationModeDefault(effective))
  }, [open, effective, modeTouched])

  useEffect(() => {
    const list = (sitesQuery.data ?? []).filter((s) => !!s.id)
    if (list.length === 1) {
      setContactSiteId(list[0]?.id ?? null)
      return
    }
    if (list.length === 0) {
      setContactSiteId(null)
      return
    }
    setContactSiteId((prev) =>
      prev && list.some((s) => s.id === prev) ? prev : null,
    )
  }, [clientId, sitesQuery.data])

  async function handleCreate() {
    if (!activeTenant?.id || !clientId) return
    setBusy(true)
    try {
      const docId = await createOrphanQuoteDraft({
        tenantId: activeTenant.id,
        clientId,
        contactSiteId,
        siteId: resolvedTenantSiteId,
        formalizationMode: mode,
      })
      await queryClient.invalidateQueries({ queryKey: ['commercial_documents', 'search'] })
      await queryClient.invalidateQueries({ queryKey: ['commercial_documents', 'client'] })
      toast({
        title: t('projects.orphan.draft_created', 'Esborrany creat'),
        description: t(
          'projects.orphan.draft_created_help',
          'Omple el full de preus i emet el pressupost. No es crea cap ordre fins que s’accepti.',
        ),
      })
      onOpenChange(false)
      navigate(`/sales/quotes/${docId}`)
    } catch (err) {
      toast({
        variant: 'destructive',
        description: commercialErrorMessage(
          err,
          t('projects.orphan.create_failed', 'No s\'ha pogut crear l\'esborrany'),
        ),
      })
    } finally {
      setBusy(false)
    }
  }

  const openIssuedCount = openIssuedQuery.data ?? 0

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-lg max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {t('projects.quotes.wizard_type_orphan_title', 'Només pressupost')}
          </DialogTitle>
          <DialogDescription>
            {t(
              'projects.orphan.dialog_help',
              'Flux: contacte → full de preus → emetre. L’ordre de servei només es crea si el client accepta.',
            )}
          </DialogDescription>
        </DialogHeader>

        <ol className="flex flex-wrap gap-1.5" aria-label={t('projects.orphan.journey_aria', 'Passos')}>
          {JOURNEY.map((step, index) => (
            <li
              key={step.id}
              className={cn(
                'inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px]',
                index === 0
                  ? 'border-primary bg-primary/10 font-semibold text-foreground'
                  : 'border-border text-muted-foreground',
              )}
            >
              <span className="tabular-nums opacity-70">{index + 1}.</span>
              {t(step.labelKey, step.fallback)}
            </li>
          ))}
        </ol>

        <div className="space-y-3 py-1">
          {fixedClientId && fixedClientName ? (
            <p className="text-sm text-muted-foreground">
              {t('projects.orphan.client', 'Client')}:{' '}
              <span className="font-medium text-foreground">{fixedClientName}</span>
            </p>
          ) : (
            <>
              <label className="relative block">
                <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
                <Input
                  className="pl-9"
                  value={query}
                  onChange={(e) => setQuery(e.target.value)}
                  placeholder={t('projects.orphan.pick_placeholder', 'Cerca contacte…')}
                  autoFocus
                />
              </label>
              <ul className="max-h-40 overflow-y-auto rounded-md border divide-y">
                {options.length === 0 ? (
                  <li className="px-3 py-4 text-sm text-muted-foreground">
                    {contactsQuery.isFetching
                      ? t('common:loading', 'Carregant…')
                      : t('projects.orphan.pick_empty', 'Cap contacte trobat.')}
                  </li>
                ) : (
                  options.map((c) => (
                    <li key={c.id}>
                      <button
                        type="button"
                        className={cn(
                          'flex w-full px-3 py-2 text-left text-sm hover:bg-muted/60',
                          pickedId === c.id && 'bg-primary/10 font-medium',
                        )}
                        onClick={() => {
                          setPickedId(c.id!)
                          setPickedName(c.display_name ?? null)
                        }}
                      >
                        {c.display_name ?? c.id}
                      </button>
                    </li>
                  ))
                )}
              </ul>
            </>
          )}

          {clientId && showContactSitePicker ? (
            <label className="block space-y-1.5">
              <span className="text-sm font-medium">
                {t('projects.orphan.site_label', 'Adreça d’intervenció')}
              </span>
              <select
                className="flex h-9 w-full rounded-md border border-input bg-transparent px-3 text-sm"
                value={contactSiteId ?? ''}
                onChange={(e) => setContactSiteId(e.target.value || null)}
              >
                <option value="">
                  {t('projects.orphan.site_none', 'Sense adreça')}
                </option>
                {contactSites.map((s) => (
                  <option key={s.id} value={s.id ?? ''}>
                    {s.name?.trim() || s.address?.trim() || s.id}
                  </option>
                ))}
              </select>
            </label>
          ) : null}

          {clientId && contactSites.length === 1 ? (
            <p className="text-xs text-muted-foreground">
              {t(
                'projects.orphan.site_auto_one',
                'S’usarà l’única adreça del client.',
              )}{' '}
              <span className="font-medium text-foreground">
                {contactSites[0]?.name?.trim() ||
                  contactSites[0]?.address?.trim() ||
                  ''}
              </span>
            </p>
          ) : null}

          {clientId && openIssuedCount > 0 ? (
            <p
              className="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-950 dark:border-amber-900 dark:bg-amber-950/40 dark:text-amber-100"
              role="status"
            >
              {t(
                'projects.orphan.open_issued_warn',
                'Aquest client ja té {{count}} pressupost(os) emès(os) sense ordre. Pots crear-ne un altre.',
                { count: openIssuedCount },
              )}
            </p>
          ) : null}

          <QuoteFormalizationFields
            mode={mode}
            templateId={templateId}
            templates={templates}
            disabled={busy}
            showTemplate={false}
            onModeChange={(next) => {
              setModeTouched(true)
              setMode(next)
            }}
            onTemplateChange={setTemplateId}
          />
        </div>

        <DialogFooter className="gap-2 sm:gap-0">
          {onBack ? (
            <Button type="button" variant="outline" onClick={onBack} disabled={busy}>
              {t('projects.quotes.wizard_back', 'Enrere')}
            </Button>
          ) : (
            <Button variant="outline" onClick={() => onOpenChange(false)} disabled={busy}>
              {t('common:cancel', 'Cancel·lar')}
            </Button>
          )}
          <Button onClick={() => void handleCreate()} disabled={busy || !clientId}>
            {busy
              ? t('common:saving', 'Creant…')
              : t('projects.orphan.submit', 'Continuar amb el full de preus')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
