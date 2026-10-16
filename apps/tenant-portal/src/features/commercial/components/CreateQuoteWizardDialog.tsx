import { useEffect, useState, type ReactNode } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import {
  CheckCircle2,
  FileCheck2,
  FileText,
  Files,
  Gauge,
  Workflow,
  Wrench,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { cn } from '@/lib/utils'
import { useTenant } from '@/contexts/TenantContext'
import { useEffectiveSettings } from '@/hooks/useSettings'
import {
  readExplicitFormalizationModeDefault,
  type FormalizationMode,
} from '../utils/deviationApprovalThreshold'
import {
  listActiveCommercialQuickFlows,
  type CommercialQuickFlowRow,
} from '../api/commercialQuickFlowsService'
import { CreateOrphanQuoteDialog } from './CreateOrphanQuoteDialog'
import { CreateProspectQuoteDialog } from './CreateProspectQuoteDialog'
import { CreateQuickQuoteDialog } from './CreateQuickQuoteDialog'
import { LaunchCommercialFlowDialog } from './LaunchCommercialFlowDialog'

export type QuoteWizardInitialType = 'orphan' | 'prospect' | 'quick' | 'flows'

type WizardStep = 'type' | 'formalization' | 'pick_flow' | QuoteWizardInitialType

interface CreateQuoteWizardDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  clientId?: string | null
  clientName?: string | null
  /** Preselect a branch (e.g. leads `?orphan=1`) and still ask formalization unless a tenant default exists. */
  initialType?: QuoteWizardInitialType | null
}

