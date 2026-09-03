'use client'

import { useMemo, useState, useTransition } from 'react'
import { Loader2, Save } from 'lucide-react'
import { toast } from 'sonner'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Badge } from '@/components/ui/badge'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import {
  upsertAiModelCapabilityAdmin,
  type AiModelCapabilityAdminRow,
} from '@/app/admin/actions/ai-settings'

type EditableCapability = AiModelCapabilityAdminRow & {
  supported_image_mimes_text: string
  supported_file_mimes_text: string
  deprecated: boolean
}

const PROVIDERS = ['openai', 'anthropic', 'gemini', 'openrouter'] as const

function toEditable(row: AiModelCapabilityAdminRow): EditableCapability {
  return {
    ...row,
    supported_image_mimes_text: (row.supported_image_mimes ?? []).join(', '),
    supported_file_mimes_text: (row.supported_file_mimes ?? []).join(', '),
    deprecated: !!row.deprecated_at,
  }
}

function toMimes(value: string): string[] {
  return value
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean)
}

export function AdminAiModelCapabilities({ rows }: { rows: AiModelCapabilityAdminRow[] }) {
  const { t } = useTranslation('settings')
  const [pending, startTransition] = useTransition()
  const [providerFilter, setProviderFilter] = useState<string>('all')
  const [needsReviewOnly, setNeedsReviewOnly] = useState<boolean>(false)
  const [items, setItems] = useState<EditableCapability[]>(() => rows.map(toEditable))
  const [savingKey, setSavingKey] = useState<string | null>(null)

  const [newModel, setNewModel] = useState({
    provider: 'openai',
    model_id: '',
  })

  const filtered = useMemo(() => {
    return items.filter((row) => {
      if (providerFilter !== 'all' && row.provider !== providerFilter) return false
      if (needsReviewOnly && !row.needs_review) return false
      return true
    })
  }, [items, providerFilter, needsReviewOnly])

  function updateRow(key: string, patch: Partial<EditableCapability>) {
    setItems((prev) => prev.map((row) => (row.provider + '::' + row.model_id === key ? { ...row, ...patch } : row)))
  }

  function saveRow(row: EditableCapability) {
    const key = `${row.provider}::${row.model_id}`
    setSavingKey(key)
    startTransition(async () => {
      try {
        await upsertAiModelCapabilityAdmin({
          provider: row.provider,
          model_id: row.model_id,
          vision: row.vision,
          tools: row.tools,
          tools_with_vision: row.tools_with_vision,
          streaming: row.streaming,
          max_image_size_mb: row.max_image_size_mb,
          supported_image_mimes: toMimes(row.supported_image_mimes_text),
          max_file_size_mb: row.max_file_size_mb,
          supported_file_mimes: toMimes(row.supported_file_mimes_text),
          context_window: row.context_window,
          deprecated: row.deprecated,
          needs_review: row.needs_review,
          source: row.source ?? 'admin',
        })
        toast.success(t('settings.ai.capabilitiesSaved', 'Capacitats desades'))
      } catch (err) {
        toast.error(err instanceof Error ? err.message : String(err))
      } finally {
        setSavingKey(null)
      }
    })
  }

  function addModel() {
    const provider = newModel.provider
    const modelId = newModel.model_id.trim()
    if (!modelId) {
      toast.error(t('settings.ai.modelRequired', 'Cal indicar el model_id'))
      return
    }
    const exists = items.some((row) => row.provider === provider && row.model_id === modelId)
    if (exists) {
      toast.error(t('settings.ai.modelAlreadyExists', 'Aquest model ja existeix'))
      return
    }
    const created: EditableCapability = toEditable({
      provider,
      model_id: modelId,
      vision: false,
      tools: true,
      tools_with_vision: false,
      streaming: true,
      max_image_size_mb: 5,
      supported_image_mimes: ['image/jpeg', 'image/png', 'image/webp'],
      max_file_size_mb: 10,
      supported_file_mimes: ['application/pdf'],
      context_window: null,
      deprecated_at: null,
      needs_review: true,
      source: 'admin',
      updated_at: new Date().toISOString(),
    })
    setItems((prev) => [created, ...prev])
    setNewModel((prev) => ({ ...prev, model_id: '' }))
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>{t('settings.ai.capabilitiesTitle', 'AI Model Capabilities')}</CardTitle>
        <CardDescription>
          {t(
            'settings.ai.capabilitiesDescription',
            'Administra visió, tools, streaming i límits de fitxers per model. Els models nous detectats per sync queden amb needs_review.',
          )}
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-5">
        <div className="rounded-lg border p-4 bg-muted/20 space-y-3">
          <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
            <div className="space-y-2">
              <Label>{t('settings.ai.provider', 'Proveïdor')}</Label>
              <select
                className="h-9 w-full rounded-md border bg-background px-3 text-sm"
                value={newModel.provider}
                onChange={(e) => setNewModel((prev) => ({ ...prev, provider: e.target.value }))}
              >
                {PROVIDERS.map((provider) => (
                  <option key={provider} value={provider}>
                    {provider}
                  </option>
                ))}
              </select>
            </div>
            <div className="space-y-2 md:col-span-2">
              <Label>{t('settings.ai.modelId', 'Model ID')}</Label>
              <div className="flex gap-2">
                <Input
                  value={newModel.model_id}
                  onChange={(e) => setNewModel((prev) => ({ ...prev, model_id: e.target.value }))}
                  placeholder="gpt-4o-mini"
                />
                <Button type="button" variant="outline" onClick={addModel}>
                  {t('settings.ai.addModel', 'Afegir')}
                </Button>
              </div>
            </div>
          </div>
          <p className="text-xs text-muted-foreground">
            {t(
              'settings.ai.addModelHint',
              'Afegeix un model manualment i desa la fila per persistir-la. Es crearà amb needs_review=true per defecte.',
            )}
          </p>
        </div>

        <div className="flex flex-wrap items-end gap-3">
          <label className="space-y-1">
            <span className="text-xs text-muted-foreground">{t('settings.ai.filterProvider', 'Filtra proveïdor')}</span>
            <select
              className="h-9 rounded-md border bg-background px-3 text-sm"
              value={providerFilter}
              onChange={(e) => setProviderFilter(e.target.value)}
            >
              <option value="all">{t('settings.ai.allProviders', 'Tots')}</option>
              {PROVIDERS.map((provider) => (
                <option key={provider} value={provider}>
                  {provider}
                </option>
              ))}
            </select>
          </label>

          <label className="inline-flex items-center gap-2 h-9 px-2">
            <input
              type="checkbox"
              checked={needsReviewOnly}
              onChange={(e) => setNeedsReviewOnly(e.target.checked)}
            />
            <span className="text-sm">{t('settings.ai.onlyNeedsReview', 'Només needs_review')}</span>
          </label>

          <Badge variant="secondary">{t('settings.ai.capabilitiesCount', '{{count}} models', { count: filtered.length })}</Badge>
        </div>

        <div className="space-y-3">
          {filtered.map((row) => {
            const key = `${row.provider}::${row.model_id}`
            const isSaving = pending && savingKey === key
            return (
              <div key={key} className="rounded-lg border p-4 space-y-3">
                <div className="flex items-center justify-between gap-2">
                  <div className="min-w-0">
                    <p className="font-medium text-sm truncate">{row.model_id}</p>
                    <p className="text-xs text-muted-foreground">{row.provider}</p>
                  </div>
                  <div className="flex gap-1.5">
                    {row.needs_review && <Badge variant="secondary">needs_review</Badge>}
                    {row.deprecated && <Badge variant="outline">deprecated</Badge>}
                    <Badge variant="outline">{row.source}</Badge>
                  </div>
                </div>

                <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
                  <label className="inline-flex items-center gap-2 text-sm"><input type="checkbox" checked={row.vision} onChange={(e) => updateRow(key, { vision: e.target.checked })} />vision</label>
                  <label className="inline-flex items-center gap-2 text-sm"><input type="checkbox" checked={row.tools} onChange={(e) => updateRow(key, { tools: e.target.checked })} />tools</label>
                  <label className="inline-flex items-center gap-2 text-sm"><input type="checkbox" checked={row.tools_with_vision} onChange={(e) => updateRow(key, { tools_with_vision: e.target.checked })} />tools_with_vision</label>
                  <label className="inline-flex items-center gap-2 text-sm"><input type="checkbox" checked={row.streaming} onChange={(e) => updateRow(key, { streaming: e.target.checked })} />streaming</label>
                  <label className="inline-flex items-center gap-2 text-sm"><input type="checkbox" checked={row.needs_review} onChange={(e) => updateRow(key, { needs_review: e.target.checked })} />needs_review</label>
                  <label className="inline-flex items-center gap-2 text-sm"><input type="checkbox" checked={row.deprecated} onChange={(e) => updateRow(key, { deprecated: e.target.checked })} />deprecated</label>
                </div>

                <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
                  <label className="space-y-1">
                    <span className="text-xs text-muted-foreground">max_image_size_mb</span>
                    <Input
                      type="number"
                      min={1}
                      value={row.max_image_size_mb}
                      onChange={(e) => updateRow(key, { max_image_size_mb: Number(e.target.value) || 1 })}
                    />
                  </label>
                  <label className="space-y-1">
                    <span className="text-xs text-muted-foreground">max_file_size_mb</span>
                    <Input
                      type="number"
                      min={1}
                      value={row.max_file_size_mb}
                      onChange={(e) => updateRow(key, { max_file_size_mb: Number(e.target.value) || 1 })}
                    />
                  </label>
                  <label className="space-y-1">
                    <span className="text-xs text-muted-foreground">context_window</span>
                    <Input
                      type="number"
                      min={1}
                      value={row.context_window ?? ''}
                      onChange={(e) =>
                        updateRow(key, {
                          context_window: e.target.value.trim() === '' ? null : Math.max(1, Number(e.target.value) || 1),
                        })
                      }
                    />
                  </label>
                </div>

                <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
                  <label className="space-y-1">
                    <span className="text-xs text-muted-foreground">supported_image_mimes (csv)</span>
                    <Input
                      value={row.supported_image_mimes_text}
                      onChange={(e) => updateRow(key, { supported_image_mimes_text: e.target.value })}
                    />
                  </label>
                  <label className="space-y-1">
                    <span className="text-xs text-muted-foreground">supported_file_mimes (csv)</span>
                    <Input
                      value={row.supported_file_mimes_text}
                      onChange={(e) => updateRow(key, { supported_file_mimes_text: e.target.value })}
                    />
                  </label>
                </div>

                <div className="flex justify-end">
                  <Button type="button" onClick={() => saveRow(row)} disabled={isSaving}>
                    {isSaving ? <Loader2 className="h-4 w-4 animate-spin mr-2" /> : <Save className="h-4 w-4 mr-2" />}
                    {t('settings.ai.save', 'Desar')}
                  </Button>
                </div>
              </div>
            )
          })}

          {filtered.length === 0 && (
            <p className="text-sm text-muted-foreground py-4 text-center">
              {t('settings.ai.noCapabilityRows', 'No hi ha files per aquests filtres.')}
            </p>
          )}
        </div>
      </CardContent>
    </Card>
  )
}

