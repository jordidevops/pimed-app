import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'

// ─── Types ────────────────────────────────────────────────────────────────────

export type Theme = 'light' | 'dark' | 'system'

export interface ColorPreset {
  id: string
  label: string
  /** HSL values without hsl(), e.g. "263.4 70% 50.4%" */
  primary: string
  primaryForeground: string
  /** CSS color for the swatch */
  swatch: string
}

export interface RadiusPreset {
  id: string
  label: string
  value: string
}

// ─── Presets ──────────────────────────────────────────────────────────────────

export const COLOR_PRESETS: ColorPreset[] = [
  {
    id: 'slate',
    label: 'Pissarra',
    primary: '222.2 47.4% 11.2%',
    primaryForeground: '210 40% 98%',
    swatch: '#1e293b',
  },
  {
    id: 'violet',
    label: 'Violeta',
    primary: '263.4 70% 50.4%',
    primaryForeground: '210 40% 98%',
    swatch: '#7c3aed',
  },
  {
    id: 'rose',
    label: 'Rosa',
    primary: '346.8 77.5% 49.8%',
    primaryForeground: '355.7 100% 97.3%',
    swatch: '#e11d48',
  },
  {
    id: 'orange',
    label: 'Taronja',
    primary: '24.6 95% 53.1%',
    primaryForeground: '60 9.1% 97.8%',
    swatch: '#f97316',
  },
]

export const RADIUS_PRESETS: RadiusPreset[] = [
  { id: 'none', label: 'Cap',     value: '0rem' },
  { id: 'sm',   label: 'Petit',   value: '0.3rem' },
  { id: 'md',   label: 'Mitjà',   value: '0.5rem' },
  { id: 'lg',   label: 'Gran',    value: '1rem' },
  { id: 'full', label: 'Rodó',    value: '1.5rem' },
]

// ─── DOM helpers ──────────────────────────────────────────────────────────────

function applyTheme(theme: Theme) {
  const root = document.documentElement
  const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches
  if (theme === 'dark' || (theme === 'system' && prefersDark)) {
    root.classList.add('dark')
  } else {
    root.classList.remove('dark')
  }
}

function resolveIsDark(theme: Theme): boolean {
  if (theme === 'dark') return true
  if (theme === 'light') return false
  return window.matchMedia('(prefers-color-scheme: dark)').matches
}

function applyColor(preset: ColorPreset, dark: boolean) {
  const root = document.documentElement
  const p   = dark ? preset.primaryForeground : preset.primary
  const pFg = dark ? preset.primary           : preset.primaryForeground
  root.style.setProperty('--primary', p)
  root.style.setProperty('--primary-foreground', pFg)
  root.style.setProperty('--ring', p)
}

function applyRadius(value: string) {
  document.documentElement.style.setProperty('--radius', value)
}

// ─── Context ──────────────────────────────────────────────────────────────────

interface ThemeContextValue {
  theme: Theme
  setTheme: (t: Theme) => void
  colorPresetId: string
  setColorPresetId: (id: string) => void
  radiusId: string
  setRadiusId: (id: string) => void
}

const ThemeContext = createContext<ThemeContextValue | null>(null)

// ─── Provider ────────────────────────────────────────────────────────────────

export function ThemeProvider({ children }: { children: ReactNode }) {
  const [theme, setThemeState] = useState<Theme>(
    () => (localStorage.getItem('theme') as Theme | null) ?? 'system',
  )
  const [colorPresetId, setColorPresetIdState] = useState<string>(
    () => localStorage.getItem('color-preset') ?? 'slate',
  )
  const [radiusId, setRadiusIdState] = useState<string>(
    () => localStorage.getItem('radius-preset') ?? 'md',
  )

  // Apply saved preferences on first mount
  useEffect(() => {
    const preset = COLOR_PRESETS.find((p) => p.id === colorPresetId) ?? COLOR_PRESETS[0]
    const radius = RADIUS_PRESETS.find((r) => r.id === radiusId) ?? RADIUS_PRESETS[2]
    applyTheme(theme)
    applyColor(preset, resolveIsDark(theme))
    applyRadius(radius.value)
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

  // Re-apply when system preference changes (only while theme === 'system')
  useEffect(() => {
    if (theme !== 'system') return
    const mq = window.matchMedia('(prefers-color-scheme: dark)')
    const handler = () => {
      applyTheme('system')
      const preset = COLOR_PRESETS.find((p) => p.id === colorPresetId) ?? COLOR_PRESETS[0]
      applyColor(preset, resolveIsDark('system'))
    }
    mq.addEventListener('change', handler)
    return () => mq.removeEventListener('change', handler)
  }, [theme, colorPresetId])

  const setTheme = (t: Theme) => {
    setThemeState(t)
    localStorage.setItem('theme', t)
    applyTheme(t)
    const preset = COLOR_PRESETS.find((p) => p.id === colorPresetId) ?? COLOR_PRESETS[0]
    applyColor(preset, resolveIsDark(t))
  }

  const setColorPresetId = (id: string) => {
    setColorPresetIdState(id)
    localStorage.setItem('color-preset', id)
    const preset = COLOR_PRESETS.find((p) => p.id === id) ?? COLOR_PRESETS[0]
    applyColor(preset, resolveIsDark(theme))
  }

  const setRadiusId = (id: string) => {
    setRadiusIdState(id)
    localStorage.setItem('radius-preset', id)
    const radius = RADIUS_PRESETS.find((r) => r.id === id) ?? RADIUS_PRESETS[2]
    applyRadius(radius.value)
  }

  return (
    <ThemeContext.Provider value={{ theme, setTheme, colorPresetId, setColorPresetId, radiusId, setRadiusId }}>
      {children}
    </ThemeContext.Provider>
  )
}

// ─── Hook ─────────────────────────────────────────────────────────────────────

export function useTheme() {
  const ctx = useContext(ThemeContext)
  if (!ctx) throw new Error('useTheme must be used within ThemeProvider')
  return ctx
}
