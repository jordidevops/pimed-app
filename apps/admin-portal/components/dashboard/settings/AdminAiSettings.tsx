'use client'

import { useState, useTransition } from 'react'
import { toast } from 'sonner'
import { CheckCircle2, Copy, Loader2, RefreshCw, Save, Trash2 } from 'lucide-react'
import { useTranslation } from 'react-i18next'

import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Badge } from '@/components/ui/badge'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'

import type { PlatformAiDefault } from '@/app/admin/actions/ai-settings'
import {
  deletePlatformApiKey,
  refreshPlatformProviderModels,
  savePlatformApiKey,
  upsertPlatformAiDefault,
} from '@/app/admin/actions/ai-settings'

const PROVIDER_LABELS: Record<string, string> = {
  openai: 'OpenAI',
  anthropic: 'Anthropic',
  gemini: 'Google Gemini',
  openrouter: 'OpenRouter',
}

type ProviderForm = {
  suggestedModels: string
  defaultModel: string
  billingUrl: string
  systemPrompt: string
  temperature: string
  maxTokens: string
  apiKey: string
  baseUrl: string
}

function toForm(row: PlatformAiDefault): ProviderForm {
  return {
    suggestedModels: (row.suggested_models ?? []).join(', '),
    defaultModel: row.default_model,
    billingUrl: row.billing_url,
    systemPrompt: row.system_prompt ?? '',
    temperature: String(row.temperature ?? 0.2),
    maxTokens: String(row.max_tokens ?? 4096),
    apiKey: '',
    baseUrl: row.base_url ?? '',
  }
}

function ModelBadges({
  models,
  onCopy,
  copiedModel,
}: {
  models: string[]
  onCopy: (model: string) => void
  copiedModel: string | null
}) {
  if (models.length === 0) return null

  return (
    <div className="flex flex-wrap gap-2">
      {models.map((model) => (
        <button
          key={model}
          type="button"
          onClick={() => onCopy(model)}
          className="inline-flex"
          title={model}
        >
          <Badge
            variant="secondary"
            className="cursor-pointer hover:bg-muted font-mono text-xs gap-1 max-w-full"
          >
            {copiedModel === model ? <CheckCircle2 className="h-3 w-3 text-emerald-600" /> : <Copy className="h-3 w-3 opacity-60" />}
            <span className="truncate">{model}</span>
          </Badge>
        </button>
      ))}
    </div>
  )
}