export function CreateQuoteWizardDialog({
  open,
  onOpenChange,
  clientId = null,
  clientName = null,
  initialType = null,
}: CreateQuoteWizardDialogProps) {
  const { t } = useTranslation(['projects', 'common'])
  const { activeTenant } = useTenant()
  const { data: effectiveSettings } = useEffectiveSettings({
    tenantId: activeTenant?.id ?? null,
  })
  const formalizationDefault = readExplicitFormalizationModeDefault(effectiveSettings)

  const [step, setStep] = useState<WizardStep>('type')
  const [selected, setSelected] = useState<QuoteWizardInitialType | null>(null)
  const [formalization, setFormalization] = useState<FormalizationMode | null>(null)
  const [forceAskFormalization, setForceAskFormalization] = useState(false)
  const [selectedFlowId, setSelectedFlowId] = useState<string | null>(null)
  const [launchFlow, setLaunchFlow] = useState<CommercialQuickFlowRow | null>(null)

  const { data: activeFlows = [] } = useQuery({
    queryKey: ['commercial_quick_flows_active', activeTenant?.id],
    queryFn: listActiveCommercialQuickFlows,
    enabled: open && !!activeTenant,
  })

  useEffect(() => {
    if (!open) {
      setStep('type')
      setSelected(null)
      setFormalization(null)
      setForceAskFormalization(false)
      setSelectedFlowId(null)
      setLaunchFlow(null)
      return
    }
    if (
      initialType === 'orphan' ||
      initialType === 'prospect' ||
      initialType === 'quick'
    ) {
      setSelected(initialType)
      if (formalizationDefault && !forceAskFormalization) {
        setFormalization(formalizationDefault)
        setStep(initialType)
      } else {
        setFormalization(null)
        setStep('formalization')
      }
      return
    }
    if (initialType === 'flows') {
      setSelected('flows')
      setStep('pick_flow')
      return
    }
    setStep('type')
    setSelected(null)
    setFormalization(null)
    setForceAskFormalization(false)
    setSelectedFlowId(null)
    setLaunchFlow(null)
  }, [open, initialType, formalizationDefault, forceAskFormalization])

  function handleOpenChange(next: boolean) {
    onOpenChange(next)
  }

  function chooseType(next: QuoteWizardInitialType) {
    setSelected(next)
    if (next === 'flows') {
      setStep('pick_flow')
      return
    }
    if (formalizationDefault && !forceAskFormalization) {
      setFormalization(formalizationDefault)
      setStep(next)
      return
    }
    setStep('formalization')
  }

  function chooseFormalization(next: FormalizationMode) {
    if (!selected || selected === 'flows') return
    setFormalization(next)
    setStep(selected)
  }

  function changeFormalization() {
    setForceAskFormalization(true)
    setFormalization(null)
    setStep('formalization')
  }

  if (step === 'orphan' && formalization) {
    return (
      <CreateOrphanQuoteDialog
        open={open}
        onOpenChange={handleOpenChange}
        clientId={clientId}
        clientName={clientName}
        formalizationMode={formalization}
        onBack={() => {
          if (formalizationDefault && !forceAskFormalization) {
            if (initialType) {
              handleOpenChange(false)
              return
            }
            setStep('type')
            setFormalization(null)
            return
          }
          setStep('formalization')
        }}
        onChangeFormalization={formalizationDefault ? changeFormalization : undefined}
      />
    )
  }

  if (step === 'prospect' && formalization) {
    return (
      <CreateProspectQuoteDialog
        open={open}
        onOpenChange={handleOpenChange}
        clientId={clientId}
        clientName={clientName}
        formalizationMode={formalization}
        onBack={() => {
          if (formalizationDefault && !forceAskFormalization) {
            if (initialType) {
              handleOpenChange(false)
              return
            }
            setStep('type')
            setFormalization(null)
            return
          }
          setStep('formalization')
        }}
        onChangeFormalization={formalizationDefault ? changeFormalization : undefined}
      />
    )
  }

  if (step === 'quick' && formalization) {
    return (
      <CreateQuickQuoteDialog
        open={open}
        onOpenChange={handleOpenChange}
        clientId={clientId}
        clientName={clientName}
        formalizationMode={formalization}
        onBack={() => {
          if (formalizationDefault && !forceAskFormalization) {
            if (initialType) {
              handleOpenChange(false)
              return
            }
            setStep('type')
            setFormalization(null)
            return
          }
          setStep('formalization')
        }}
        onChangeFormalization={formalizationDefault ? changeFormalization : undefined}
      />
    )
  }

  if (launchFlow) {
    return (
      <LaunchCommercialFlowDialog
        open={open}
        onOpenChange={handleOpenChange}
        flow={launchFlow}
        clientId={clientId}
        clientName={clientName}
        onBack={() => {
          setLaunchFlow(null)
          setStep('pick_flow')
        }}
      />
    )
  }

  const onFormalization = step === 'formalization'
  const onPickFlow = step === 'pick_flow'

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogContent className="sm:max-w-xl">
        <DialogHeader>
          <DialogTitle>
            {onFormalization
              ? t('projects.quotes.wizard_formalization_title', 'Formalització')
              : onPickFlow
                ? t('projects.flows.pick_title', 'Tria un flux')
                : t('projects.quotes.wizard_title', 'Nou pressupost')}
          </DialogTitle>
          <DialogDescription>
            {onFormalization
              ? t(
                  'projects.quotes.wizard_formalization_help',
                  'Tria com es tanca l’encàrrec. És el mateix per a les dues maneres de començar. Doble clic també continua.',
                )
              : onPickFlow
                ? t(
                    'projects.flows.pick_help',
                    'Els fluxos actius ja porten plantilla, formalització i font (calculadora o hàbit).',
                  )
                : t(
                    'projects.quotes.wizard_help',
                    'Tria com vols començar. Doble clic a una opció continua.',
                  )}
          </DialogDescription>
        </DialogHeader>

        {onFormalization ? (
          <div className="grid gap-3 sm:grid-cols-2">
            <TypeCard
              selected={formalization === 'signed_quote'}
              onSelect={() => setFormalization('signed_quote')}
              onOpen={() => chooseFormalization('signed_quote')}
              icon={<FileCheck2 className="h-8 w-8 text-foreground" aria-hidden />}
              title={t(
                'projects.quotes.wizard_formalization_signed_title',
                'El pressupost és el contracte',
              )}
              description={t(
                'projects.commercial.formalization_signed_help',
                'El pressupost acceptat és l’encàrrec. No es generarà un segon document.',
              )}
            />
            <TypeCard
              selected={formalization === 'separate_agreement'}
              onSelect={() => setFormalization('separate_agreement')}
              onOpen={() => chooseFormalization('separate_agreement')}
              icon={<Files className="h-8 w-8 text-foreground" aria-hidden />}
              title={t(
                'projects.quotes.wizard_formalization_separate_title',
                'Pressupost i contracte a part',
              )}
              description={t(
                'projects.commercial.formalization_separate_help',
                'El pressupost queda com a annex. El contracte es prepara després, amb una segona firma. Acceptar no el crea sol.',
              )}
            />
          </div>
        ) : onPickFlow ? (
          <div className="max-h-72 space-y-2 overflow-y-auto">
            {activeFlows.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                {t(
                  'projects.flows.pick_empty',
                  'No hi ha fluxos actius. Crea’n un a Comercial → Fluxos comercials.',
                )}
              </p>
            ) : (
              activeFlows.map((flow) => (
                <button
                  key={flow.id}
                  type="button"
                  className={cn(
                    'flex w-full flex-col gap-1 rounded-xl border-2 p-4 text-left transition-colors',
                    'hover:border-primary/60 hover:bg-muted/40',
                    selectedFlowId === flow.id
                      ? 'border-primary bg-primary/5'
                      : 'border-border bg-card',
                  )}
                  onClick={() => setSelectedFlowId(flow.id)}
                  onDoubleClick={() => {
                    setSelectedFlowId(flow.id)
                    setLaunchFlow(flow)
                  }}
                >
                  <span className="text-sm font-semibold">{flow.name}</span>
                  {flow.description ? (
                    <span className="text-xs text-muted-foreground">{flow.description}</span>
                  ) : null}
                  <span className="text-[10px] uppercase text-muted-foreground">
                    {flow.calculator_definition_id
                      ? t('projects.flows.source_calc', 'Calculadora')
                      : t('projects.flows.source_habit', 'Hàbit')}
                    {' · '}
                    {flow.formalization_mode === 'signed_quote'
                      ? t('projects.flows.mode_signed', 'Pressupost = contracte')
                      : t('projects.flows.mode_separate', 'Contracte a part')}
                  </span>
                </button>
              ))
            )}
          </div>
        ) : (
          <div className="grid gap-3 sm:grid-cols-2">
            <TypeCard
              selected={selected === 'orphan'}
              onSelect={() => setSelected('orphan')}
              onOpen={() => chooseType('orphan')}
              icon={<FileText className="h-8 w-8 text-foreground" aria-hidden />}
              title={t('projects.quotes.wizard_type_orphan_title', 'Només pressupost')}
              description={t(
                'projects.quotes.wizard_type_orphan_help',
                'Envies una oferta sense obrir ordre. L’ordre (si cal) es crea quan el client accepta.',
              )}
            />
            <TypeCard
              selected={selected === 'prospect'}
              onSelect={() => setSelected('prospect')}
              onOpen={() => chooseType('prospect')}
              icon={<Wrench className="h-8 w-8 text-foreground" aria-hidden />}
              title={t('projects.quotes.wizard_type_prospect_title', 'Feina amb pressupost')}
              description={t(
                'projects.quotes.wizard_type_prospect_help',
                'Creem una ordre en preparació: omples el full de preus allà i després emets el pressupost.',
              )}
            />
            <TypeCard
              selected={selected === 'quick'}
              onSelect={() => setSelected('quick')}
              onOpen={() => chooseType('quick')}
              icon={<Gauge className="h-8 w-8 text-foreground" aria-hidden />}
              title={t('projects.quotes.wizard_type_quick_title', 'Ràpid')}
              description={t(
                'projects.quotes.wizard_type_quick_help',
                'Client, calculadora i emetre. Sense obrir ordre.',
              )}
            />
            <TypeCard
              selected={selected === 'flows'}
              onSelect={() => setSelected('flows')}
              onOpen={() => chooseType('flows')}
              icon={<Workflow className="h-8 w-8 text-foreground" aria-hidden />}
              title={t('projects.flows.wizard_card_title', 'Fluxos comercials')}
              description={t(
                'projects.flows.wizard_card_help',
                'Llança un flux preconfigurat (plantilla, formalització i font).',
              )}
            />
          </div>
        )}

        {!onFormalization && !onPickFlow ? (
          <p className="text-xs text-muted-foreground">
            {t(
              'projects.quotes.wizard_existing_order_note',
              'Si ja tens una ordre oberta, obre-la i emet el pressupost des de Preparar.',
            )}
          </p>
        ) : null}

        <DialogFooter>
          {onFormalization || onPickFlow ? (
            <Button
              variant="outline"
              onClick={() => {
                if (onPickFlow && initialType === 'flows') {
                  handleOpenChange(false)
                  return
                }
                setStep('type')
                setFormalization(null)
                setForceAskFormalization(false)
                setSelectedFlowId(null)
                setLaunchFlow(null)
                setSelected(null)
              }}
            >
              {t('projects.quotes.wizard_back', 'Enrere')}
            </Button>
          ) : (
            <Button variant="outline" onClick={() => handleOpenChange(false)}>
              {t('common:cancel', 'Cancel·lar')}
            </Button>
          )}
          <Button
            disabled={
              onFormalization
                ? !formalization
                : onPickFlow
                  ? !selectedFlowId
                  : !selected
            }
            onClick={() => {
              if (onFormalization) {
                if (formalization) chooseFormalization(formalization)
                return
              }
              if (onPickFlow) {
                const flow = activeFlows.find((f) => f.id === selectedFlowId) ?? null
                if (flow) setLaunchFlow(flow)
                return
              }
              if (selected) chooseType(selected)
            }}
          >
            {t('projects.quotes.wizard_continue', 'Continuar')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function TypeCard({
  selected,
  onSelect,
  onOpen,
  icon,
  title,
  description,
}: {
  selected: boolean
  onSelect: () => void
  /** Double-click: same as Continuar with this card. */
  onOpen: () => void
  icon: ReactNode
  title: string
  description: string
}) {
  return (
    <button
      type="button"
      onClick={onSelect}
      onDoubleClick={(event) => {
        event.preventDefault()
        onOpen()
      }}
      aria-pressed={selected}
      className={cn(
        'relative flex select-none flex-col items-start gap-3 rounded-2xl border-2 p-5 text-left transition-colors',
        'hover:border-primary/60 hover:bg-muted/40 focus:outline-none focus-visible:ring-2 focus-visible:ring-ring',
        selected
          ? 'border-primary bg-primary/5 shadow-sm'
          : 'border-border bg-card',
      )}
    >
      {selected ? (
        <CheckCircle2 className="absolute top-3 right-3 h-5 w-5 text-primary" aria-hidden />
      ) : null}
      <span className="flex h-12 w-12 items-center justify-center rounded-xl bg-muted">
        {icon}
      </span>
      <span className="text-sm font-semibold text-foreground">{title}</span>
      <span className="text-xs text-muted-foreground leading-snug">{description}</span>
    </button>
  )
}
