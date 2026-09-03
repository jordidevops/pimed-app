import * as React from 'react'
import { useTranslation } from 'react-i18next'
import { cn } from '@/lib/utils'
import { Input } from './input'

// ---------------------------------------------------------------------------
// SettingsInput
//
// Input de configuració jeràrquic. Mostra el valor del nivell actual i, quan
// està buit, exhibeix el valor heretat dels nivells superiors com a placeholder
// en cursiva grisa.
//
// Props:
//   value          — valor del nivell actual (pot ser undefined/null si no s'ha definit)
//   inheritedValue — valor resultat del merge dels nivells superiors (placeholder)
//   inheritedFrom  — nom del nivell d'origen (ex: "Empresa", "Sistema")
//   onChange       — callback quan l'usuari escriu un valor nou
//   onReset        — callback per esborrar el valor del nivell actual (torna a heretar)
//   type           — tipus d'input HTML (default: "text")
//   disabled       — desactiva l'input
//   className      — classes CSS addicionals
// ---------------------------------------------------------------------------

export interface SettingsInputProps
  extends Omit<React.ComponentProps<'input'>, 'value' | 'onChange'> {
  value?: string | null
  inheritedValue?: string | null
  inheritedFrom?: string
  onChange: (value: string | null) => void
  onReset?: () => void
}

const SettingsInput = React.forwardRef<HTMLInputElement, SettingsInputProps>(
  (
    {
      value,
      inheritedValue,
      inheritedFrom,
      onChange,
      onReset,
      className,
      disabled,
      ...props
    },
    ref,
  ) => {
    const { t } = useTranslation('settings')

    const isInherited = value === null || value === undefined || value === ''
    const inheritedLabel = inheritedFrom ?? t('settings.levels.system', 'Sistema')

    const placeholderText =
      inheritedValue != null
        ? `${inheritedValue} (${t('settings.inherited.label', 'Heretat')} de ${inheritedLabel})`
        : undefined

    return (
      <div className="relative w-full">
        <Input
          ref={ref}
          value={value ?? ''}
          onChange={(e) => {
            const newVal = e.target.value
            onChange(newVal === '' ? null : newVal)
          }}
          placeholder={placeholderText}
          disabled={disabled}
          className={cn(
            isInherited && 'italic text-muted-foreground',
            className,
          )}
          title={
            isInherited && inheritedValue != null
              ? `${t('settings.inherited.tooltip', 'Aquest valor s\'hereta del nivell superior')}: ${inheritedValue}`
              : undefined
          }
          {...props}
        />
        {!isInherited && onReset && (
          <button
            type="button"
            onClick={onReset}
            disabled={disabled}
            aria-label={t('settings.reset', 'Restablir al valor heretat')}
            className="absolute right-2 top-1/2 -translate-y-1/2 text-xs text-muted-foreground hover:text-foreground disabled:opacity-40"
          >
            ↩
          </button>
        )}
      </div>
    )
  },
)

SettingsInput.displayName = 'SettingsInput'

export { SettingsInput }
