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
import { useIsFieldService, useSectorLabel } from '@/hooks/useSectorLabel'
import { getContactSites, searchContacts } from '@/features/contacts/api/contactsService'
import {
  createOrphanQuoteDraft,
  setCommercialDocumentTitle,
} from '../api/commercialFlowService'
import { commercialErrorMessage } from '../utils/commercialErrorMessage'
import type { FormalizationMode } from '../utils/deviationApprovalThreshold'
import { supabase } from '@/lib/supabase'
import { cn } from '@/lib/utils'

interface CreateOrphanQuoteDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  clientId?: string | null
  clientName?: string | null
  formalizationMode: FormalizationMode
  onBack?: () => void
  /** CF-29: reobre el selector de formalització només per aquest document. */
  onChangeFormalization?: () => void
}

function useDebouncedValue<T>(value: T, delayMs: number): T {
  const [debounced, setDebounced] = useState(value)
  useEffect(() => {
    const id = window.setTimeout(() => setDebounced(value), delayMs)
    return () => window.clearTimeout(id)
  }, [value, delayMs])
  return debounced
}

function inSentence(label: string): string {
  if (!label) return label
  return label.charAt(0).toLocaleLowerCase('ca') + label.slice(1)
}

const JOURNEY_SIGNED_QUOTE = [
  { id: 'contact', labelKey: 'projects.orphan.journey_contact', fallback: '{{contact}}' },
  { id: 'lines', labelKey: 'projects.orphan.journey_lines', fallback: 'Full de preus' },
  { id: 'template', labelKey: 'projects.orphan.journey_template', fallback: 'Plantilla' },
  { id: 'issue', labelKey: 'projects.orphan.journey_issue', fallback: 'Emetre' },
  { id: 'reply', labelKey: 'projects.orphan.journey_reply', fallback: 'Resposta' },
  { id: 'os', labelKey: 'projects.orphan.journey_os', fallback: 'Ordre' },
] as const

/** separate_agreement: after accept → contract (not Ordre as step 6). */
const JOURNEY_SEPARATE_AGREEMENT = [
  { id: 'contact', labelKey: 'projects.orphan.journey_contact', fallback: '{{contact}}' },
  { id: 'lines', labelKey: 'projects.orphan.journey_lines', fallback: 'Full de preus' },
  { id: 'template', labelKey: 'projects.orphan.journey_template', fallback: 'Plantilla' },
  { id: 'issue', labelKey: 'projects.orphan.journey_issue', fallback: 'Emetre' },
  { id: 'reply', labelKey: 'projects.orphan.journey_reply', fallback: 'Resposta' },
  {
    id: 'contract',
    labelKey: 'projects.orphan.journey_contract',
    fallback: 'Contracte',
  },
] as const

