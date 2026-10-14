import { useTranslation } from 'react-i18next'
import { Check, ChevronRight } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from '@/components/ui/sheet'
import { cn } from '@/lib/utils'
import { useState } from 'react'

export type PolicyChoiceOption = {
  value: string
  label: string
  help: string
  implication: string
}

type FieldPolicyChoiceSheetProps = {
  open: boolean
  onOpenChange: (open: boolean) => void
  title: string
  description?: string
  value: string
  options: PolicyChoiceOption[]
  disabled?: boolean
  onSelect: (value: string) => void | Promise<void>
}

export function FieldPolicyChoiceSheet({
  open,
  onOpenChange,
  title,
  description,
  value,
  options,
  disabled,
  onSelect,
}: FieldPolicyChoiceSheetProps) {
  const { t } = useTranslation('field-service')
  const [busy, setBusy] = useState(false)

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent side="right" className="flex w-full flex-col gap-0 p-0 sm:max-w-lg">
        <SheetHeader className="border-b border-border px-4 py-3 text-left">
          <SheetTitle>{title}</SheetTitle>
          {description ? <SheetDescription>{description}</SheetDescription> : null}
        </SheetHeader>
        <div className="min-h-0 flex-1 space-y-2 overflow-y-auto p-4">
          {options.map((option) => {
            const selected = option.value === value
            return (
              <button
                key={option.value}
                type="button"
                disabled={disabled || busy}
                onClick={() => {
                  if (selected || disabled) {
                    onOpenChange(false)
                    return
                  }
                  setBusy(true)
                  void Promise.resolve(onSelect(option.value))
                    .then(() => onOpenChange(false))
                    .finally(() => setBusy(false))
                }}
                className={cn(
                  'w-full rounded-xl border px-3 py-3 text-left transition',
                  selected
                    ? 'border-primary bg-primary/10'
                    : 'border-border hover:border-primary/40 hover:bg-accent/40',
                  (disabled || busy) && 'opacity-60',
                )}
              >
                <span className="flex items-start justify-between gap-2">
                  <span className="font-semibold text-foreground">{option.label}</span>
                  {selected ? <Check className="h-4 w-4 shrink-0 text-primary" /> : null}
                </span>
                <span className="mt-1 block text-sm text-muted-foreground">{option.help}</span>
                <span className="mt-1.5 block text-xs text-foreground/80">{option.implication}</span>
              </button>
            )
          })}
        </div>
        {disabled ? (
          <p className="border-t border-border px-4 py-3 text-xs text-muted-foreground">
            {t(
              'policy.locked_after_report',
              'No es pot canviar després de publicar l’informe al client.',
            )}
          </p>
        ) : null}
      </SheetContent>
    </Sheet>
  )
}

type FieldPolicyChoiceRowProps = {
  visitIntent: string
  commercialRegime: string
  serviceMode: string
  disabled?: boolean
  onVisitIntent: (value: string) => Promise<void>
  onCommercialRegime: (value: string) => Promise<void>
  onServiceMode: (value: string) => Promise<void>
}

