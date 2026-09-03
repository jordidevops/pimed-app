import { useMemo, useState } from 'react'
import { BookMarked, Loader2, Trash2 } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover'
import { Textarea } from '@/components/ui/textarea'
import { AI_PROVIDER_LABELS } from '@/features/ai/hooks/useAiGenerationConfig'
import type { AiProvider } from '@/features/ai/types/rpc'
import type { AiChatPresetRow } from '@/features/ai-chat/api/chatApi'

type ChatPresetSelectorProps = {
  presets: AiChatPresetRow[]
  selectedPresetId: string | null
  disabled?: boolean
  locked?: boolean
  isLoading?: boolean
  canManageShared?: boolean
  provider: AiProvider
  model: string
  onSelect: (presetId: string | null) => void
  onSave: (input: {
    id?: string | null
    name: string
    provider: AiProvider
    model: string
    systemPromptOverride?: string
    temperatureOverride?: number | null
    isTenantShared?: boolean
  }) => Promise<void>
  onDelete: (presetId: string) => Promise<void>
}

export function ChatPresetSelector({
  presets,
  selectedPresetId,
  disabled = false,
  locked = false,
  isLoading = false,
  canManageShared = false,
  provider,
  model,
  onSelect,
  onSave,
  onDelete,
}: ChatPresetSelectorProps) {
  const { t } = useTranslation('chat')
  const [open, setOpen] = useState(false)
  const [saving, setSaving] = useState(false)
  const [deletingId, setDeletingId] = useState<string | null>(null)
  const [formName, setFormName] = useState('')
  const [formPrompt, setFormPrompt] = useState('')
  const [formTemperature, setFormTemperature] = useState('')
  const [formShared, setFormShared] = useState(false)

  const selectedPreset = useMemo(
    () => presets.find((p) => p.id === selectedPresetId) ?? null,
    [presets, selectedPresetId],
  )

  const summary = selectedPreset?.name ?? t('presetNone', 'Sense preset')

  function resetForm() {
    setFormName('')
    setFormPrompt('')
    setFormTemperature('')
    setFormShared(false)
  }

  async function handleSave() {
    const name = formName.trim()
    if (!name || saving) return

    const tempRaw = formTemperature.trim()
    const temperatureOverride = tempRaw === '' ? null : Number(tempRaw)
    if (tempRaw !== '' && (!Number.isFinite(temperatureOverride) || temperatureOverride! < 0 || temperatureOverride! > 2)) {
      return
    }

    setSaving(true)
    try {
      await onSave({
        name,
        provider,
        model,
        systemPromptOverride: formPrompt.trim() || undefined,
        temperatureOverride,
        isTenantShared: canManageShared ? formShared : false,
      })
      resetForm()
    } finally {
      setSaving(false)
    }
  }

  async function handleDelete(presetId: string) {
    if (deletingId) return
    setDeletingId(presetId)
    try {
      await onDelete(presetId)
      if (selectedPresetId === presetId) onSelect(null)
    } finally {
      setDeletingId(null)
    }
  }

  if (locked && !selectedPreset) return null

  return (
    <Popover open={open} onOpenChange={setOpen} modal={false}>
      <PopoverTrigger asChild>
        <Button
          type="button"
          variant="outline"
          size="sm"
          disabled={disabled || isLoading}
          className="h-auto min-h-8 gap-1.5 max-w-[min(100%,14rem)] py-1"
          title={summary}
        >
          {isLoading ? (
            <Loader2 className="h-3.5 w-3.5 shrink-0 animate-spin" />
          ) : (
            <BookMarked className="h-3.5 w-3.5 shrink-0" />
          )}
          <span className="truncate text-xs text-left">{summary}</span>
        </Button>
      </PopoverTrigger>
      <PopoverContent
        align="end"
        className="z-[100] w-80 sm:w-96 space-y-3"
        onOpenAutoFocus={(e) => e.preventDefault()}
      >
        <div>
          <p className="text-sm font-medium">{t('presetSelectorTitle', 'Preset de xat')}</p>
          <p className="text-xs text-muted-foreground mt-0.5">
            {locked
              ? t('presetLockedHint', 'El preset queda fixat per a aquesta conversa.')
              : t('presetSelectorHint', 'Aplica provider, model i instruccions a la nova conversa.')}
          </p>
        </div>

        {!locked && (
          <div className="space-y-1">
            <Label className="text-xs text-muted-foreground">{t('presetPick', 'Triar preset')}</Label>
            <select
              value={selectedPresetId ?? ''}
              disabled={disabled}
              onChange={(e) => onSelect(e.target.value || null)}
              className="h-8 w-full rounded-md border bg-background px-2 text-sm"
            >
              <option value="">{t('presetNone', 'Sense preset')}</option>
              {presets.map((preset) => (
                <option key={preset.id} value={preset.id}>
                  {preset.name}
                  {preset.is_tenant_shared ? ` (${t('presetShared', 'compartit')})` : ''}
                </option>
              ))}
            </select>
          </div>
        )}

        {selectedPreset && (
          <div className="text-xs text-muted-foreground space-y-0.5 border rounded-md p-2 bg-muted/30">
            <p>{AI_PROVIDER_LABELS[selectedPreset.provider as AiProvider]} · {selectedPreset.model}</p>
            {selectedPreset.system_prompt_override ? (
              <p className="line-clamp-2">{selectedPreset.system_prompt_override}</p>
            ) : null}
          </div>
        )}

        {!locked && (
          <div className="border-t pt-3 space-y-2">
            <p className="text-xs font-medium">{t('presetSaveCurrent', 'Desar configuració actual com a preset')}</p>
            <div className="space-y-1">
              <Label className="text-xs text-muted-foreground">{t('presetName', 'Nom')}</Label>
              <Input
                value={formName}
                onChange={(e) => setFormName(e.target.value)}
                placeholder={t('presetNamePlaceholder', 'Assistent RRHH')}
                className="h-8 text-sm"
              />
            </div>
            <div className="space-y-1">
              <Label className="text-xs text-muted-foreground">{t('presetSystemPrompt', 'Instruccions (opcional)')}</Label>
              <Textarea
                value={formPrompt}
                onChange={(e) => setFormPrompt(e.target.value)}
                rows={3}
                className="text-sm resize-none"
                placeholder={t('presetSystemPromptPlaceholder', 'Ets un assistent especialitzat en…')}
              />
            </div>
            <div className="space-y-1">
              <Label className="text-xs text-muted-foreground">{t('presetTemperature', 'Temperatura (opcional, 0–2)')}</Label>
              <Input
                value={formTemperature}
                onChange={(e) => setFormTemperature(e.target.value)}
                type="number"
                min={0}
                max={2}
                step={0.1}
                className="h-8 text-sm"
              />
            </div>
            {canManageShared && (
              <label className="flex items-center gap-2 text-xs">
                <input
                  type="checkbox"
                  checked={formShared}
                  onChange={(e) => setFormShared(e.target.checked)}
                />
                {t('presetShareTenant', 'Compartir amb tot el tenant')}
              </label>
            )}
            <Button
              type="button"
              size="sm"
              className="w-full"
              disabled={!formName.trim() || saving}
              onClick={() => void handleSave()}
            >
              {saving ? <Loader2 className="h-4 w-4 animate-spin" /> : t('presetSave', 'Desar preset')}
            </Button>
          </div>
        )}

        {!locked && presets.length > 0 && (
          <div className="border-t pt-2 space-y-1 max-h-40 overflow-y-auto">
            <p className="text-xs font-medium text-muted-foreground">{t('presetManage', 'Els meus presets')}</p>
            {presets.map((preset) => (
              <div key={preset.id} className="flex items-center justify-between gap-2 text-xs">
                <button
                  type="button"
                  className="truncate text-left hover:underline"
                  onClick={() => onSelect(preset.id)}
                >
                  {preset.name}
                </button>
                <Button
                  type="button"
                  variant="ghost"
                  size="icon"
                  className="h-7 w-7 shrink-0"
                  disabled={deletingId === preset.id}
                  onClick={() => void handleDelete(preset.id)}
                  title={t('presetDelete', 'Eliminar preset')}
                >
                  {deletingId === preset.id ? (
                    <Loader2 className="h-3.5 w-3.5 animate-spin" />
                  ) : (
                    <Trash2 className="h-3.5 w-3.5" />
                  )}
                </Button>
              </div>
            ))}
          </div>
        )}
      </PopoverContent>
    </Popover>
  )
}
