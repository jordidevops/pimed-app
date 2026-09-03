'use client'
import { useTranslation } from 'react-i18next'
import { useState, useRef, useEffect } from 'react'
import { usePatchPublicSiteTheme } from '../api/usePublicSiteMutations'
import { useTenant } from '../../../contexts/TenantContext'
import { useToast } from '../../../hooks/use-toast'
import { supabase } from '../../../lib/supabase'
import { Button } from '../../../components/ui/button'
import { Input } from '../../../components/ui/input'
import type { PublicSiteFullRow } from '../api/usePublicSite'
import type { Json } from '../../../types/database.types'

// ---------------------------------------------------------------------------
// Helpers de tipus locals (mirrors theme.ts del public-portal)
// ---------------------------------------------------------------------------
interface ThemeHeader {
  show_nav?: boolean
  show_language_switcher?: boolean
  show_contact_button?: boolean
  contact_button_label?: string
  contact_button_url?: string
}

interface ThemeFooter {
  copyright_text?: string
  social_links?: {
    twitter?: string
    linkedin?: string
    instagram?: string
    facebook?: string
  }
}

interface ThemeColors {
  primary?: string
}

interface ThemeBranding {
  logo_url?: string
}

interface ThemeConfig {
  header?: ThemeHeader
  footer?: ThemeFooter
  colors?: ThemeColors
  branding?: ThemeBranding
}

function parseTheme(raw: unknown): ThemeConfig {
  if (!raw || typeof raw !== 'object') return {}
  return raw as ThemeConfig
}

