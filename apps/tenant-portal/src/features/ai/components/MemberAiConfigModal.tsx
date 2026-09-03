import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Sparkles } from 'lucide-react'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import { Label } from '@/components/ui/label'
import { useToast } from '@/hooks/use-toast'
import {
  deleteAiUserPolicy,
  fetchAiConfigForTenant,
  fetchAiUserPolicies,
  setAiUserPolicy,
} from '@/features/ai/api/aiRpc'
import type { AiProvider, AiUserPolicy, AiUserPolicyRow } from '@/features/ai/types/rpc'
import { effectiveEnabledModels } from '@/features/ai/utils/aiModels'

const PROVIDER_LABELS: Record<AiProvider, string> = {
  openai: 'OpenAI',
  anthropic: 'Anthropic',
  gemini: 'Google Gemini',
  openrouter: 'OpenRouter',
}

type AiAccessMode = 'inherit' | 'enabled' | 'disabled'
type ModelsMode = 'inherit' | 'custom'

type ProviderModelsEdit = {
  mode: ModelsMode
  models: string[]
}

type MemberAiConfigModalProps = {
  open: boolean
  onOpenChange: (open: boolean) => void
  tenantId: string
  member: {
    user_id: string
    email: string
    full_name: string | null
    role: string
  }
}

function aiAccessFromDb(value: boolean | null | undefined): AiAccessMode {
  if (value === true) return 'enabled'
  if (value === false) return 'disabled'
  return 'inherit'
}

function aiAccessToDb(mode: AiAccessMode): boolean | null {
  if (mode === 'inherit') return null
  return mode === 'enabled'
}

function parseProviderModels(
  allowedModels: Partial<Record<AiProvider, string[]>> | undefined,
  provider: AiProvider,
): ProviderModelsEdit {
  const custom = allowedModels?.[provider]
  if (Array.isArray(custom) && custom.length > 0) {
    return { mode: 'custom', models: custom }
  }
  return { mode: 'inherit', models: [] }
}

function serializeAllowedModels(
  edits: Partial<Record<AiProvider, ProviderModelsEdit>>,
): Partial<Record<AiProvider, string[]>> {
  const out: Partial<Record<AiProvider, string[]>> = {}
  for (const [provider, edit] of Object.entries(edits) as Array<[AiProvider, ProviderModelsEdit]>) {
    if (edit?.mode === 'custom' && edit.models.length > 0) {
      out[provider] = edit.models
    }
  }
  return out
}

function hasCustomPolicy(row: AiUserPolicyRow | null): boolean {
  if (!row) return false
  return (
    row.policy !== 'allow'
    || row.custom_hourly_limit != null
    || row.custom_daily_limit != null
    || row.custom_tokens_daily_limit != null
    || row.ai_enabled != null
    || Object.keys(row.allowed_models ?? {}).some((key) => {
      const models = row.allowed_models?.[key as AiProvider]
      return Array.isArray(models) && models.length > 0
    })
    || Boolean(row.notes?.trim())
  )
}

