import { useTranslation } from 'react-i18next'
import { Popover, PopoverTrigger, PopoverContent } from '@/components/ui/popover'
import { Button } from '@/components/ui/button'
import { useTheme, type Theme } from '../contexts/ThemeContext'
import { cn } from '@/lib/utils'

function SunIcon() {
  return (
    <svg className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} aria-hidden>
      <circle cx="12" cy="12" r="4" />
      <path strokeLinecap="round" d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41" />
    </svg>
  )
}

function MoonIcon() {
  return (
    <svg className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} aria-hidden>
      <path strokeLinecap="round" strokeLinejoin="round" d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
    </svg>
  )
}

function SystemIcon() {
  return (
    <svg className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} aria-hidden>
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

export function ThemeToggle() {
  const { t } = useTranslation('common')
  const { theme, setTheme } = useTheme()

  const current = THEME_OPTIONS.find((o) => o.value === theme) ?? THEME_OPTIONS[2]

  return (
    <Popover>
      <PopoverTrigger asChild>
        <Button
          variant="ghost"
          size="sm"
          className="gap-2 text-muted-foreground hover:text-foreground"
          aria-label={t('theme.toggle_label', "Canviar aparença")}
        >
          {current.icon}
          <span className="text-xs">{t(current.labelKey, current.labelFallback)}</span>
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-40 p-1" align="start" side="top">
        {THEME_OPTIONS.map((opt) => (
          <button
            key={opt.value}
            onClick={() => setTheme(opt.value)}
            className={cn(
              'flex w-full items-center gap-2.5 rounded-sm px-2 py-1.5 text-sm transition-colors',
              theme === opt.value
                ? 'bg-accent text-accent-foreground font-medium'
                : 'text-muted-foreground hover:bg-accent hover:text-accent-foreground',
            )}
          >
            {opt.icon}
            {t(opt.labelKey, opt.labelFallback)}
          </button>
        ))}
      </PopoverContent>
    </Popover>
  )
}