// ---------------------------------------------------------------------------
// Props
// ---------------------------------------------------------------------------
interface Props {
  site: PublicSiteFullRow
  tenantId: string
  canManage: boolean
}

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------
export function AppearanceEditor({ site, tenantId, canManage }: Props) {
  const { t } = useTranslation('public_portal')
  const { activeTenant } = useTenant()
  const { toast } = useToast()
  const theme = parseTheme(site.theme_config)

  const patchTheme = usePatchPublicSiteTheme(tenantId, site.id ?? '')

  // ---------- Branding state ----------
  const [logoUploading, setLogoUploading] = useState(false)
  const [logoError, setLogoError] = useState<string | null>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)

  // Re-inicialitza l'estat local quan canvia el theme_config del site
  // (p.ex. després d'un desar + refetch)
  useEffect(() => {
    const t = parseTheme(site.theme_config)
    setPrimaryColor(t.colors?.primary ?? '#6366f1')
    setHeader({
      show_nav: t.header?.show_nav !== false,
      show_language_switcher: t.header?.show_language_switcher !== false,
      show_contact_button: t.header?.show_contact_button ?? false,
      contact_button_label: t.header?.contact_button_label ?? '',
      contact_button_url: t.header?.contact_button_url ?? '',
    })
    setFooter({
      copyright_text: t.footer?.copyright_text ?? '',
      social_links: {
        twitter: t.footer?.social_links?.twitter ?? '',
        linkedin: t.footer?.social_links?.linkedin ?? '',
        instagram: t.footer?.social_links?.instagram ?? '',
        facebook: t.footer?.social_links?.facebook ?? '',
      },
    })
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [site.theme_config])

  async function handleLogoUpload(file: File) {
    if (!activeTenant?.id) return
    if (file.size > 2 * 1024 * 1024) {
      setLogoError(t('public_portal.appearance.logo_too_large', 'El logo supera els 2 MB.'))
      return
    }
    setLogoUploading(true)
    setLogoError(null)
    const ext = file.name.split('.').pop() ?? 'png'
    const path = `${activeTenant.id as string}/portal/logo.${ext}`
    const { error: uploadError } = await supabase.storage
      .from('public-assets')
      .upload(path, file, { upsert: true, contentType: file.type })
    if (uploadError) {
      setLogoError(uploadError.message)
      setLogoUploading(false)
      return
    }
    const { data: urlData } = supabase.storage.from('public-assets').getPublicUrl(path)
    try {
      await patchTheme.mutateAsync({ section: 'branding', patch: { logo_url: urlData.publicUrl } })
      toast({ title: t('public_portal.appearance.save_success', 'Logo desat correctament.') })
    } catch (err) {
      setLogoError(err instanceof Error ? err.message : t('public_portal.appearance.save_error', 'Error en desar.'))
    }
    setLogoUploading(false)
  }

  // ---------- Colors state ----------
  const [primaryColor, setPrimaryColor] = useState(theme.colors?.primary ?? '#6366f1')

  async function handleColorSave() {
    try {
      await patchTheme.mutateAsync({ section: 'colors', patch: { primary: primaryColor } })
      toast({ title: t('public_portal.appearance.save_colors_success', 'Color desat correctament.') })
    } catch (err) {
      toast({
        title: t('public_portal.appearance.save_error', 'Error en desar els canvis.'),
        description: err instanceof Error ? err.message : undefined,
        variant: 'destructive',
      })
    }
  }

  // ---------- Header state ----------
  const [header, setHeader] = useState<ThemeHeader>({
    show_nav: theme.header?.show_nav !== false,
    show_language_switcher: theme.header?.show_language_switcher !== false,
    show_contact_button: theme.header?.show_contact_button ?? false,
    contact_button_label: theme.header?.contact_button_label ?? '',
    contact_button_url: theme.header?.contact_button_url ?? '',
  })

  async function handleHeaderSave() {
    try {
      await patchTheme.mutateAsync({ section: 'header', patch: header as unknown as Json })
      toast({ title: t('public_portal.appearance.save_header_success', 'Capçalera desada correctament.') })
    } catch (err) {
      toast({
        title: t('public_portal.appearance.save_error', 'Error en desar els canvis.'),
        description: err instanceof Error ? err.message : undefined,
        variant: 'destructive',
      })
    }
  }

  // ---------- Footer state ----------
  const [footer, setFooter] = useState<ThemeFooter>({
    copyright_text: theme.footer?.copyright_text ?? '',
    social_links: {
      twitter: theme.footer?.social_links?.twitter ?? '',
      linkedin: theme.footer?.social_links?.linkedin ?? '',
      instagram: theme.footer?.social_links?.instagram ?? '',
      facebook: theme.footer?.social_links?.facebook ?? '',
    },
  })

  async function handleFooterSave() {
    try {
      await patchTheme.mutateAsync({ section: 'footer', patch: footer as unknown as Json })
      toast({ title: t('public_portal.appearance.save_footer_success', 'Peu de pàgina desat correctament.') })
    } catch (err) {
      toast({
        title: t('public_portal.appearance.save_error', 'Error en desar els canvis.'),
        description: err instanceof Error ? err.message : undefined,
        variant: 'destructive',
      })
    }
  }

  const disabled = !canManage || patchTheme.isPending

  return (
    <div className="space-y-6">

      {/* Branding / Logo */}
      <section className="rounded-2xl border bg-card p-6 space-y-4">
        <h3 className="text-sm font-semibold">{t('public_portal.appearance.branding_section', 'Marca')}</h3>
          <div className="space-y-2">
            <label className="text-sm font-medium">{t('public_portal.appearance.logo_label', 'Logo')}</label>
            <p className="text-sm text-muted-foreground">
              {t('public_portal.appearance.logo_hint', 'Format: PNG, JPG, WebP. Màxim 2 MB.')}
            </p>
            {theme.branding?.logo_url && (
              <img
                src={theme.branding.logo_url}
                alt="logo"
                className="h-12 object-contain border rounded p-1 bg-white"
              />
            )}
            <input
              ref={fileInputRef}
              type="file"
              accept="image/png,image/jpeg,image/webp"
              className="hidden"
              onChange={(e) => {
                const file = e.target.files?.[0]
                if (file) handleLogoUpload(file)
              }}
            />
            <Button
              type="button"
              variant="outline"
              size="sm"
              disabled={disabled || logoUploading}
              onClick={() => fileInputRef.current?.click()}
            >
              {logoUploading
                ? t('public_portal.appearance.logo_uploading', 'Pujant...')
                : t('public_portal.appearance.logo_upload_btn', 'Pujar logo')}
            </Button>
            {logoError && <p className="text-sm text-destructive">{logoError}</p>}
          </div>
      </section>

      {/* Colors */}
      <section className="rounded-2xl border bg-card p-6 space-y-4">
        <h3 className="text-sm font-semibold">{t('public_portal.appearance.colors_section', 'Colors')}</h3>
          <div className="flex items-center gap-4">
            <div className="space-y-1">
              <label htmlFor="primary-color" className="text-sm font-medium">
                {t('public_portal.appearance.primary_color_label', 'Color principal')}
              </label>
              <input
                id="primary-color"
                type="color"
                value={primaryColor}
                onChange={(e) => setPrimaryColor(e.target.value)}
                disabled={disabled}
                className="h-10 w-20 cursor-pointer rounded border p-1"
              />
            </div>
            <div className="self-end">
              <Button type="button" size="sm" disabled={disabled} onClick={handleColorSave}>
                {t('public_portal.appearance.save_appearance', 'Desar')}
              </Button>
            </div>
          </div>
      </section>

      {/* Header */}
      <section className="rounded-2xl border bg-card p-6 space-y-4">
        <h3 className="text-sm font-semibold">{t('public_portal.appearance.header_section', 'Capçalera')}</h3>
          <div className="flex flex-col gap-3">
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                checked={header.show_nav !== false}
                disabled={disabled}
                onChange={(e) => setHeader({ ...header, show_nav: e.target.checked })}
              />
              <span className="text-sm">
                {t('public_portal.appearance.show_nav_label', 'Mostrar navegació')}
              </span>
            </label>
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                checked={header.show_language_switcher !== false}
                disabled={disabled}
                onChange={(e) =>
                  setHeader({ ...header, show_language_switcher: e.target.checked })
                }
              />
              <span className="text-sm">
                {t(
                  'public_portal.appearance.show_lang_switcher_label',
                  "Mostrar selector d'idioma",
                )}
              </span>
            </label>
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                checked={header.show_contact_button ?? false}
                disabled={disabled}
                onChange={(e) =>
                  setHeader({ ...header, show_contact_button: e.target.checked })
                }
              />
              <span className="text-sm">
                {t(
                  'public_portal.appearance.show_contact_btn_label',
                  'Mostrar botó de contacte',
                )}
              </span>
            </label>

            {header.show_contact_button && (
              <div className="ml-6 space-y-3">
                <div className="space-y-1">
                  <label htmlFor="contact-btn-label" className="text-sm font-medium">
                    {t('public_portal.appearance.contact_btn_label_label', 'Text del botó')}
                  </label>
                  <Input
                    id="contact-btn-label"
                    value={header.contact_button_label ?? ''}
                    maxLength={50}
                    disabled={disabled}
                    onChange={(e) =>
                      setHeader({ ...header, contact_button_label: e.target.value })
                    }
                  />
                </div>
                <div className="space-y-1">
                  <label htmlFor="contact-btn-url" className="text-sm font-medium">
                    {t('public_portal.appearance.contact_btn_url_label', 'URL del botó')}
                  </label>
                  <Input
                    id="contact-btn-url"
                    type="url"
                    value={header.contact_button_url ?? ''}
                    disabled={disabled}
                    onChange={(e) =>
                      setHeader({ ...header, contact_button_url: e.target.value })
                    }
                  />
                </div>
              </div>
            )}
          </div>
          <Button type="button" size="sm" disabled={disabled} onClick={handleHeaderSave}>
            {t('public_portal.appearance.save_appearance', 'Desar capçalera')}
          </Button>
      </section>

      {/* Footer */}
      <section className="rounded-2xl border bg-card p-6 space-y-4">
        <h3 className="text-sm font-semibold">{t('public_portal.appearance.footer_section', 'Peu de pàgina')}</h3>
          <div className="space-y-1">
            <label htmlFor="copyright-text" className="text-sm font-medium">
              {t('public_portal.appearance.copyright_text_label', 'Text de copyright')}
            </label>
            <p className="text-xs text-muted-foreground">
              {t(
                'public_portal.appearance.copyright_text_hint',
                "Usa {year} per inserir l'any actual automàticament.",
              )}
            </p>
            <Input
              id="copyright-text"
              value={footer.copyright_text ?? ''}
              maxLength={300}
              disabled={disabled}
              onChange={(e) => setFooter({ ...footer, copyright_text: e.target.value })}
            />
          </div>

          <div className="space-y-3">
            <p className="text-sm font-medium">
              {t('public_portal.appearance.social_links_section', 'Xarxes socials')}
            </p>
            {(['twitter', 'linkedin', 'instagram', 'facebook'] as const).map((network) => (
              <div key={network} className="space-y-1">
                <label htmlFor={`social-${network}`} className="text-sm font-medium capitalize">
                  {network}
                </label>
                <Input
                  id={`social-${network}`}
                  type="url"
                  placeholder={`https://${network}.com/...`}
                  value={footer.social_links?.[network] ?? ''}
                  disabled={disabled}
                  onChange={(e) =>
                    setFooter({
                      ...footer,
                      social_links: { ...footer.social_links, [network]: e.target.value },
                    })
                  }
                />
              </div>
            ))}
          </div>

          <Button type="button" size="sm" disabled={disabled} onClick={handleFooterSave}>
            {t('public_portal.appearance.save_appearance', 'Desar peu de pàgina')}
          </Button>
      </section>
    </div>
  )
}