export function MemberAiConfigModal({
  open,
  onOpenChange,
  tenantId,
  member,
}: MemberAiConfigModalProps) {
  const { t } = useTranslation('settings')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  const [aiAccess, setAiAccess] = useState<AiAccessMode>('inherit')
  const [policy, setPolicy] = useState<AiUserPolicy>('allow')
  const [customHourly, setCustomHourly] = useState('')
  const [customDaily, setCustomDaily] = useState('')
  const [customTokensDaily, setCustomTokensDaily] = useState('')
  const [notes, setNotes] = useState('')
  const [providerEdits, setProviderEdits] = useState<Partial<Record<AiProvider, ProviderModelsEdit>>>({})

  const { data: aiConfig, isLoading: configLoading } = useQuery({
    queryKey: ['ai_config', tenantId],
    enabled: open && !!tenantId,
    queryFn: () => fetchAiConfigForTenant(tenantId),
  })

  const { data: policyRows = [], isLoading: policiesLoading } = useQuery({
    queryKey: ['ai_user_policies', tenantId],
    enabled: open && !!tenantId,
    queryFn: () => fetchAiUserPolicies(tenantId),
  })

  const policyRow = useMemo(
    () => policyRows.find((row) => row.user_id === member.user_id) ?? null,
    [policyRows, member.user_id],
  )

  const configuredProviders = useMemo(
    () => (aiConfig?.providers ?? []).filter((provider) => provider.configured && provider.verified),
    [aiConfig?.providers],
  )

  useEffect(() => {
    if (!open || policiesLoading || configLoading) return

    setAiAccess(aiAccessFromDb(policyRow?.ai_enabled))
    setPolicy(policyRow?.policy ?? 'allow')
    setCustomHourly(policyRow?.custom_hourly_limit?.toString() ?? '')
    setCustomDaily(policyRow?.custom_daily_limit?.toString() ?? '')
    setCustomTokensDaily(policyRow?.custom_tokens_daily_limit?.toString() ?? '')
    setNotes(policyRow?.notes ?? '')

    const nextEdits: Partial<Record<AiProvider, ProviderModelsEdit>> = {}
    for (const provider of configuredProviders) {
      nextEdits[provider.provider] = parseProviderModels(policyRow?.allowed_models, provider.provider)
    }
    setProviderEdits(nextEdits)
  }, [open, policiesLoading, configLoading, policyRow, configuredProviders])

  const saveMutation = useMutation({
    mutationFn: async () => {
      await setAiUserPolicy({
        tenantId,
        userId: member.user_id,
        policy,
        customHourlyLimit: customHourly ? Number(customHourly) : null,
        customDailyLimit: customDaily ? Number(customDaily) : null,
        customTokensDailyLimit: customTokensDaily ? Number(customTokensDaily) : null,
        aiEnabled: aiAccessToDb(aiAccess),
        allowedModels: serializeAllowedModels(providerEdits),
        notes: notes.trim() || null,
      })
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['ai_user_policies', tenantId] })
      toast({ description: t('ai.memberAiSaved', 'Configuració IA desada') })
      onOpenChange(false)
    },
    onError: (err) => {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : String(err),
      })
    },
  })

  const resetMutation = useMutation({
    mutationFn: async () => deleteAiUserPolicy(tenantId, member.user_id),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['ai_user_policies', tenantId] })
      toast({ description: t('ai.memberAiReset', 'Configuració IA restablerta (hereta del tenant)') })
      onOpenChange(false)
    },
    onError: (err) => {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : String(err),
      })
    },
  })

  function updateProviderModels(provider: AiProvider, patch: Partial<ProviderModelsEdit>) {
    setProviderEdits((prev) => ({
      ...prev,
      [provider]: {
        mode: 'inherit',
        models: [],
        ...prev[provider],
        ...patch,
      },
    }))
  }

  function toggleProviderModel(provider: AiProvider, modelId: string, checked: boolean) {
    const current = providerEdits[provider] ?? { mode: 'custom' as const, models: [] }
    const base = current.mode === 'inherit' ? [] : [...current.models]
    const next = checked
      ? [...new Set([...base, modelId])]
      : base.filter((id) => id !== modelId)
    updateProviderModels(provider, { mode: 'custom', models: next })
  }

  const loading = configLoading || policiesLoading
  const isBusy = saveMutation.isPending || resetMutation.isPending

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-2xl max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <Sparkles className="h-5 w-5 text-indigo-600" />
            {t('ai.memberAiTitle', 'Configuració IA')}
          </DialogTitle>
          <DialogDescription>
            {member.full_name || member.email}
            <span className="text-muted-foreground"> · {member.email} · {member.role}</span>
          </DialogDescription>
        </DialogHeader>

        {loading ? (
          <p className="text-sm text-muted-foreground">{t('ai.loading', 'Carregant...')}</p>
        ) : !aiConfig?.configured ? (
          <p className="text-sm text-muted-foreground">
            {t('ai.memberAiNotConfigured', 'La IA no està configurada per a aquest tenant. Configura-la primer a Configuració → IA.')}
          </p>
        ) : (
          <div className="space-y-6">
            <section className="space-y-3">
              <h3 className="text-sm font-semibold">{t('ai.memberAiAccessTitle', 'Accés a la IA')}</h3>
              <div className="grid gap-2 sm:grid-cols-3">
                {(['inherit', 'enabled', 'disabled'] as const).map((mode) => (
                  <label
                    key={mode}
                    className="flex items-start gap-2 rounded-lg border p-3 cursor-pointer has-[:checked]:border-indigo-500 has-[:checked]:bg-indigo-50/50"
                  >
                    <input
                      type="radio"
                      name="ai-access"
                      checked={aiAccess === mode}
                      onChange={() => setAiAccess(mode)}
                      className="mt-0.5"
                    />
                    <span>
                      <span className="block text-sm font-medium">
                        {mode === 'inherit'
                          ? t('ai.memberAiAccessInherit', 'Hereta del tenant')
                          : mode === 'enabled'
                            ? t('ai.memberAiAccessEnabled', 'Habilitada')
                            : t('ai.memberAiAccessDisabled', 'Deshabilitada')}
                      </span>
                      <span className="block text-xs text-muted-foreground mt-0.5">
                        {mode === 'inherit'
                          ? t('ai.memberAiAccessInheritHint', 'Segueix la configuració global del tenant')
                          : mode === 'enabled'
                            ? t('ai.memberAiAccessEnabledHint', 'Força l\'accés encara que el tenant estigui limitat')
                            : t('ai.memberAiAccessDisabledHint', 'Bloqueja l\'accés al xat i eines IA')}
                      </span>
                    </span>
                  </label>
                ))}
              </div>
            </section>

            <section className="space-y-3">
              <h3 className="text-sm font-semibold">{t('ai.memberAiPolicyTitle', 'Política i límits')}</h3>
              <div className="grid gap-3 sm:grid-cols-2">
                <div className="space-y-1.5">
                  <Label htmlFor="member-ai-policy">{t('ai.policy', 'Política')}</Label>
                  <select
                    id="member-ai-policy"
                    value={policy}
                    onChange={(e) => setPolicy(e.target.value as AiUserPolicy)}
                    className="h-9 w-full rounded-md border bg-background px-2 text-sm"
                  >
                    <option value="allow">{t('ai.policyAllow', 'Permetre')}</option>
                    <option value="warn_only">{t('ai.policyWarn', 'Avís')}</option>
                    <option value="block">{t('ai.policyBlock', 'Bloquejar')}</option>
                  </select>
                </div>
                <div className="space-y-1.5">
                  <Label htmlFor="member-ai-tokens-day">{t('ai.memberAiTokensDay', 'Límit tokens/dia')}</Label>
                  <input
                    id="member-ai-tokens-day"
                    type="number"
                    min={1}
                    value={customTokensDaily}
                    onChange={(e) => setCustomTokensDaily(e.target.value)}
                    placeholder={t('ai.memberAiInheritPlaceholder', 'Hereta')}
                    className="h-9 w-full rounded-md border bg-background px-2 text-sm"
                  />
                </div>
                <div className="space-y-1.5">
                  <Label htmlFor="member-ai-hourly">{t('ai.customHourly', 'Límit/h')}</Label>
                  <input
                    id="member-ai-hourly"
                    type="number"
                    min={1}
                    value={customHourly}
                    onChange={(e) => setCustomHourly(e.target.value)}
                    placeholder={t('ai.memberAiInheritPlaceholder', 'Hereta')}
                    className="h-9 w-full rounded-md border bg-background px-2 text-sm"
                  />
                </div>
                <div className="space-y-1.5">
                  <Label htmlFor="member-ai-daily">{t('ai.customDaily', 'Límit/dia')}</Label>
                  <input
                    id="member-ai-daily"
                    type="number"
                    min={1}
                    value={customDaily}
                    onChange={(e) => setCustomDaily(e.target.value)}
                    placeholder={t('ai.memberAiInheritPlaceholder', 'Hereta')}
                    className="h-9 w-full rounded-md border bg-background px-2 text-sm"
                  />
                </div>
              </div>
              <div className="space-y-1.5">
                <Label htmlFor="member-ai-notes">{t('ai.notes', 'Notes')}</Label>
                <input
                  id="member-ai-notes"
                  value={notes}
                  onChange={(e) => setNotes(e.target.value)}
                  className="h-9 w-full rounded-md border bg-background px-2 text-sm"
                />
              </div>
            </section>

            <section className="space-y-3">
              <div>
                <h3 className="text-sm font-semibold">{t('ai.memberAiModelsTitle', 'Models permesos')}</h3>
                <p className="text-xs text-muted-foreground mt-1">
                  {t('ai.memberAiModelsHint', 'Per proveïdor: hereta la whitelist del tenant o tria models concrets.')}
                </p>
              </div>

              {configuredProviders.length === 0 ? (
                <p className="text-sm text-muted-foreground">
                  {t('ai.memberAiNoProviders', 'No hi ha cap proveïdor verificat al tenant.')}
                </p>
              ) : (
                <div className="space-y-4">
                  {configuredProviders.map((providerStatus) => {
                    const provider = providerStatus.provider
                    const edit = providerEdits[provider] ?? { mode: 'inherit', models: [] }
                    const tenantModels = effectiveEnabledModels(
                      providerStatus.available_models ?? [],
                      providerStatus.enabled_models ?? [],
                    )

                    return (
                      <div key={provider} className="rounded-lg border p-3 space-y-3">
                        <div className="flex items-center justify-between gap-2">
                          <p className="text-sm font-medium">{PROVIDER_LABELS[provider]}</p>
                          <label className="flex items-center gap-2 text-xs text-muted-foreground">
                            <input
                              type="radio"
                              checked={edit.mode === 'inherit'}
                              onChange={() => updateProviderModels(provider, { mode: 'inherit', models: [] })}
                            />
                            {t('ai.memberAiModelsInherit', 'Hereta')}
                          </label>
                          <label className="flex items-center gap-2 text-xs text-muted-foreground">
                            <input
                              type="radio"
                              checked={edit.mode === 'custom'}
                              onChange={() => updateProviderModels(provider, {
                                mode: 'custom',
                                models: edit.models.length > 0 ? edit.models : tenantModels.slice(0, 1),
                              })}
                            />
                            {t('ai.memberAiModelsCustom', 'Personalitzat')}
                          </label>
                        </div>

                        {edit.mode === 'custom' && (
                          <div className="max-h-40 overflow-y-auto space-y-2 pl-1">
                            {tenantModels.length === 0 ? (
                              <p className="text-xs text-muted-foreground">
                                {t('ai.enabledModelsEmpty', 'Sincronitza els models del proveïdor per configurar la whitelist.')}
                              </p>
                            ) : (
                              tenantModels.map((modelId) => (
                                <label key={modelId} className="flex items-center gap-2 text-sm">
                                  <Checkbox
                                    checked={edit.models.includes(modelId)}
                                    onCheckedChange={(checked) =>
                                      toggleProviderModel(provider, modelId, checked === true)
                                    }
                                  />
                                  <span className="font-mono text-xs">{modelId}</span>
                                </label>
                              ))
                            )}
                          </div>
                        )}
                      </div>
                    )
                  })}
                </div>
              )}
            </section>
          </div>
        )}

        <DialogFooter className="gap-2 sm:gap-0">
          {hasCustomPolicy(policyRow) && (
            <Button
              type="button"
              variant="ghost"
              disabled={isBusy || loading}
              onClick={() => void resetMutation.mutateAsync()}
            >
              {t('ai.memberAiResetBtn', 'Restablir (hereta)')}
            </Button>
          )}
          <Button
            type="button"
            variant="outline"
            disabled={isBusy}
            onClick={() => onOpenChange(false)}
          >
            {t('ai.memberAiCancel', 'Cancel·lar')}
          </Button>
          <Button
            type="button"
            disabled={isBusy || loading || !aiConfig?.configured}
            onClick={() => void saveMutation.mutateAsync()}
          >
            {saveMutation.isPending ? t('ai.saving', 'Desant...') : t('ai.savePolicy', 'Desar')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
