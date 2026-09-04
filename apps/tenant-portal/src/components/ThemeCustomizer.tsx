import { useTranslation } from 'react-i18next'
import { Popover, PopoverTrigger, PopoverContent } from '@/components/ui/popover'
import {
  useTheme,
  COLOR_PRESETS,
  RADIUS_PRESETS,
  type Theme,
} from '../contexts/ThemeContext'
import { cn } from '@/lib/utils'

function PaletteIcon() {
  return (
    <svg className="h-5 w-5 shrink-0" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.75} aria-hidden>
      <circle cx="12" cy="12" r="10" />
      <circle cx="8.5" cy="14.5" r="1.5" fill="currentColor" stroke="none" />
      <circle cx="12" cy="9" r="1.5" fill="currentColor" stroke="none" />
      <circle cx="15.5" cy="14.5" r="1.5" fill="currentColor" stroke="none" />
    </svg>
  )
}

function SunIcon() {
  return (
    <svg className="h-3.5 w-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} aria-hidden>
      <circle cx="12" cy="12" r="4" />
      <path strokeLinecap="round" d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41" />
    </svg>
  )
}

function MoonIcon() {
  return (
    <svg className="h-3.5 w-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} aria-hidden>
      <path strokeLinecap="round" strokeLinejoin="round" d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
    </svg>
  )
}

function SystemIcon() {
  return (
    <svg className="h-3.5 w-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} aria-hidden>
      <rect x="2" y="3" width="20" height="14" rx="2" />
      <path strokeLinecap="round" d="M8 21h8M12 17v4" />
    </svg>
  )
}

const THEME_OPTIONS: { value: Theme; icon: React.ReactNode; labelKey: string; labelFallback: string }[] = [
  { value: 'light',  icon: <SunIcon />,    labelKey: 'theme.light',  labelFallback: 'Clar' },
  { value: 'dark',   icon: <MoonIcon />,   labelKey: 'theme.dark',   labelFallback: 'Fosc' },
  { value: 'system', icon: <SystemIcon />, labelKey: 'theme.system', labelFallback: 'Sistema' },
]

export function ThemeCustomizer({
  className,
  label,
  showIcon = true,
}: {
  className?: string
  label?: string
  showIcon?: boolean
}) {
  const { t } = useTranslation('common')
  const { theme, setTheme, colorPresetId, setColorPresetId, radiusId, setRadiusId } = useTheme()
  const displayLabel = label ?? t('theme.customizer_label', 'Aparença')

  return (
    <Popover>
      <PopoverTrigger asChild>
        <button
          type="button"
            className={cn('tp-nav-item', className)}
          aria-label={displayLabel}
        >
          {showIcon ? <PaletteIcon /> : <span className="inline-block h-5 w-5 shrink-0" aria-hidden />}
          <span>{displayLabel}</span>
        </button>
      </PopoverTrigger>

      <PopoverContent className="w-64 space-y-4" align="start" side="top">
        {/* Mode */}
        <div>
          <p className="text-xs font-semibold uppercase tracking-wider text-muted-foreground mb-2">
            {t('theme.mode_label', 'Mode')}
          </p>
          <div className="flex gap-1">
            {THEME_OPTIONS.map((opt) => (
              <button
                key={opt.value}
                onClick={() => setTheme(opt.value)}
                className={cn(
                  'flex flex-1 flex-col items-center gap-1 rounded-md border px-2 py-2 text-xs transition-colors',
                  theme === opt.value
                    ? 'border-primary bg-primary text-primary-foreground font-medium'
                    : 'border-transparent text-muted-foreground hover:border-border hover:text-foreground',
                )}
                aria-pressed={theme === opt.value}
              >
                {opt.icon}
                <span>{t(opt.labelKey, opt.labelFallback)}</span>
              </button>
            ))}
          </div>
        </div>

        {/* Color */}
        <div>
          <p className="text-xs font-semibold uppercase tracking-wider text-muted-foreground mb-2">
            {t('theme.color_label', 'Color principal')}
          </p>
          <div className="flex gap-2 flex-wrap">
            {COLOR_PRESETS.map((preset) => (
              <button
                key={preset.id}
                onClick={() => setColorPresetId(preset.id)}
                title={preset.label}
                aria-pressed={colorPresetId === preset.id}
                className={cn(
                  'h-7 w-7 rounded-full ring-offset-background transition-all',
                  colorPresetId === preset.id
                    ? 'ring-2 ring-offset-2 ring-primary scale-110'
                    : 'hover:scale-105',
                )}
                style={{ backgroundColor: preset.swatch }}
                aria-label={preset.label}
              />
            ))}
          </div>
        </div>

        {/* Radius */}
        <div>
          <p className="text-xs font-semibold uppercase tracking-wider text-muted-foreground mb-2">
            {t('theme.radius_label', 'Radi de les vores')}
          </p>
          <div className="flex gap-1.5 flex-wrap">
            {RADIUS_PRESETS.map((r) => (
              <button
                key={r.id}
                onClick={() => setRadiusId(r.id)}
                aria-pressed={radiusId === r.id}
                className={cn(
                  'h-7 px-2 text-xs border transition-colors',
                  // Use a fixed border-radius here (not CSS var) so each button shows the actual shape
                  r.id === 'none' && 'rounded-none',
                  r.id === 'sm'   && 'rounded-sm',
                  r.id === 'md'   && 'rounded-md',
                  r.id === 'lg'   && 'rounded-lg',
                  r.id === 'full' && 'rounded-full',
                  radiusId === r.id
                    ? 'border-primary bg-primary text-primary-foreground font-medium'
                    : 'border-border text-muted-foreground hover:text-foreground hover:border-foreground/30',
                )}
              >
                {r.label}
              </button>
            ))}
          </div>
        </div>
      </PopoverContent>
    </Popover>
  )
}
