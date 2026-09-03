/**
 * Estructura del theme_config del portal públic.
 * Reflecteix el contrat definit a docs/V2/public-portal-content-v1-v2.md
 */

export interface ThemeHeader {
  show_nav?: boolean
  show_language_switcher?: boolean
  show_contact_button?: boolean
  contact_button_label?: string
  contact_button_url?: string
}

export interface ThemeFooter {
  copyright_text?: string
  show_links?: boolean
  social_links?: {
    twitter?: string
    linkedin?: string
    instagram?: string
    facebook?: string
  }
}

export interface ThemeColors {
  primary?: string
  background?: string
  text?: string
}

export interface ThemeBranding {
  logo_url?: string
  logo_alt?: string
}

export interface ThemeConfig {
  header?: ThemeHeader
  footer?: ThemeFooter
  colors?: ThemeColors
  branding?: ThemeBranding
}

export function parseThemeConfig(raw: unknown): ThemeConfig {
  if (!raw || typeof raw !== 'object') return {}
  return raw as ThemeConfig
}
