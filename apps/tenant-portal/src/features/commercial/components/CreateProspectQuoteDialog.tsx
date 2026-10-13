import { useEffect, useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Search } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
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
import { useIsFieldService, useSectorContactListLabel, useSectorLabel } from '@/hooks/useSectorLabel'
import { searchContacts } from '@/features/contacts/api/contactsService'
import { createProspectWorkOrder } from '@/features/projects/api/projectsService'
import type { FormalizationMode } from '../utils/deviationApprovalThreshold'
import { cn } from '@/lib/utils'

interface CreateProspectQuoteDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  /** When set (contact tab / filter), skip the contact step. */
  clientId?: string | null
  clientName?: string | null
  formalizationMode: FormalizationMode
  onBack?: () => void
}

type WizardStep = 'contact' | 'details'

function defaultOrderName(
  clientName: string | null | undefined,
  t: (key: string, fallback: string, opts?: Record<string, string>) => string,
) {
  const date = new Date().toLocaleDateString('ca-ES', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
  })
  if (clientName) {
    return t('projects.prospect.default_name', 'Ordre — {{client}} — {{date}}', {
      client: clientName,
      date,
    })
  }
  return t('projects.prospect.default_name_generic', 'Ordre comercial — {{date}}', { date })
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

const JOURNEY_STEPS = [
  { id: 'contact', labelKey: 'projects.prospect.journey_contact', fallback: '{{contact}}' },
  { id: 'order', labelKey: 'projects.prospect.journey_order', fallback: 'Ordre' },
  { id: 'lines', labelKey: 'projects.prospect.journey_lines', fallback: 'Full de preus' },
  { id: 'template', labelKey: 'projects.prospect.journey_template', fallback: 'Plantilla' },
  { id: 'issue', labelKey: 'projects.prospect.journey_issue', fallback: 'Emetre' },
  { id: 'followup', labelKey: 'projects.prospect.journey_followup', fallback: 'Seguiment' },
] as const

