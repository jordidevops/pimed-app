import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { AlertCircle, CheckCircle2, Circle, Save, ShieldAlert, Sparkles, Trash2 } from 'lucide-react'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { useTenant } from '../../contexts/TenantContext'
import { useToast } from '../../hooks/use-toast'
import { supabase } from '../../lib/supabase'
import { getFunctionErrorMessage, getResponseErrorMessage } from '../../lib/functionErrors'
import { AiUsageDashboard } from '@/features/ai/components/AiUsageDashboard'
import { AiUserPoliciesPanel } from '@/features/ai/components/AiUserPoliciesPanel'
import { AiConnectionTest } from '@/features/ai/components/AiConnectionTest'
import { AiProviderNav } from '@/features/ai/components/AiProviderNav'
import { AiProviderModelsPanel } from '@/features/ai/components/AiProviderModelsPanel'
import { AiSettingsSection } from '@/features/ai/components/AiSettingsSection'
import { pickDefaultAmongAllowed } from '@/features/ai/utils/aiModels'

import { fetchAiConfigForTenant, saveTenantAiProviderGenerationSettings, setAiAnalyticsCronEnabled, setTenantAiDefaultProvider } from '@/features/ai/api/aiRpc'
import { invalidateAiTenantQueries } from '@/features/ai/api/aiQueryKeys'
import type { AiConfigForTenant, AiProvider } from '@/features/ai/types/rpc'

const PROVIDERS: AiProvider[] = ['openai', 'anthropic', 'gemini', 'openrouter']

const PROVIDER_LABELS: Record<AiProvider, string> = {
  openai: 'OpenAI',
  anthropic: 'Anthropic',
  gemini: 'Google Gemini',
  openrouter: 'OpenRouter',
}

const DEFAULT_MODELS: Record<AiProvider, string> = {
  openai: 'gpt-4o-mini',
  anthropic: 'claude-3-5-haiku-latest',
  gemini: 'gemini-3.6-flash',
  openrouter: 'openai/gpt-4o-mini',
}

const DEFAULT_BASE_URLS: Record<AiProvider, string> = {
  openai: 'https://api.openai.com/v1',
  anthropic: 'https://api.anthropic.com',
  gemini: 'https://generativelanguage.googleapis.com/v1beta',
  openrouter: 'https://openrouter.ai/api/v1',
}

