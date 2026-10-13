import { useEffect, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { CheckCircle2, FileCheck2, FileText, Files, Wrench } from 'lucide-react'
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
import type { FormalizationMode } from '../utils/deviationApprovalThreshold'
import { CreateOrphanQuoteDialog } from './CreateOrphanQuoteDialog'
import { CreateProspectQuoteDialog } from './CreateProspectQuoteDialog'

export type QuoteWizardInitialType = 'orphan' | 'prospect'

type WizardStep = 'type' | 'formalization' | QuoteWizardInitialType

interface CreateQuoteWizardDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  clientId?: string | null
  clientName?: string | null
  /** Preselect a branch (e.g. leads `?orphan=1`) and still ask formalization. */
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
  const [step, setStep] = useState<WizardStep>('type')
  const [selected, setSelected] = useState<QuoteWizardInitialType | null>(null)
  const [formalization, setFormalization] = useState<FormalizationMode | null>(null)

  useEffect(() => {
    if (!open) {
      setStep('type')
      setSelected(null)
      setFormalization(null)
      return
    }
    if (initialType === 'orphan' || initialType === 'prospect') {
      setSelected(initialType)
      setFormalization(null)
      setStep('formalization')
      return
    }
    setStep('type')
    setSelected(null)
    setFormalization(null)
  }, [open, initialType])

  function handleOpenChange(next: boolean) {
    onOpenChange(next)
  }

  function chooseType(next: QuoteWizardInitialType) {
    setSelected(next)
    setStep('formalization')
  }

  function chooseFormalization(next: FormalizationMode) {
    if (!selected) return
    setFormalization(next)
    setStep(selected)
  }

  if (step === 'orphan' && formalization) {
    return (
      <CreateOrphanQuoteDialog
        open={open}
        onOpenChange={handleOpenChange}
        clientId={clientId}
        clientName={clientName}
        formalizationMode={formalization}
        onBack={() => setStep('formalization')}
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
        onBack={() => setStep('formalization')}
      />
    )
  }

  const onFormalization = step === 'formalization'

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogContent className="sm:max-w-xl">
        <DialogHeader>
          <DialogTitle>
            {onFormalization
              ? t('projects.quotes.wizard_formalization_title', 'Formalització')
              : t('projects.quotes.wizard_title', 'Nou pressupost')}
          </DialogTitle>
          <DialogDescription>
            {onFormalization
              ? t(
                  'projects.quotes.wizard_formalization_help',
                  'Tria com es tanca l’encàrrec. És el mateix per a les dues maneres de començar. Doble clic també continua.',
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
                'Envies una oferta. No s’obre cap ordre fins que el client accepti.',
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
                'Creem una ordre en preparació: omples el full de preus allà i després emets.',
              )}
            />
          </div>
        )}

        {!onFormalization ? (
          <p className="text-xs text-muted-foreground">
            {t(
              'projects.quotes.wizard_existing_order_note',
              'Si ja tens una ordre oberta, obre-la i emet el pressupost des de Preparar.',
            )}
          </p>
        ) : null}

        <DialogFooter>
          {onFormalization ? (
            <Button
              variant="outline"
              onClick={() => {
                if (initialType) {
                  handleOpenChange(false)
                  return
                }
                setStep('type')
                setFormalization(null)
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
            disabled={onFormalization ? !formalization : !selected}
            onClick={() => {
              if (onFormalization) {
                if (formalization) chooseFormalization(formalization)
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