export function AdminAiSettings({ defaults }: { defaults: PlatformAiDefault[] }) {
  const { t } = useTranslation('settings')
  const [forms, setForms] = useState<Record<string, ProviderForm>>(() => {
    const initial: Record<string, ProviderForm> = {}
    for (const row of defaults) initial[row.provider] = toForm(row)
    return initial
  })
  const [availableModels, setAvailableModels] = useState<Record<string, string[]>>(() => {
    const initial: Record<string, string[]> = {}
    for (const row of defaults) initial[row.provider] = row.available_models ?? []
    return initial
  })
  const [copiedModel, setCopiedModel] = useState<string | null>(null)
  const [pending, startTransition] = useTransition()
  const [savingProvider, setSavingProvider] = useState<string | null>(null)
  const [refreshingProvider, setRefreshingProvider] = useState<string | null>(null)
  const [keyActionProvider, setKeyActionProvider] = useState<string | null>(null)

  function updateForm(provider: string, patch: Partial<ProviderForm>) {
    setForms((prev) => ({ ...prev, [provider]: { ...prev[provider], ...patch } }))
  }

  async function copyModel(model: string) {
    await navigator.clipboard.writeText(model)
    setCopiedModel(model)
    toast.success(t('settings.ai.modelCopied', 'Model copiat'))
    window.setTimeout(() => setCopiedModel((current) => (current === model ? null : current)), 1500)
  }

  function save(provider: string) {
    const form = forms[provider]
    if (!form) return

    setSavingProvider(provider)
    startTransition(async () => {
      try {
        await upsertPlatformAiDefault({
          provider,
          suggested_models: form.suggestedModels.split(',').map((s) => s.trim()).filter(Boolean),
          default_model: form.defaultModel.trim(),
          billing_url: form.billingUrl.trim(),
          system_prompt: form.systemPrompt.trim() || null,
          temperature: Number(form.temperature) || 0.2,
          max_tokens: Number(form.maxTokens) || 4096,
        })
        toast.success(t('settings.ai.saved', 'Configuració desada'))
      } catch (err) {
        toast.error(err instanceof Error ? err.message : String(err))
      } finally {
        setSavingProvider(null)
      }
    })
  }

  function saveKey(provider: string) {
    const form = forms[provider]
    if (!form?.apiKey.trim()) {
      toast.error(t('settings.ai.apiKeyRequired', 'Cal introduir una API key'))
      return
    }

    setKeyActionProvider(provider)
    startTransition(async () => {
      try {
        await savePlatformApiKey({
          provider,
          apiKey: form.apiKey.trim(),
          model: form.defaultModel.trim() || null,
          baseUrl: form.baseUrl.trim() || null,
        })
        updateForm(provider, { apiKey: '' })
        toast.success(t('settings.ai.keyVerifiedSaved', 'Clau verificada i desada'))
      } catch (err) {
        toast.error(err instanceof Error ? err.message : String(err))
      } finally {
        setKeyActionProvider(null)
      }
    })
  }

  function removeKey(provider: string) {
    setKeyActionProvider(provider)
    startTransition(async () => {
      try {
        await deletePlatformApiKey(provider)
        setAvailableModels((prev) => ({ ...prev, [provider]: [] }))
        toast.success(t('settings.ai.keyDeleted', 'Clau eliminada'))
      } catch (err) {
        toast.error(err instanceof Error ? err.message : String(err))
      } finally {
        setKeyActionProvider(null)
      }
    })
  }

  function fetchModels(provider: string) {
    setRefreshingProvider(provider)
    startTransition(async () => {
      try {
        const models = await refreshPlatformProviderModels(provider)
        setAvailableModels((prev) => ({ ...prev, [provider]: models }))
        toast.success(
          t('settings.ai.modelsFetched', '{{count}} models llegits de l\'API', { count: models.length }),
        )
      } catch (err) {
        toast.error(err instanceof Error ? err.message : String(err))
      } finally {
        setRefreshingProvider(null)
      }
    })
  }

  return (
    <div className="space-y-6">
      {defaults.map((row) => {
        const form = forms[row.provider] ?? toForm(row)
        const models = availableModels[row.provider] ?? []
        const isBusy = pending && (savingProvider === row.provider || refreshingProvider === row.provider || keyActionProvider === row.provider)

        return (
          <Card key={row.provider}>
            <CardHeader>
              <div className="flex items-center justify-between gap-4">
                <div>
                  <CardTitle>{PROVIDER_LABELS[row.provider] ?? row.provider}</CardTitle>
                  <CardDescription>
                    {t('settings.ai.providerHint', 'Models suggerits, model per defecte i enllaç de facturació per al tenant-portal.')}
                  </CardDescription>
                </div>
                {row.configured && (
                  <Badge className="bg-emerald-100 text-emerald-800 hover:bg-emerald-100">
                    {t('settings.ai.keyVerified', 'Clau verificada')}
                  </Badge>
                )}
              </div>
            </CardHeader>
            <CardContent className="space-y-6">
              <div className="rounded-lg border p-4 space-y-4 bg-muted/20">
                <div>
                  <h4 className="text-sm font-medium">{t('settings.ai.platformKeyTitle', 'Clau API de plataforma')}</h4>
                  <p className="text-xs text-muted-foreground mt-1">
                    {t('settings.ai.platformKeyHint', 'S\'emmagatzema xifrada al Vault (mateix patró que els tenants). Serveix per llegir models des de l\'API del proveïdor.')}
                  </p>
                </div>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div className="space-y-2 md:col-span-2">
                    <Label>{t('settings.ai.apiKey', 'API key')}</Label>
                    <Input
                      type="password"
                      autoComplete="off"
                      placeholder={row.has_key ? '••••••••••••••••' : t('settings.ai.apiKeyPlaceholder', 'sk-...')}
                      value={form.apiKey}
                      onChange={(e) => updateForm(row.provider, { apiKey: e.target.value })}
                    />
                  </div>
                  <div className="space-y-2 md:col-span-2">
                    <Label>{t('settings.ai.baseUrl', 'Base URL (opcional)')}</Label>
                    <Input
                      value={form.baseUrl}
                      onChange={(e) => updateForm(row.provider, { baseUrl: e.target.value })}
                      placeholder="https://..."
                    />
                  </div>
                </div>
                {row.key_last_error && (
                  <p className="text-xs text-red-600">{row.key_last_error}</p>
                )}
                <div className="flex flex-wrap gap-2">
                  <Button
                    type="button"
                    variant="secondary"
                    onClick={() => saveKey(row.provider)}
                    disabled={isBusy}
                  >
                    {keyActionProvider === row.provider ? (
                      <Loader2 className="h-4 w-4 animate-spin mr-2" />
                    ) : null}
                    {t('settings.ai.verifyAndSaveKey', 'Verificar i desar clau')}
                  </Button>
                  {row.has_key && (
                    <Button
                      type="button"
                      variant="outline"
                      onClick={() => removeKey(row.provider)}
                      disabled={isBusy}
                    >
                      <Trash2 className="h-4 w-4 mr-2" />
                      {t('settings.ai.deleteKey', 'Eliminar clau')}
                    </Button>
                  )}
                  <Button
                    type="button"
                    variant="outline"
                    onClick={() => fetchModels(row.provider)}
                    disabled={isBusy || !row.configured}
                  >
                    {refreshingProvider === row.provider ? (
                      <Loader2 className="h-4 w-4 animate-spin mr-2" />
                    ) : (
                      <RefreshCw className="h-4 w-4 mr-2" />
                    )}
                    {t('settings.ai.fetchModels', 'Llegir models de l\'API')}
                  </Button>
                </div>
                {models.length > 0 && (
                  <div className="space-y-2">
                    <Label>{t('settings.ai.availableModels', 'Models disponibles (clic per copiar)')}</Label>
                    <ModelBadges models={models} onCopy={copyModel} copiedModel={copiedModel} />
                  </div>
                )}
              </div>

              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div className="space-y-2 md:col-span-2">
                  <Label>{t('settings.ai.suggestedModels', 'Models suggerits (separats per comes)')}</Label>
                  <Input
                    value={form.suggestedModels}
                    onChange={(e) => updateForm(row.provider, { suggestedModels: e.target.value })}
                  />
                </div>
                <div className="space-y-2">
                  <Label>{t('settings.ai.defaultModel', 'Model per defecte')}</Label>
                  <Input
                    value={form.defaultModel}
                    onChange={(e) => updateForm(row.provider, { defaultModel: e.target.value })}
                  />
                </div>
                <div className="space-y-2">
                  <Label>{t('settings.ai.billingUrl', 'URL facturació')}</Label>
                  <Input
                    value={form.billingUrl}
                    onChange={(e) => updateForm(row.provider, { billingUrl: e.target.value })}
                  />
                </div>
                <div className="space-y-2 md:col-span-2">
                  <Label>{t('settings.ai.systemPrompt', 'System prompt (opcional)')}</Label>
                  <textarea
                    value={form.systemPrompt}
                    onChange={(e) => updateForm(row.provider, { systemPrompt: e.target.value })}
                    className="w-full min-h-[80px] rounded-md border px-3 py-2 text-sm"
                  />
                </div>
                <div className="space-y-2">
                  <Label>{t('settings.ai.temperature', 'Temperature')}</Label>
                  <Input
                    type="number"
                    min={0}
                    max={1}
                    step={0.1}
                    value={form.temperature}
                    onChange={(e) => updateForm(row.provider, { temperature: e.target.value })}
                  />
                </div>
                <div className="space-y-2">
                  <Label>{t('settings.ai.maxTokens', 'Max tokens')}</Label>
                  <Input
                    type="number"
                    min={1}
                    value={form.maxTokens}
                    onChange={(e) => updateForm(row.provider, { maxTokens: e.target.value })}
                  />
                </div>
              </div>
              <div className="flex justify-end">
                <Button
                  type="button"
                  onClick={() => save(row.provider)}
                  disabled={pending && savingProvider === row.provider}
                >
                  {pending && savingProvider === row.provider ? (
                    <Loader2 className="h-4 w-4 animate-spin mr-2" />
                  ) : (
                    <Save className="h-4 w-4 mr-2" />
                  )}
                  {t('settings.ai.save', 'Desar')}
                </Button>
              </div>
            </CardContent>
          </Card>
        )
      })}
    </div>
  )
}