function defaultQuoteTitle(
  clientName: string,
  t: (key: string, fallback: string, opts?: Record<string, string>) => string,
) {
  const date = new Date().toLocaleDateString('ca-ES', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
  })
  return t('projects.orphan.default_title', 'Pressupost — {{client}} — {{date}}', {
    client: clientName,
    date,
  })
}

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
  formalizationMode,
  onBack,
  onChangeFormalization,
}: CreateOrphanQuoteDialogProps) {
  const { t } = useTranslation(['projects', 'common'])
  const isFieldService = useIsFieldService()
  const contactLabel = useSectorLabel('contact', isFieldService ? 'Client' : 'Contacte')
  const contactWord = inSentence(contactLabel)
  const journey =
    formalizationMode === 'separate_agreement'
      ? JOURNEY_SEPARATE_AGREEMENT
      : JOURNEY_SIGNED_QUOTE
  const { activeTenant, sites: tenantSites, selectedSiteId } = useTenant()
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const [pickedId, setPickedId] = useState<string | null>(
    fixedClientId && fixedClientName ? fixedClientId : null,
  )
  const [pickedName, setPickedName] = useState<string | null>(
    fixedClientId && fixedClientName ? fixedClientName : null,
  )
  const [contactSiteId, setContactSiteId] = useState<string | null>(null)
  const [query, setQuery] = useState('')
  const debounced = useDebouncedValue(query, 250)
  const [busy, setBusy] = useState(false)
  const [title, setTitle] = useState('')
  const [titleTouched, setTitleTouched] = useState(false)

  const lockedClientId = fixedClientId && fixedClientName ? fixedClientId : null

  const contactsQuery = useQuery({
    queryKey: ['contacts', 'search', 'orphan-wizard', debounced],
    queryFn: () => searchContacts({ q: debounced, limit: 20 }),
    enabled: open && !lockedClientId,
  })

  const options = useMemo(
    () => (contactsQuery.data ?? []).filter((c) => !!c.id),
    [contactsQuery.data],
  )
  const pickedVisible = pickedId && options.some((c) => c.id === pickedId) ? pickedId : null
  const clientId = lockedClientId ?? pickedVisible

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

  const contactSites = (sitesQuery.data ?? []).filter((s) => !!s.id)
  const showContactSitePicker = contactSites.length > 1
  const resolvedTenantSiteId =
    selectedSiteId ?? (tenantSites.length === 1 ? tenantSites[0]?.id ?? null : null)

  useEffect(() => {
    if (!open) return
    setPickedId(fixedClientId && fixedClientName ? fixedClientId : null)
    setPickedName(fixedClientId && fixedClientName ? fixedClientName : null)
    setContactSiteId(null)
    setQuery('')
    setBusy(false)
    setTitle('')
    setTitleTouched(false)
  }, [open, fixedClientId, fixedClientName])

  const clientName = lockedClientId ? fixedClientName : pickedName

  useEffect(() => {
    if (!open || !clientName || titleTouched) return
    setTitle(defaultQuoteTitle(clientName, t))
  }, [open, clientName, titleTouched, t])

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
        formalizationMode,
      })
      const nextTitle = title.trim()
      if (nextTitle) {
        await setCommercialDocumentTitle({ documentId: docId, title: nextTitle })
      }
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
            {formalizationMode === 'separate_agreement'
              ? t(
                  'projects.orphan.dialog_help_contract',
                  'Flux: {{contact}} → full de preus → plantilla → emetre → resposta. Si s’accepta, genera el contracte i envia’l a firmar.',
                  { contact: contactWord },
                )
              : t(
                  'projects.orphan.dialog_help',
                  'Flux: {{contact}} → full de preus → plantilla → emetre. L’ordre de servei només es crea si el client accepta.',
                  { contact: contactWord },
                )}
          </DialogDescription>
        </DialogHeader>

        <ol className="flex flex-wrap gap-1.5" aria-label={t('projects.orphan.journey_aria', 'Passos')}>
          {journey.map((step, index) => (
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
              {step.id === 'contact'
                ? t(step.labelKey, step.fallback, { contact: contactLabel })
                : t(step.labelKey, step.fallback)}
            </li>
          ))}
        </ol>

        <div className="space-y-3 py-1">
          {lockedClientId && fixedClientName ? (
            <p className="text-sm text-muted-foreground">
              {contactLabel}:{' '}
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
                  placeholder={t('projects.orphan.pick_placeholder', 'Cerca {{contact}}…', {
                    contact: contactWord,
                  })}
                  autoFocus
                />
              </label>
              <ul className="max-h-40 overflow-y-auto rounded-md border divide-y">
                {options.length === 0 ? (
                  <li className="px-3 py-4 text-sm text-muted-foreground">
                    {contactsQuery.isFetching
                      ? t('common:loading', 'Carregant…')
                      : t('projects.orphan.pick_empty', 'Cap {{contact}} trobat.', {
                          contact: contactWord,
                        })}
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

          {clientId ? (
            <label className="block space-y-1.5">
              <span className="text-sm font-medium">
                {t('projects.orphan.title_label', 'Títol')}
              </span>
              <Input
                value={title}
                maxLength={120}
                onChange={(e) => {
                  setTitleTouched(true)
                  setTitle(e.target.value)
                }}
              />
              <span className="block text-xs text-muted-foreground">
                {t(
                  'projects.orphan.title_prefill_help',
                  'Ja ve ple. Pots canviar-lo abans de continuar, i també a Emetre.',
                )}
              </span>
            </label>
          ) : null}

          {clientId && contactSites.length === 1 ? (
            <p className="text-xs text-muted-foreground">
              {t(
                'projects.orphan.site_auto_one',
                'S’usarà l’única adreça del {{contact}}.',
                { contact: contactWord },
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
                'Aquest {{contact}} ja té {{count}} pressupost(os) emès(os) sense ordre. Pots crear-ne un altre.',
                { contact: contactWord, count: openIssuedCount },
              )}
            </p>
          ) : null}

          <div className="flex items-start justify-between gap-2 rounded-xl border border-border bg-muted/30 px-3 py-2">
            <p className="text-sm text-muted-foreground">
              {formalizationMode === 'separate_agreement'
                ? t(
                    'projects.quotes.wizard_formalization_separate_title',
                    'Pressupost i contracte a part',
                  )
                : t(
                    'projects.quotes.wizard_formalization_signed_title',
                    'El pressupost és el contracte',
                  )}
            </p>
            {onChangeFormalization ? (
              <Button
                type="button"
                variant="ghost"
                size="sm"
                className="shrink-0"
                onClick={onChangeFormalization}
                disabled={busy}
              >
                {t('projects.quotes.wizard_change_default', 'Canviar')}
              </Button>
            ) : null}
          </div>
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
          <Button
            onClick={() => void handleCreate()}
            disabled={busy || !clientId || !title.trim()}
          >
            {busy
              ? t('common:saving', 'Creant…')
              : t('projects.orphan.submit', 'Continuar amb el full de preus')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
