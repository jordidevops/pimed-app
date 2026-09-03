import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { getFileUrl } from '../api/storageService'

// ---------------------------------------------------------------------------
// Types & constants
// ---------------------------------------------------------------------------

interface GetUrlModalProps {
  fileId: string
  fileName: string
  tenantId: string
  onClose: () => void
}

interface GetUrlResult {
  type: 'signed' | 'share'
  url: string
}

const PRESETS = [
  { key: '1d', seconds: 86_400,      fallback: '1 dia' },
  { key: '1w', seconds: 604_800,     fallback: '1 setmana' },
  { key: '1m', seconds: 2_592_000,   fallback: '1 mes' },
  { key: '1y', seconds: 31_536_000,  fallback: '1 any' },
] as const

type PresetKey = typeof PRESETS[number]['key']

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------

export function GetUrlModal({ fileId, fileName, tenantId, onClose }: GetUrlModalProps) {
  const { t } = useTranslation('storage')

  const [selected, setSelected] = useState<PresetKey | 'custom'>('1w')
  const [customDays, setCustomDays] = useState('30')
  const [result, setResult] = useState<GetUrlResult | null>(null)
  const [isLoading, setIsLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)

  // Close on Escape
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [onClose])

  function getExpirySeconds(): number {
    if (selected === 'custom') {
      const days = parseInt(customDays, 10)
      return !isNaN(days) && days > 0 ? days * 86_400 : 86_400
    }
    return PRESETS.find((p) => p.key === selected)!.seconds
  }

  const isLongExpiry = getExpirySeconds() > 604_800

  async function handleGenerate() {
    setIsLoading(true)
    setError(null)
    setResult(null)
    try {
      const res = await getFileUrl(fileId, getExpirySeconds(), tenantId)
      setResult({ url: res.url, type: res.type })
    } catch (err) {
      setError(
        err instanceof Error
          ? err.message
          : t('storage.share.error_generic', 'Error en generar la URL'),
      )
    } finally {
      setIsLoading(false)
    }
  }

  async function handleCopy() {
    if (!result) return
    try {
      await navigator.clipboard.writeText(result.url)
      setCopied(true)
      setTimeout(() => setCopied(false), 2500)
    } catch {
      // Clipboard unavailable — user can select the input manually
    }
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 backdrop-blur-sm"
      onClick={onClose}
    >
      <div
        className="bg-card rounded-2xl shadow-2xl w-full max-w-md mx-4 overflow-hidden"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between px-5 py-3.5 border-b border-border">
          <div className="min-w-0">
            <h3 className="text-sm font-semibold text-foreground">
              {t('storage.share.modal_title', 'Obtenir URL del fitxer')}
            </h3>
            <p
              className="text-xs text-muted-foreground mt-0.5 truncate max-w-[260px]"
              title={fileName}
            >
              {fileName}
            </p>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="ml-3 shrink-0 p-1 rounded-lg text-muted-foreground hover:bg-accent hover:text-accent-foreground transition"
            aria-label={t('storage.explorer.preview_close', 'Tanca')}
          >
            <svg className="h-5 w-5" viewBox="0 0 20 20" fill="currentColor" aria-hidden>
              <path d="M6.28 5.22a.75.75 0 0 0-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 1 0 1.06 1.06L10 11.06l3.72 3.72a.75.75 0 1 0 1.06-1.06L11.06 10l3.72-3.72a.75.75 0 0 0-1.06-1.06L10 8.94 6.28 5.22Z" />
            </svg>
          </button>
        </div>

        {/* Body */}
        <div className="px-5 py-4 space-y-4">

          {/* Expiry presets */}
          <div>
            <p className="text-xs font-medium text-foreground mb-2">
              {t('storage.share.expiry_label', "Durada de l'enllaç")}
            </p>
            <div className="grid grid-cols-4 gap-1.5">
              {PRESETS.map((p) => (
                <button
                  key={p.key}
                  type="button"
                  onClick={() => setSelected(p.key)}
                  className={`py-1.5 rounded-lg text-xs font-medium transition-colors ${
                    selected === p.key
                      ? 'bg-indigo-600 text-white'
                      : 'bg-muted text-foreground hover:bg-accent'
                  }`}
                >
                  {t(`storage.share.preset_${p.key}`, p.fallback)}
                </button>
              ))}
            </div>

            {/* Custom expiry toggle */}
            <button
              type="button"
              onClick={() => setSelected('custom')}
              className={`mt-1.5 w-full py-1.5 rounded-lg text-xs font-medium transition-colors ${
                selected === 'custom'
                  ? 'bg-indigo-600 text-white'
                  : 'bg-muted text-foreground hover:bg-accent'
              }`}
            >
              {t('storage.share.preset_custom', 'Personalitzat')}
            </button>

            {selected === 'custom' && (
              <div className="mt-2 flex items-center gap-2">
                <input
                  type="number"
                  min={1}
                  max={3650}
                  value={customDays}
                  onChange={(e) => setCustomDays(e.target.value)}
                  className="w-20 px-2 py-1 text-sm border border-input bg-background text-foreground rounded-lg focus:outline-none focus:ring-2 focus:ring-primary/30"
                  aria-label={t('storage.share.custom_days_label', 'Dies de validesa')}
                  placeholder={t('storage.share.custom_days_placeholder', 'Ex: 30')}
                />
                <span className="text-xs text-muted-foreground">
                  {t('storage.share.custom_unit', 'dies')}
                </span>
              </div>
            )}
          </div>

          {/* Informational note */}
          <p className="text-xs text-muted-foreground leading-relaxed">
            {isLongExpiry
              ? t(
                  'storage.share.note_token',
                  "Es crearà un token persistent. En cada accés es genera una URL temporal de 5 min.",
                )
              : t(
                  'storage.share.note_signed',
                  "Es generarà una URL signada directa, vàlida fins al termini indicat.",
                )}
          </p>

          {/* Generate button */}
          <button
            type="button"
            onClick={handleGenerate}
            disabled={isLoading}
            className="w-full py-2 rounded-xl text-sm font-semibold bg-indigo-600 text-white hover:bg-indigo-700 transition disabled:opacity-50"
          >
            {isLoading
              ? t('storage.share.generating', 'Generant URL...')
              : t('storage.share.generate_btn', 'Generar URL')}
          </button>

          {/* Error */}
          {error && (
            <p className="text-xs text-red-600 bg-red-50 px-3 py-2 rounded-lg">
              {error}
            </p>
          )}

          {/* Result */}
          {result && (
            <div className="rounded-xl border border-border bg-muted/50 p-3 space-y-2">
              <div className="flex items-center gap-1.5 flex-wrap">
                <span className="text-xs font-medium text-foreground">
                  {result.type === 'share'
                    ? t(
                        'storage.share.result_token_label',
                        'Enllaç compartit (llarg termini)',
                      )
                    : t('storage.share.result_signed_label', 'URL signada directa')}
                </span>
                {result.type === 'share' && (
                  <span className="px-1.5 py-0.5 rounded text-[10px] font-medium bg-amber-100 text-amber-700">
                    {t('storage.share.badge_token', 'token')}
                  </span>
                )}
              </div>
              <div className="flex items-center gap-2">
                <input
                  readOnly
                  value={result.url}
                  onClick={(e) => (e.target as HTMLInputElement).select()}
                  className="flex-1 min-w-0 px-2 py-1.5 text-xs text-muted-foreground bg-background border border-input rounded-lg focus:outline-none"
                  aria-label={t('storage.share.url_input_label', 'URL generada')}
                  title={t('storage.share.url_input_title', 'URL generada per compartir')}
                />
                <button
                  type="button"
                  onClick={handleCopy}
                  className={`shrink-0 px-3 py-1.5 rounded-lg text-xs font-semibold transition ${
                    copied
                      ? 'bg-green-500 text-white'
                      : 'bg-indigo-600 text-white hover:bg-indigo-700'
                  }`}
                >
                  {copied
                    ? t('storage.share.copied', 'Copiat!')
                    : t('storage.share.copy_btn', 'Copiar')}
                </button>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