const FUNCTIONS_BASE = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1`

type ProviderFormState = {
  apiKey: string
  model: string
  baseUrl: string
}

type GenerationFormState = {
  systemPrompt: string
  temperature: string
  maxTokens: string
}

function emptyEnabledModelsForms(): Record<AiProvider, string[]> {
  return { openai: [], anthropic: [], gemini: [], openrouter: [] }
}

function emptyProviderForms(): Record<AiProvider, ProviderFormState> {
  return {
    openai: { apiKey: '', model: DEFAULT_MODELS.openai, baseUrl: '' },
    anthropic: { apiKey: '', model: DEFAULT_MODELS.anthropic, baseUrl: '' },
    gemini: { apiKey: '', model: DEFAULT_MODELS.gemini, baseUrl: '' },
    openrouter: { apiKey: '', model: DEFAULT_MODELS.openrouter, baseUrl: '' },
  }
}

function emptyGenerationForms(): Record<AiProvider, GenerationFormState> {
  return {
    openai: { systemPrompt: '', temperature: '0.2', maxTokens: '4096' },
    anthropic: { systemPrompt: '', temperature: '0.2', maxTokens: '4096' },
    gemini: { systemPrompt: '', temperature: '0.2', maxTokens: '4096' },
    openrouter: { systemPrompt: '', temperature: '0.2', maxTokens: '4096' },
  }
}

function formatVerifiedAt(iso: string | null | undefined): string | null {
  if (!iso) return null
  try {
    return new Intl.DateTimeFormat('ca', {
      dateStyle: 'short',
      timeStyle: 'short',
    }).format(new Date(iso))
  } catch {
    return iso
  }
}

export function AiPage() {
  const { t } = useTranslation('settings')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  const { activeTenant, activeRole } = useTenant()
  const tenantId = activeTenant?.id ?? null
  const canManage = activeRole === 'owner' || activeRole === 'manager'
  const isOwner = activeRole === 'owner'

  const [defaultProvider, setDefaultProvider] = useState<AiProvider>('openai')
  const [activeProvider, setActiveProvider] = useState<AiProvider>('openai')
  const [providerForms, setProviderForms] = useState(emptyProviderForms())
  const [generationForms, setGenerationForms] = useState(emptyGenerationForms())
  const [enabledModelsForms, setEnabledModelsForms] = useState(emptyEnabledModelsForms())
  const [savingProvider, setSavingProvider] = useState<AiProvider | null>(null)
  const [savingGeneration, setSavingGeneration] = useState<AiProvider | null>(null)
  const [deletingProvider, setDeletingProvider] = useState<AiProvider | null>(null)
  const [refreshingModels, setRefreshingModels] = useState<AiProvider | null>(null)
  const [savingAnalyticsCron, setSavingAnalyticsCron] = useState(false)

  const enabled = !!tenantId && canManage

  const { data: config, isLoading } = useQuery<AiConfigForTenant | null>({
    queryKey: ['ai_config', tenantId],
    enabled,
    queryFn: async () => fetchAiConfigForTenant(tenantId!),
  })

  useEffect(() => {
    if (!config) return
    const nextDefault = config.default_provider ?? 'openai'
    setDefaultProvider(nextDefault)
    setActiveProvider((prev) => (PROVIDERS.includes(prev) ? prev : nextDefault))

    const nextForms = emptyProviderForms()
    const nextGeneration = emptyGenerationForms()
    const nextEnabled = emptyEnabledModelsForms()
    for (const row of config.providers ?? []) {
      nextForms[row.provider] = {
        apiKey: '',
        model: pickDefaultAmongAllowed(
          row.model ?? DEFAULT_MODELS[row.provider],
          row.available_models ?? [],
          row.enabled_models ?? [],
          DEFAULT_MODELS[row.provider],
        ),
        baseUrl: row.base_url === DEFAULT_BASE_URLS[row.provider] ? '' : (row.base_url ?? ''),
      }
      nextGeneration[row.provider] = {
        systemPrompt: row.system_prompt ?? '',
        temperature: String(row.temperature ?? row.platform_temperature ?? 0.2),
        maxTokens: String(row.max_tokens ?? row.platform_max_tokens ?? 4096),
      }
      nextEnabled[row.provider] = row.enabled_models ?? []
    }
    setProviderForms(nextForms)
    setGenerationForms(nextGeneration)
    setEnabledModelsForms(nextEnabled)
  }, [config])

  const providerStatusMap = useMemo(() => {
    const map = new Map<AiProvider, AiConfigForTenant['providers'][number]>()
    for (const row of config?.providers ?? []) {
      map.set(row.provider, row)
    }
    return map
  }, [config])

  const providerConfigured = useMemo(() => {
    const out = {} as Record<AiProvider, boolean>
    for (const p of PROVIDERS) {
      out[p] = providerStatusMap.get(p)?.configured ?? false
    }
    return out
  }, [providerStatusMap])

  const saveDefaultMutation = useMutation({
    mutationFn: async () => {
      if (!tenantId) throw new Error('No tenant')
      await setTenantAiDefaultProvider(tenantId, defaultProvider)
    },
    onSuccess: async () => {
      await invalidateAiTenantQueries(queryClient, tenantId)
      toast({ description: t('ai.defaultSaved', 'Proveïdor per defecte desat') })
    },
    onError: (err) => {
      toast({ variant: 'destructive', description: err instanceof Error ? err.message : String(err) })
    },
  })

  async function saveProvider(provider: AiProvider) {
    if (!tenantId || !canManage) return

    const form = providerForms[provider]
    const status = providerStatusMap.get(provider)
    const isConfigured = status?.configured ?? false
    const hasNewKey = !!form.apiKey.trim()

    if (!hasNewKey && !isConfigured) {
      toast({ variant: 'destructive', description: t('ai.apiKeyRequired', 'Cal introduir una API key') })
      return
    }

    setSavingProvider(provider)
    try {
      const available = status?.available_models ?? []
      const enabled = enabledModelsForms[provider]
      const modelToSave = pickDefaultAmongAllowed(
        form.model.trim() || DEFAULT_MODELS[provider],
        available,
        enabled,
        DEFAULT_MODELS[provider],
      )

      const { data, error } = await supabase.functions.invoke('save-tenant-api-key', {
        headers: { 'x-tenant-id': tenantId },
        body: {
          provider,
          apiKey: hasNewKey ? form.apiKey.trim() : null,
          model: modelToSave,
          baseUrl: form.baseUrl.trim() || null,
          enabledModels: enabled,
        },
      })

      if (error) {
        const detailed = await getFunctionErrorMessage(error)
        throw new Error(detailed ?? error.message)
      }
      const responseError = getResponseErrorMessage(data)
      if (responseError) throw new Error(responseError)

      if (hasNewKey) {
        if (data && typeof data === 'object' && 'verified' in data && !data.verified) {
          throw new Error(t('ai.verificationFailed', 'La clau no ha passat la verificació'))
        }
      }

      await saveGenerationSettings(provider, false, false)

      toast({
        description: hasNewKey
          ? t('ai.keyVerifiedSaved', 'Clau verificada i desada per a {{provider}}', {
              provider: PROVIDER_LABELS[provider],
            })
          : t('ai.providerSaved', 'Configuració de {{provider}} desada', {
              provider: PROVIDER_LABELS[provider],
            }),
      })

      await invalidateAiTenantQueries(queryClient, tenantId)
      setProviderForms((prev) => ({
        ...prev,
        [provider]: { ...prev[provider], apiKey: '', model: modelToSave },
      }))
    } catch (err) {
      toast({ variant: 'destructive', description: err instanceof Error ? err.message : String(err) })
    } finally {
      setSavingProvider(null)
    }
  }

  async function refreshModels(provider: AiProvider) {
    if (!tenantId || !canManage) return
    const status = providerStatusMap.get(provider)
    if (!status?.configured) {
      toast({ variant: 'destructive', description: t('ai.refreshModelsNeedsKey', 'Cal una clau verificada') })
      return
    }

    setRefreshingModels(provider)
    try {
      const { data, error } = await supabase.functions.invoke('refresh-ai-models', {
        headers: { 'x-tenant-id': tenantId },
        body: { provider },
      })

      if (error) {
        const detailed = await getFunctionErrorMessage(error)
        throw new Error(detailed ?? error.message)
      }
      const responseError = getResponseErrorMessage(data)
      if (responseError) throw new Error(responseError)

      const count = typeof (data as { count?: number })?.count === 'number'
        ? (data as { count: number }).count
        : 0

      await invalidateAiTenantQueries(queryClient, tenantId)
      toast({
        description: t('ai.modelsRefreshed', '{{count}} models sincronitzats per a {{provider}}', {
          count,
          provider: PROVIDER_LABELS[provider],
        }),
      })
    } catch (err) {
      toast({ variant: 'destructive', description: err instanceof Error ? err.message : String(err) })
    } finally {
      setRefreshingModels(null)
    }
  }

  async function deleteProviderKey(provider: AiProvider) {
    if (!tenantId || !canManage) return
    if (!window.confirm(t('ai.deleteKeyConfirm', 'Vols eliminar la clau API d\'aquest proveïdor?'))) {
      return
    }

    setDeletingProvider(provider)
    try {
      const { data: { session } } = await supabase.auth.getSession()
      if (!session) throw new Error('No autenticat')

      const res = await fetch(
        `${FUNCTIONS_BASE}/save-tenant-api-key?provider=${encodeURIComponent(provider)}`,
        {
          method: 'DELETE',
          headers: {
            Authorization: `Bearer ${session.access_token}`,
            'x-tenant-id': tenantId,
          },
        },
      )

      const payload = await res.json().catch(() => null)
      if (!res.ok) {
        const message =
          (typeof payload?.error === 'object' && payload?.error?.message) ||
          (typeof payload?.error === 'string' ? payload.error : null) ||
          `HTTP ${res.status}`
        throw new Error(message)
      }

      await invalidateAiTenantQueries(queryClient, tenantId)
      toast({
        description: t('ai.keyDeleted', 'Clau eliminada per a {{provider}}', {
          provider: PROVIDER_LABELS[provider],
        }),
      })
    } catch (err) {
      toast({ variant: 'destructive', description: err instanceof Error ? err.message : String(err) })
    } finally {
      setDeletingProvider(null)
    }
  }

  function updateProviderForm(provider: AiProvider, patch: Partial<ProviderFormState>) {
    setProviderForms((prev) => ({
      ...prev,
      [provider]: { ...prev[provider], ...patch },
    }))
  }

  function updateGenerationForm(provider: AiProvider, patch: Partial<GenerationFormState>) {
    setGenerationForms((prev) => ({
      ...prev,
      [provider]: { ...prev[provider], ...patch },
    }))
  }

  function hasGenerationOverride(provider: AiProvider): boolean {
    const status = providerStatusMap.get(provider)
    return (
      status?.system_prompt_override != null
      || status?.temperature_override != null
      || status?.max_tokens_override != null
    )
  }

  async function saveGenerationSettings(
    provider: AiProvider,
    usePlatformDefaults = false,
    showToast = true,
  ) {
    if (!tenantId || !canManage) return

    const status = providerStatusMap.get(provider)
    const form = generationForms[provider]
    const platformTemp = status?.platform_temperature ?? 0.2
    const platformTokens = status?.platform_max_tokens ?? 4096
    const platformPrompt = status?.platform_system_prompt ?? ''

    setSavingGeneration(provider)
    try {
      if (usePlatformDefaults) {
        await saveTenantAiProviderGenerationSettings({
          tenantId,
          provider,
          usePlatformDefaults: true,
        })
        setGenerationForms((prev) => ({
          ...prev,
          [provider]: {
            systemPrompt: platformPrompt,
            temperature: String(platformTemp),
            maxTokens: String(platformTokens),
          },
        }))
      } else {
        const temperature = Number(form.temperature)
        const maxTokens = Number(form.maxTokens)
        if (!Number.isFinite(temperature) || temperature < 0 || temperature > 1) {
          throw new Error(t('ai.temperatureInvalid', 'La temperatura ha d\'estar entre 0 i 1'))
        }
        if (!Number.isFinite(maxTokens) || maxTokens < 1) {
          throw new Error(t('ai.maxTokensInvalid', 'Els tokens màxims han de ser un enter positiu'))
        }

        const systemPromptTrimmed = form.systemPrompt.trim()
        const matchesPlatform =
          systemPromptTrimmed === (platformPrompt ?? '').trim()
          && temperature === platformTemp
          && maxTokens === platformTokens

        await saveTenantAiProviderGenerationSettings({
          tenantId,
          provider,
          systemPrompt: matchesPlatform ? null : (systemPromptTrimmed || null),
          temperature: matchesPlatform ? null : temperature,
          maxTokens: matchesPlatform ? null : maxTokens,
        })
      }

      await invalidateAiTenantQueries(queryClient, tenantId)
      if (showToast) {
        toast({
          description: usePlatformDefaults
            ? t('ai.generationReset', 'Paràmetres de {{provider}} restablerts als valors de plataforma', {
                provider: PROVIDER_LABELS[provider],
              })
            : t('ai.generationSaved', 'Paràmetres de generació desats per a {{provider}}', {
                provider: PROVIDER_LABELS[provider],
              }),
        })
      }
    } catch (err) {
      toast({ variant: 'destructive', description: err instanceof Error ? err.message : String(err) })
    } finally {
      setSavingGeneration(null)
    }
  }

  function resetGenerationToPlatform(provider: AiProvider) {
    const status = providerStatusMap.get(provider)
    updateGenerationForm(provider, {
      systemPrompt: status?.platform_system_prompt ?? '',
      temperature: String(status?.platform_temperature ?? 0.2),
      maxTokens: String(status?.platform_max_tokens ?? 4096),
    })
    void saveGenerationSettings(provider, true)
  }

  const defaultConfigured = providerStatusMap.get(defaultProvider)?.configured ?? false
  const defaultServiceModel =
    providerForms[defaultProvider]?.model?.trim() || DEFAULT_MODELS[defaultProvider]

  function renderProviderNav() {
    return (
      <AiProviderNav
        providers={PROVIDERS}
        labels={PROVIDER_LABELS}
        active={activeProvider}
        configured={providerConfigured}
        defaultProvider={defaultProvider}
        onSelect={setActiveProvider}
      />
    )
  }

  function renderActiveProviderPanel(options?: { showConnectionTest?: boolean }) {
    const provider = activeProvider
    const status = providerStatusMap.get(provider)
    const configured = status?.configured ?? false
    const verifiedAt = formatVerifiedAt(status?.key_verified_at)
    const modelsSyncedAt = formatVerifiedAt(status?.last_models_sync_at)
    const lastError = status?.key_last_error
    const isDefault = defaultProvider === provider
    const form = providerForms[provider]
    const generationForm = generationForms[provider]
    const availableModels = status?.available_models ?? []
    const suggestedModels = status?.suggested_models ?? []
    const usesPlatformGeneration = !hasGenerationOverride(provider)

    return (
      <section className="flex-1 min-w-0 rounded-2xl border bg-card p-6 space-y-4">
        <div className="flex items-start justify-between gap-4">
          <div>
            <div className="flex items-center gap-2">
              <h3 className="text-base font-semibold text-foreground">{PROVIDER_LABELS[provider]}</h3>
              {isDefault && (
                <span className="text-xs font-medium text-indigo-700 bg-indigo-50 px-2 py-0.5 rounded-full">
                  {t('ai.defaultBadge', 'Per defecte')}
                </span>
              )}
            </div>
            <div className="flex items-center gap-1.5 mt-1">
              {configured ? (
                <CheckCircle2 className="h-4 w-4 text-emerald-600" />
              ) : (
                <Circle className="h-4 w-4 text-muted-foreground" />
              )}
              <p className="text-sm text-muted-foreground">
                {configured
                  ? t('ai.keyVerified', 'Clau verificada{{date}}', {
                      date: verifiedAt ? ` (${verifiedAt})` : '',
                    })
                  : status?.has_key
                    ? t('ai.keyUnverified', 'Clau sense verificar')
                    : t('ai.keyNotConfigured', 'Sense clau')}
              </p>
            </div>
            <p className="text-sm text-muted-foreground mt-1">
              {t('ai.defaultModelLabel', 'Model per defecte')}:{' '}
              <span className="font-mono">
                {form.model?.trim() || DEFAULT_MODELS[provider]}
              </span>
            </p>
            {modelsSyncedAt && (
              <p className="text-xs text-muted-foreground mt-1">
                {t('ai.modelsSyncedAt', 'Models sincronitzats: {{date}}', { date: modelsSyncedAt })}
              </p>
            )}
            {status?.billing_url && (
              <a
                href={status.billing_url}
                target="_blank"
                rel="noopener noreferrer"
                className="text-xs text-indigo-700 hover:underline mt-1 inline-block"
              >
                {t('ai.billingLink', 'Gestiona facturació al panell de {{provider}}', {
                  provider: PROVIDER_LABELS[provider],
                })}
              </a>
            )}
            {lastError && !configured && (
              <p className="text-xs text-red-700 bg-red-50 border border-red-200 rounded-lg px-3 py-2 mt-2 flex items-start gap-2">
                <AlertCircle className="h-4 w-4 shrink-0 mt-0.5" />
                <span>{lastError}</span>
              </p>
            )}
          </div>
        </div>

        {options?.showConnectionTest ? (
          configured && tenantId ? (
            <AiConnectionTest
              tenantId={tenantId}
              provider={provider}
              model={pickDefaultAmongAllowed(
                form.model,
                availableModels,
                enabledModelsForms[provider],
                DEFAULT_MODELS[provider],
              )}
              systemPrompt={generationForm.systemPrompt}
              temperature={Number(generationForm.temperature) || 0.2}
              maxTokens={Number(generationForm.maxTokens) || 4096}
              embedded
            />
          ) : (
            <p className="text-sm text-muted-foreground">
              {t('ai.connectionTestNeedsKey', 'Configura i verifica la clau API abans de provar la connexió.')}
            </p>
          )
        ) : (
          <>
            <AiSettingsSection
              title={t('ai.sectionConnection', 'Connexió')}
              description={t('ai.sectionConnectionHint', 'Clau API i URL base del proveïdor.')}
              defaultOpen
            >
              <label className="space-y-1 block">
                <span className="text-sm text-foreground">{t('ai.apiKey', 'API key')}</span>
                <input
                  value={form.apiKey}
                  disabled={!canManage}
                  type="password"
                  onChange={(e) => updateProviderForm(provider, { apiKey: e.target.value })}
                  className="h-9 w-full rounded-md border bg-background px-3 text-sm"
                  placeholder={
                    configured || status?.has_key
                      ? t('ai.apiKeyKeepHint', 'Deixa en blanc per mantenir la clau actual')
                      : t('ai.apiKey_hint', 'Pega la teva API key aquí')
                  }
                />
              </label>
              <label className="space-y-1 block">
                <span className="text-sm text-foreground">{t('ai.baseUrl', 'Base URL (opcional)')}</span>
                <input
                  value={form.baseUrl}
                  disabled={!canManage}
                  onChange={(e) => updateProviderForm(provider, { baseUrl: e.target.value })}
                  className="h-9 w-full rounded-md border bg-background px-3 text-sm"
                  placeholder={DEFAULT_BASE_URLS[provider]}
                />
              </label>
            </AiSettingsSection>

            <AiSettingsSection
              title={t('ai.sectionModels', 'Models')}
              description={
                provider === 'openrouter'
                  ? t('ai.openrouterModelHint', 'Format proveïdor/model (p.ex. openai/gpt-4o-mini). Una sola clau dona accés a centenars de models.')
                  : t('ai.sectionModelsHint', 'Marca quins models poden usar els membres i quin és el per defecte.')
              }
              defaultOpen
            >
              <AiProviderModelsPanel
                availableModels={availableModels}
                suggestedModels={suggestedModels}
                enabledModels={enabledModelsForms[provider]}
                defaultModel={form.model}
                placeholder={DEFAULT_MODELS[provider]}
                disabled={!canManage}
                onEnabledChange={(models) =>
                  setEnabledModelsForms((prev) => ({ ...prev, [provider]: models }))
                }
                onDefaultChange={(model) => updateProviderForm(provider, { model })}
                onRefresh={configured && canManage ? () => void refreshModels(provider) : undefined}
                refreshing={refreshingModels === provider}
              />
            </AiSettingsSection>

            <AiSettingsSection
              title={t('ai.generationParamsTitle', 'Paràmetres de generació')}
              description={t('ai.generationParamsDescription', 'Controlen com es comporta el model en cada crida. Per defecte s\'hereten dels valors configurats al portal d\'administració.')}
              defaultOpen={false}
            >
              {usesPlatformGeneration && (
                <p className="text-xs text-indigo-700 bg-indigo-50 border border-indigo-100 rounded-lg px-2.5 py-1.5">
                  {t('ai.usingPlatformDefaults', 'Aquest proveïdor usa els valors per defecte de la plataforma.')}
                </p>
              )}
              <label className="space-y-1 block">
                <span className="text-sm text-foreground">{t('ai.systemPrompt', 'Prompt de sistema')}</span>
                <textarea
                  value={generationForm.systemPrompt}
                  disabled={!canManage}
                  onChange={(e) => updateGenerationForm(provider, { systemPrompt: e.target.value })}
                  rows={4}
                  className="w-full rounded-md border bg-background px-3 py-2 text-sm resize-y min-h-[88px]"
                  placeholder={status?.platform_system_prompt ?? t('ai.systemPromptPlaceholder', 'Sense prompt de sistema')}
                />
              </label>
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <label className="space-y-1">
                  <span className="text-sm text-foreground">{t('ai.temperature', 'Temperatura')}</span>
                  <input
                    type="number"
                    min={0}
                    max={1}
                    step={0.05}
                    value={generationForm.temperature}
                    disabled={!canManage}
                    onChange={(e) => updateGenerationForm(provider, { temperature: e.target.value })}
                    className="h-9 w-full rounded-md border bg-background px-3 text-sm"
                  />
                </label>
                <label className="space-y-1">
                  <span className="text-sm text-foreground">{t('ai.maxTokens', 'Màx. tokens')}</span>
                  <input
                    type="number"
                    min={1}
                    value={generationForm.maxTokens}
                    disabled={!canManage}
                    onChange={(e) => updateGenerationForm(provider, { maxTokens: e.target.value })}
                    className="h-9 w-full rounded-md border bg-background px-3 text-sm"
                  />
                </label>
              </div>
              {canManage && (
                <div className="flex justify-end">
                  <button
                    type="button"
                    onClick={() => resetGenerationToPlatform(provider)}
                    disabled={savingGeneration === provider || savingProvider === provider}
                    className="inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground disabled:opacity-50"
                  >
                    {t('ai.resetGenerationToPlatform', 'Restablir valors de plataforma')}
                  </button>
                </div>
              )}
            </AiSettingsSection>

            <div className="flex justify-between items-center pt-2 border-t gap-2 flex-wrap">
              {(configured || status?.has_key) && canManage && (
                <button
                  type="button"
                  onClick={() => void deleteProviderKey(provider)}
                  disabled={deletingProvider === provider}
                  className="inline-flex items-center gap-2 text-sm text-destructive hover:text-destructive/80 disabled:opacity-50"
                >
                  <Trash2 className="h-4 w-4" />
                  {deletingProvider === provider
                    ? t('ai.deleting', 'Eliminant...')
                    : t('ai.deleteKey', 'Eliminar clau')}
                </button>
              )}
              <button
                type="button"
                onClick={() => void saveProvider(provider)}
                disabled={!canManage || savingProvider === provider}
                className="inline-flex items-center gap-2 bg-indigo-600 hover:bg-indigo-700 disabled:opacity-50 text-white text-sm font-medium px-4 py-2 rounded-lg transition ml-auto"
              >
                <Save className="h-4 w-4" />
                {savingProvider === provider
                  ? t('ai.verifying', 'Verificant...')
                  : form.apiKey.trim()
                    ? t('ai.verifyAndSave', 'Verificar i desar')
                    : t('ai.saveProvider', 'Desar {{provider}}', { provider: PROVIDER_LABELS[provider] })}
              </button>
            </div>
          </>
        )}
      </section>
    )
  }

  const configTab = (
    <div className="space-y-6">
      <section className="rounded-2xl border bg-card p-6 space-y-4">
        <div className="flex items-start gap-3">
          <Sparkles className="h-5 w-5 text-indigo-600 mt-0.5 shrink-0" />
          <div className="space-y-1">
            <h3 className="text-base font-semibold text-foreground">
              {t('ai.defaultProvider', 'Proveïdor per defecte')}
            </h3>
            <p className="text-sm text-muted-foreground">
              {isLoading
                ? t('ai.loading', 'Carregant...')
                : config?.configured
                  ? t('ai.ready', 'El wizard utilitzarà {{provider}} amb el model configurat.', {
                      provider: PROVIDER_LABELS[defaultProvider],
                    })
                  : t('ai.notReady', 'Encara no hi ha cap proveïdor per defecte amb clau verificada.')}
            </p>
          </div>
        </div>

        {!canManage && (
          <p className="text-sm text-muted-foreground italic">
            {t('ai.read_only', 'Només els gestors i propietaris poden modificar aquesta configuració.')}
          </p>
        )}

        <div className="flex flex-col sm:flex-row sm:items-end gap-3">
          <label className="space-y-1 flex-1">
            <span className="text-sm text-foreground">{t('ai.defaultProviderLabel', 'Servei actiu')}</span>
            <select
              value={defaultProvider}
              disabled={!canManage}
              onChange={(e) => setDefaultProvider(e.target.value as AiProvider)}
              className="h-9 w-full rounded-md border bg-background px-3 text-sm"
            >
              {PROVIDERS.map((provider) => (
                <option key={provider} value={provider}>
                  {PROVIDER_LABELS[provider]}
                  {(providerStatusMap.get(provider)?.configured ?? false) ? ' ✓' : ''}
                </option>
              ))}
            </select>
          </label>

          <button
            type="button"
            onClick={() => void saveDefaultMutation.mutateAsync()}
            disabled={!canManage || saveDefaultMutation.isPending}
            className="inline-flex items-center justify-center gap-2 bg-indigo-600 hover:bg-indigo-700 disabled:opacity-50 text-white text-sm font-medium px-4 py-2 rounded-lg transition h-9 shrink-0"
          >
            <Save className="h-4 w-4" />
            {saveDefaultMutation.isPending ? t('ai.saving', 'Desant...') : t('ai.saveDefault', 'Desar per defecte')}
          </button>
        </div>

        <p className="text-sm text-muted-foreground">
          {t('ai.defaultModelLabel', 'Model per defecte')}:{' '}
          <span className="font-mono">{defaultServiceModel}</span>
        </p>

        {!defaultConfigured && canManage && !isLoading && (
          <p className="text-xs text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2">
            {t(
              'ai.defaultMissingKey',
              'El proveïdor seleccionat encara no té clau verificada. Configura\'l a continuació abans d\'executar el wizard.',
            )}
          </p>
        )}

        {config?.configured && (
          <label className="flex items-start gap-3 rounded-lg border px-4 py-3 bg-muted/20">
            <input
              type="checkbox"
              className="mt-1"
              checked={!!config.analytics_cron_enabled}
              disabled={!canManage || savingAnalyticsCron}
              onChange={async (e) => {
                if (!tenantId) return
                setSavingAnalyticsCron(true)
                try {
                  await setAiAnalyticsCronEnabled(tenantId, e.target.checked)
                  await invalidateAiTenantQueries(queryClient, tenantId)
                  toast({
                    description: e.target.checked
                      ? t('ai.analyticsCronEnabled', 'Analítica proactiva activada (revisió diària d\'empleats).')
                      : t('ai.analyticsCronDisabled', 'Analítica proactiva desactivada.'),
                  })
                } catch (err) {
                  toast({
                    variant: 'destructive',
                    description: err instanceof Error ? err.message : String(err),
                  })
                } finally {
                  setSavingAnalyticsCron(false)
                }
              }}
            />
            <span className="space-y-1">
              <span className="text-sm font-medium text-foreground block">
                {t('ai.analyticsCronTitle', 'Analítica proactiva (pilot)')}
              </span>
              <span className="text-xs text-muted-foreground block">
                {t(
                  'ai.analyticsCronHint',
                  'Cada dia el sistema revisa dades d\'empleats i t\'envia una alerta in-app si detecta anomalies. Consumeix tokens del teu límit diari.',
                )}
              </span>
            </span>
          </label>
        )}
      </section>

      <div className="flex flex-col lg:flex-row gap-6">
        {renderProviderNav()}
        {renderActiveProviderPanel()}
      </div>
    </div>
  )

  const connectionTestTab = (
    <div className="space-y-4">
      <p className="text-sm text-muted-foreground">
        {t('ai.connectionTestTabHint', 'Prova la connexió amb els valors del formulari de configuració (no cal desar abans).')}
      </p>
      <div className="flex flex-col lg:flex-row gap-6">
        {renderProviderNav()}
        {renderActiveProviderPanel({ showConnectionTest: true })}
      </div>
    </div>
  )

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-lg font-semibold text-foreground">
          {t('ai.title', 'Generació de documents amb IA')}
        </h2>
        <p className="text-sm text-muted-foreground mt-0.5">
          {t(
            'ai.description',
            'Configura les claus per proveïdor i tria quin servei s\'utilitza per defecte a les eines d\'IA de l\'aplicació.',
          )}
        </p>
      </div>

      <div className="rounded-xl border border-amber-200 bg-amber-50/80 px-4 py-3 flex gap-3">
        <ShieldAlert className="h-5 w-5 text-amber-800 shrink-0 mt-0.5" />
        <div className="space-y-1 text-sm text-amber-950">
          <p className="font-medium">{t('ai.dataPolicyTitle', 'Polítiques de dades i responsabilitat')}</p>
          <p className="text-amber-900/90 leading-relaxed">
            {t(
              'ai.dataPolicyDescription',
              'Les dades que envieu a la IA (textos, prompts, documents) es transmeten directament al proveïdor que configureu (OpenAI, Anthropic, Gemini, OpenRouter, etc.). La plataforma actua com a intermediari tècnic i no controla com cada proveïdor emmagatzema, processa ni utilitza aquestes dades. És responsabilitat del tenant revisar i acceptar les polítiques de privacitat, retenció i ús de dades de cada proveïdor abans d\'activar la IA per als seus usuaris.',
            )}
          </p>
        </div>
      </div>

      <Tabs defaultValue="config">
        <TabsList>
          <TabsTrigger value="config">{t('ai.tabConfig', 'Configuració')}</TabsTrigger>
          <TabsTrigger value="test">{t('ai.tabConnectionTest', 'Prova de connexió')}</TabsTrigger>
          <TabsTrigger value="usage">{t('ai.tabUsage', 'Ús i límits')}</TabsTrigger>
          {isOwner && (
            <TabsTrigger value="members">{t('ai.tabMembers', 'Membres')}</TabsTrigger>
          )}
        </TabsList>
        <TabsContent value="config" className="mt-4">
          {configTab}
        </TabsContent>
        <TabsContent value="test" className="mt-4">
          {connectionTestTab}
        </TabsContent>
        <TabsContent value="usage" className="mt-4">
          {tenantId ? <AiUsageDashboard tenantId={tenantId} canManage={canManage} /> : null}
        </TabsContent>
        {isOwner && (
          <TabsContent value="members" className="mt-4">
            {tenantId ? <AiUserPoliciesPanel tenantId={tenantId} /> : null}
          </TabsContent>
        )}
      </Tabs>
    </div>
  )
}