export function FieldPolicyChoiceRow({
  visitIntent,
  commercialRegime,
  serviceMode,
  disabled,
  onVisitIntent,
  onCommercialRegime,
  onServiceMode,
}: FieldPolicyChoiceRowProps) {
  const { t } = useTranslation('field-service')
  const [openKey, setOpenKey] = useState<'intent' | 'regime' | 'mode' | null>(null)

  const intentOptions: PolicyChoiceOption[] = [
    {
      value: 'generic',
      label: t('intent.generic', 'Genèrica'),
      help: t(
        'intent.generic_help',
        'Visita habitual de servei sense un tipus especial.',
      ),
      implication: t(
        'intent.generic_implication',
        'No implica checklist ni flux d’inspecció/correctiva per defecte.',
      ),
    },
    {
      value: 'inspection',
      label: t('intent.inspection', 'Inspecció'),
      help: t(
        'intent.inspection_help',
        'Revisió o diagnosi (p.ex. manteniment preventiu / avaluació).',
      ),
      implication: t(
        'intent.inspection_implication',
        'Ajuda a etiquetar la feina i plantilles orientades a inspecció.',
      ),
    },
    {
      value: 'corrective',
      label: t('intent.corrective', 'Correctiva'),
      help: t(
        'intent.corrective_help',
        'Intervenció per reparar o corregir una avaria o desviació.',
      ),
      implication: t(
        'intent.corrective_implication',
        'Útil per distingir correctives de visites rutinàries o d’inspecció.',
      ),
    },
  ]

  const regimeOptions: PolicyChoiceOption[] = [
    {
      value: 'contractual',
      label: t('regime.contractual', 'Contractual'),
      help: t(
        'regime.contractual_help',
        'Client amb relació B2B / contracte (no tractament de consumidor).',
      ),
      implication: t(
        'regime.contractual_implication',
        'Fluxos comercials i autorització segueixen el règim contractual.',
      ),
    },
    {
      value: 'consumer',
      label: t('regime.consumer', 'Consumidor'),
      help: t(
        'regime.consumer_help',
        'Particular o consumidor final (proteccions i tracte específic).',
      ),
      implication: t(
        'regime.consumer_implication',
        'Pot afectar com es presenta i es formalitza el pressupost.',
      ),
    },
  ]

  const modeOptions: PolicyChoiceOption[] = [
    {
      value: 'execute',
      label: t('service_mode.execute', 'Execució'),
      help: t(
        'service_mode.execute_help',
        'Visita per fer la feina autoritzada (reparar, instal·lar, mantenir).',
      ),
      implication: t(
        'service_mode.execute_implication',
        'Cal autorització comercial segons la política del tenant abans de treballar.',
      ),
    },
    {
      value: 'assessment',
      label: t('service_mode.assessment', 'Avaluació'),
      help: t(
        'service_mode.assessment_help',
        'Visita per valorar i preparar pressupost des d’oficina.',
      ),
      implication: t(
        'service_mode.assessment_implication',
        'No exigeix pack de preus ni el mateix bloqueig d’autorització que l’execució.',
      ),
    },
  ]

  const chips = [
    {
      key: 'intent' as const,
      label: t('policy.intent_chip', 'Intent'),
      valueLabel:
        intentOptions.find((o) => o.value === visitIntent)?.label ?? visitIntent,
    },
    {
      key: 'regime' as const,
      label: t('policy.regime_chip', 'Règim'),
      valueLabel:
        regimeOptions.find((o) => o.value === commercialRegime)?.label ??
        commercialRegime,
    },
    {
      key: 'mode' as const,
      label: t('policy.mode_chip', 'Mode'),
      valueLabel:
        modeOptions.find((o) => o.value === serviceMode)?.label ?? serviceMode,
    },
  ]

  return (
    <>
      <div className="flex flex-wrap gap-2">
        {chips.map((chip) => (
          <Button
            key={chip.key}
            type="button"
            size="sm"
            variant="outline"
            className="h-8 gap-1 px-2.5 text-xs"
            disabled={!!disabled}
            onClick={() => setOpenKey(chip.key)}
          >
            <span className="text-muted-foreground">{chip.label}</span>
            <span className="font-medium">{chip.valueLabel}</span>
            <ChevronRight className="h-3.5 w-3.5 text-muted-foreground" />
          </Button>
        ))}
      </div>

      <FieldPolicyChoiceSheet
        open={openKey === 'intent'}
        onOpenChange={(open) => setOpenKey(open ? 'intent' : null)}
        title={t('policy.intent_title', 'Intenció de la visita')}
        description={t(
          'policy.intent_description',
          'Defineix el caràcter de la visita. Es pot canviar fins que es publiqui l’informe.',
        )}
        value={visitIntent || 'generic'}
        options={intentOptions}
        disabled={disabled}
        onSelect={onVisitIntent}
      />
      <FieldPolicyChoiceSheet
        open={openKey === 'regime'}
        onOpenChange={(open) => setOpenKey(open ? 'regime' : null)}
        title={t('policy.regime_title', 'Règim comercial')}
        description={t(
          'policy.regime_description',
          'Consumidor vs contractual: afecta el tracte comercial del pressupost.',
        )}
        value={commercialRegime || 'contractual'}
        options={regimeOptions}
        disabled={disabled}
        onSelect={onCommercialRegime}
      />
      <FieldPolicyChoiceSheet
        open={openKey === 'mode'}
        onOpenChange={(open) => setOpenKey(open ? 'mode' : null)}
        title={t('policy.mode_title', 'Mode de servei')}
        description={t(
          'policy.mode_description',
          'Execució fa la feina; avaluació prepara el pressupost sense el mateix pack.',
        )}
        value={serviceMode || 'execute'}
        options={modeOptions}
        disabled={disabled}
        onSelect={onServiceMode}
      />
    </>
  )
}
