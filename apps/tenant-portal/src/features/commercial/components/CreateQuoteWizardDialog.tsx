import { useEffect, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { CheckCircle2, FileText, Wrench } from 'lucide-react'
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
import { CreateOrphanQuoteDialog } from './CreateOrphanQuoteDialog'
import { CreateProspectQuoteDialog } from './CreateProspectQuoteDialog'

export type QuoteWizardInitialType = 'orphan' | 'prospect'

type WizardStep = 'type' | QuoteWizardInitialType

interface CreateQuoteWizardDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  clientId?: string | null
  clientName?: string | null
  /** Skip type step and open a branch (e.g. leads `?orphan=1`). */
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

  useEffect(() => {
    if (!open) {
      setStep('type')
      setSelected(null)
      return
    }
    if (initialType === 'orphan' || initialType === 'prospect') {
      setSelected(initialType)
      setStep(initialType)
      return
    }
    setStep('type')
    setSelected(null)
  }, [open, initialType])

  function handleOpenChange(next: boolean) {
    onOpenChange(next)
  }

  function goBackToType() {
    setStep('type')
    setSelected(null)
  }

  if (step === 'orphan') {
    return (
      <CreateOrphanQuoteDialog
        open={open}
        onOpenChange={handleOpenChange}
        clientId={clientId}
        clientName={clientName}
        onBack={goBackToType}
      />
    )
  }

  if (step === 'prospect') {
    return (
      <CreateProspectQuoteDialog
        open={open}
        onOpenChange={handleOpenChange}
        clientId={clientId}
        clientName={clientName}
        onBack={goBackToType}
      />
    )
  }

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogContent className="sm:max-w-xl">
        <DialogHeader>
          <DialogTitle>
            {t('projects.quotes.wizard_title', 'Nou pressupost')}
          </DialogTitle>
          <DialogDescription>
            {t(
              'projects.quotes.wizard_help',
              'Tria com vols començar. Pots canviar-ho més endavant tornant enrere.',
            )}
          </DialogDescription>
        </DialogHeader>

        <div className="grid gap-3 sm:grid-cols-2">
          <TypeCard
            selected={selected === 'orphan'}
            onSelect={() => setSelected('orphan')}
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
            icon={<Wrench className="h-8 w-8 text-foreground" aria-hidden />}
            title={t('projects.quotes.wizard_type_prospect_title', 'Feina amb pressupost')}
            description={t(
              'projects.quotes.wizard_type_prospect_help',
              'Creem una ordre en preparació: omples el full de preus allà i després emets. La formalització es tria a Preparar.',
            )}
          />
        </div>

        <p className="text-xs text-muted-foreground">
          {t(
            'projects.quotes.wizard_existing_order_note',
            'Si ja tens una ordre oberta, obre-la i emet el pressupost des de Preparar.',
          )}
        </p>

        <DialogFooter>
          <Button variant="outline" onClick={() => handleOpenChange(false)}>
            {t('common:cancel', 'Cancel·lar')}
          </Button>
          <Button
            disabled={!selected}
            onClick={() => {
              if (selected) setStep(selected)
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
  icon,
  title,
  description,
}: {
  selected: boolean
  onSelect: () => void
  icon: ReactNode
  title: string
  description: string
}) {
  return (
    <button
      type="button"
      onClick={onSelect}
      aria-pressed={selected}
      className={cn(
        'relative flex flex-col items-start gap-3 rounded-2xl border-2 p-5 text-left transition-colors',
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