export function CreateProspectQuoteDialog({
  open,
  onOpenChange,
  clientId: fixedClientId = null,
  clientName: fixedClientName = null,
  formalizationMode,
  onBack,
}: CreateProspectQuoteDialogProps) {
  const { t } = useTranslation(['projects', 'common'])
  const isFieldService = useIsFieldService()
  const contactLabel = useSectorLabel('contact', isFieldService ? 'Client' : 'Contacte')
  const contactWord = inSentence(contactLabel)
  const contactsLabel = useSectorContactListLabel()
  const lockedClient = Boolean(fixedClientId && fixedClientName)
  const { activeTenant } = useTenant()
  const { toast } = useToast()
  const navigate = useNavigate()
  const queryClient = useQueryClient()

  const [step, setStep] = useState<WizardStep>(() => (fixedClientId && fixedClientName ? 'details' : 'contact'))
  const [pickedClientId, setPickedClientId] = useState<string | null>(
    fixedClientId && fixedClientName ? fixedClientId : null,
  )
  const [pickedClientName, setPickedClientName] = useState<string | null>(
    fixedClientId && fixedClientName ? fixedClientName : null,
  )
  const [clientQuery, setClientQuery] = useState('')
  const debouncedClientQuery = useDebouncedValue(clientQuery, 250)
  const [name, setName] = useState(() => defaultOrderName(fixedClientName, t))
  const [busy, setBusy] = useState(false)

  const effectiveClientId = (lockedClient ? fixedClientId : null) ?? pickedClientId
  const effectiveClientName = (lockedClient ? fixedClientName : null) ?? pickedClientName

  const contactsQuery = useQuery({
    queryKey: ['contacts', 'search', 'prospect-wizard', debouncedClientQuery],
    queryFn: () => searchContacts({ q: debouncedClientQuery, limit: 20 }),
    enabled: open && !lockedClient && step === 'contact',
  })

  const contactOptions = useMemo(
    () => (contactsQuery.data ?? []).filter((c) => !!c.id),
    [contactsQuery.data],
  )

  useEffect(() => {
    if (!open) return
    setStep(lockedClient ? 'details' : 'contact')
    setPickedClientId(lockedClient ? fixedClientId : null)
    setPickedClientName(lockedClient ? fixedClientName : null)
    setClientQuery('')
    setName(defaultOrderName(fixedClientName, t))
    setBusy(false)
  }, [open, fixedClientId, fixedClientName, t])

  useEffect(() => {
    if (!open || step !== 'details') return
    setName(defaultOrderName(effectiveClientName, t))
  }, [open, step, effectiveClientName, t])

  const journeyActiveIndex = step === 'contact' ? 0 : 1

  async function handleCreate() {
    if (!activeTenant?.id || !effectiveClientId || !name.trim()) return
    setBusy(true)
    try {
      const projectId = await createProspectWorkOrder({
        tenantId: activeTenant.id,
        name: name.trim(),
        clientId: effectiveClientId,
      })
      await queryClient.invalidateQueries({ queryKey: ['projects'] })
      await queryClient.invalidateQueries({
        queryKey: ['projects', 'by-client', effectiveClientId],
      })
      await queryClient.invalidateQueries({
        queryKey: ['prospect_orders', effectiveClientId],
      })
      toast({
        title: t('projects.prospect.created', 'Ordre creada'),
        description: t(
          'projects.prospect.created_help',
          'Ara omple el full de preus i emet el pressupost. L’ordre no surt a Avui fins que s’accepti.',
        ),
      })
      onOpenChange(false)
      navigate(`/field/orders/${projectId}?tab=prepare&formalization=${formalizationMode}`)
    } catch (err) {
      toast({
        variant: 'destructive',
        description:
          err instanceof Error
            ? err.message
            : t('projects.prospect.create_failed', 'No s\'ha pogut crear l\'ordre'),
      })
    } finally {
      setBusy(false)
    }
  }

  function selectContact(id: string, displayName: string | null) {
    setPickedClientId(id)
    setPickedClientName(displayName)
    setStep('details')
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>
            {t('projects.quotes.wizard_type_prospect_title', 'Feina amb pressupost')}
          </DialogTitle>
          <DialogDescription>
            {t(
              'projects.prospect.dialog_help',
              'Creem una ordre en preparació. La formalització ja està triada. Allà ompliràs el full de preus, la plantilla i emetràs. No apareix a Avui fins que s’accepti.',
            )}
          </DialogDescription>
        </DialogHeader>

        <ol
          className="flex flex-wrap gap-1.5"
          aria-label={t('projects.prospect.journey_aria', 'Passos del flux')}
        >
          {JOURNEY_STEPS.map((item, index) => {
            const done = index < journeyActiveIndex
            const current = index === journeyActiveIndex
            const upcoming = index > journeyActiveIndex
            return (
              <li
                key={item.id}
                className={cn(
                  'inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px]',
                  done &&
                    'border-emerald-300 bg-emerald-50 text-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-200',
                  current &&
                    'border-primary bg-primary/10 font-semibold text-foreground',
                  upcoming && 'border-border text-muted-foreground',
                )}
              >
                <span className="tabular-nums opacity-70">{index + 1}.</span>
                {item.id === 'contact'
                  ? t(item.labelKey, item.fallback, { contact: contactLabel })
                  : t(item.labelKey, item.fallback)}
              </li>
            )
          })}
        </ol>

        {step === 'contact' ? (
          <div className="space-y-3 py-1">
            <p className="text-sm text-muted-foreground">
              {t(
                'projects.prospect.pick_client_help',
                'Tria el {{contact}} per a qui prepares el pressupost.',
                { contact: contactWord },
              )}
            </p>
            <label className="relative block">
              <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                className="pl-9"
                value={clientQuery}
                onChange={(e) => setClientQuery(e.target.value)}
                placeholder={t(
                  'projects.prospect.pick_client_placeholder',
                  'Cerca {{contact}}…',
                  { contact: contactWord },
                )}
                autoFocus
              />
            </label>
            <ul className="max-h-56 overflow-y-auto rounded-md border border-border divide-y">
              {contactOptions.length === 0 ? (
                <li className="px-3 py-4 text-sm text-muted-foreground">
                  {contactsQuery.isFetching
                    ? t('common:loading', 'Carregant…')
                    : t(
                        'projects.prospect.pick_client_empty',
                        'Cap {{contact}}. Crea’n un a {{contacts}} o amplia la cerca.',
                        { contact: contactWord, contacts: contactsLabel },
                      )}
                </li>
              ) : (
                contactOptions.map((c) => (
                  <li key={c.id}>
                    <button
                      type="button"
                      className="flex w-full items-center px-3 py-2 text-left text-sm hover:bg-muted/60"
                      onClick={() => selectContact(c.id!, c.display_name ?? null)}
                    >
                      <span className="truncate font-medium">
                        {c.display_name ?? c.id}
                      </span>
                    </button>
                  </li>
                ))
              )}
            </ul>
          </div>
        ) : (
          <div className="space-y-3 py-1">
            {effectiveClientName ? (
              <p className="text-sm text-muted-foreground">
                {contactLabel}:{' '}
                <span className="font-medium text-foreground">{effectiveClientName}</span>
                {!lockedClient ? (
                  <Button
                    type="button"
                    variant="link"
                    className="ml-1 h-auto px-0 text-xs"
                    onClick={() => setStep('contact')}
                    disabled={busy}
                  >
                    {t('projects.prospect.change_client', 'Canviar')}
                  </Button>
                ) : null}
              </p>
            ) : null}
            <p className="text-xs text-muted-foreground">
              {t(
                'projects.prospect.details_help',
                'Es crea una ordre en preparació. A Preparar ompliràs el full de preus, la plantilla i emetràs el pressupost amb la formalització ja triada.',
              )}
            </p>
            <p className="rounded-xl border border-border bg-muted/30 px-3 py-2 text-sm text-muted-foreground">
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
            <div className="space-y-1.5">
              <Label htmlFor="prospect-name">
                {t('projects.prospect.name_label', 'Nom de l\'ordre')}
              </Label>
              <Input
                id="prospect-name"
                value={name}
                onChange={(e) => setName(e.target.value)}
                autoFocus
              />
            </div>
          </div>
        )}

        <DialogFooter className="gap-2 sm:gap-0">
          {step === 'details' && !lockedClient ? (
            <Button
              type="button"
              variant="outline"
              onClick={() => setStep('contact')}
              disabled={busy}
            >
              {t('projects.quotes.wizard_back', 'Enrere')}
            </Button>
          ) : onBack ? (
            <Button type="button" variant="outline" onClick={onBack} disabled={busy}>
              {t('projects.quotes.wizard_back', 'Enrere')}
            </Button>
          ) : (
            <Button variant="outline" onClick={() => onOpenChange(false)} disabled={busy}>
              {t('common:cancel', 'Cancel·lar')}
            </Button>
          )}
          {step === 'details' ? (
            <Button
              onClick={() => void handleCreate()}
              disabled={busy || !name.trim() || !effectiveClientId}
            >
              {busy
                ? t('common:saving', 'Creant…')
                : t('projects.prospect.submit', 'Crear ordre i preparar')}
            </Button>
          ) : null}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
