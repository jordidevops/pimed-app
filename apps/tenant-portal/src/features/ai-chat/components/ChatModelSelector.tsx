import { useMemo, useState } from 'react'

import { Link } from 'react-router-dom'

import { FileText, Image, Loader2, Settings2, Wrench } from 'lucide-react'

import { useTranslation } from 'react-i18next'

import { Button } from '@/components/ui/button'

import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover'

import { AiModelSelect } from '@/features/ai/components/AiModelSelect'

import { AI_PROVIDER_LABELS } from '@/features/ai/hooks/useAiGenerationConfig'

import type { AiProvider, AiProviderStatus } from '@/features/ai/types/rpc'

import type { ResolvedModelCapabilities } from '@/features/ai-chat/utils/modelCapabilities'



type ChatModelSelectorProps = {

  provider: AiProvider

  model: string

  modelOptions: string[]

  suggestedModels?: string[]

  capabilities?: ResolvedModelCapabilities | null

  locked?: boolean

  disabled?: boolean

  isLoading?: boolean

  configuredProviders: AiProvider[]

  defaultProvider: AiProvider

  getProviderStatus: (provider: AiProvider) => AiProviderStatus | undefined

  onProviderChange?: (provider: AiProvider) => void

  onModelChange?: (model: string) => void

}



function CapabilityBadges({ caps }: { caps: ResolvedModelCapabilities }) {

  const { t } = useTranslation('chat')

  return (

    <div className="flex flex-wrap gap-1.5">

      {caps.vision && (

        <span className="inline-flex items-center gap-1 text-[11px] rounded-full bg-emerald-50 text-emerald-800 border border-emerald-200 px-2 py-0.5">

          <Image className="h-3 w-3" />

          {t('capabilityVision', 'Imatges')}

        </span>

      )}

      {caps.vision && caps.supportedFileMimes.includes('application/pdf') && (
        <span className="inline-flex items-center gap-1 text-[11px] rounded-full bg-sky-50 text-sky-800 border border-sky-200 px-2 py-0.5">
          <FileText className="h-3 w-3" />
          {t('capabilityPdf', 'PDF')}
        </span>
      )}

      {caps.tools && (

        <span className="inline-flex items-center gap-1 text-[11px] rounded-full bg-indigo-50 text-indigo-800 border border-indigo-200 px-2 py-0.5">

          <Wrench className="h-3 w-3" />

          {t('capabilityTools', 'Eines')}

        </span>

      )}

      {caps.vision && caps.tools && !caps.toolsWithVision && (

        <span className="text-[11px] text-amber-800 bg-amber-50 border border-amber-200 rounded-full px-2 py-0.5">

          {t('capabilityToolsVisionSplit', 'Eines sense imatges al mateix missatge')}

        </span>

      )}

    </div>

  )

}



export function ChatModelSelector({

  provider,

  model,

  modelOptions,

  suggestedModels = [],

  capabilities = null,

  locked = false,

  disabled = false,

  isLoading = false,

  configuredProviders,

  defaultProvider,

  getProviderStatus,

  onProviderChange,

  onModelChange,

}: ChatModelSelectorProps) {

  const { t } = useTranslation('chat')

  const { t: ts } = useTranslation('settings')

  const [open, setOpen] = useState(false)



  const summary = useMemo(() => {

    const providerLabel = AI_PROVIDER_LABELS[provider]

    const modelLabel = model || ts('ai.overrideModelPlaceholder', 'Per defecte del tenant')

    return `${providerLabel} · ${modelLabel}`

  }, [provider, model, ts])



  const providerStatus = getProviderStatus(provider)

  const catalogModels = modelOptions.length > 0

    ? modelOptions

    : (providerStatus?.available_models ?? [])



  if (locked) {

    return (

      <div className="flex flex-col items-end gap-1 max-w-[min(100%,20rem)]">

        <div

          className="text-xs text-muted-foreground border rounded-md px-2.5 py-1.5 bg-muted/40 w-full truncate"

          title={t('modelLockedHint', 'El model queda fixat per a aquesta conversa. Obre un nou xat per triar-ne un altre.')}

        >

          {summary}

        </div>

        {capabilities && <CapabilityBadges caps={capabilities} />}

      </div>

    )

  }



  return (

    <Popover open={open} onOpenChange={setOpen} modal={false}>

      <PopoverTrigger asChild>

        <Button

          type="button"

          variant="outline"

          size="sm"

          disabled={disabled || isLoading}

          className="h-auto min-h-8 gap-1.5 max-w-[min(100%,20rem)] py-1"

          title={summary}

        >

          {isLoading ? (

            <Loader2 className="h-3.5 w-3.5 shrink-0 animate-spin" />

          ) : (

            <Settings2 className="h-3.5 w-3.5 shrink-0" />

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

          <p className="text-sm font-medium">{t('modelSelectorTitle', 'Model del xat')}</p>

          <p className="text-xs text-muted-foreground mt-0.5">

            {t('modelSelectorHint', 'S\'aplica a la nova conversa. Els defaults del tenant es configuren a')}

            {' '}

            <Link to="/settings/ai" className="underline" onClick={() => setOpen(false)}>

              {ts('tabs.ai', 'IA')}

            </Link>

            .

          </p>

        </div>



        {capabilities && <CapabilityBadges caps={capabilities} />}



        <label className="space-y-1 block">

          <span className="text-xs text-muted-foreground">{ts('ai.provider', 'Proveïdor')}</span>

          <select

            value={provider}

            disabled={disabled}

            onChange={(e) => onProviderChange?.(e.target.value as AiProvider)}

            className="h-8 w-full rounded-md border bg-background px-2 text-sm"

          >

            {configuredProviders.map((p) => (

              <option key={p} value={p}>

                {AI_PROVIDER_LABELS[p]}

                {p === defaultProvider ? ` (${ts('ai.defaultBadge', 'Per defecte')})` : ''}

              </option>

            ))}

          </select>

        </label>



        <label className="space-y-1 block">

          <span className="text-xs text-muted-foreground">{ts('ai.model', 'Model')}</span>

          {provider === 'openrouter' && (

            <p className="text-[11px] text-muted-foreground leading-snug">

              {ts('ai.openrouterOneKeyHint', 'OpenRouter: una clau, molts models (format proveïdor/model).')}

            </p>

          )}

          <AiModelSelect

            value={model}

            onChange={(next) => onModelChange?.(next)}

            suggestedModels={suggestedModels}

            availableModels={catalogModels}

            disabled={disabled}

            placeholder={ts('ai.overrideModelPlaceholder', 'Per defecte del tenant')}

            selectClassName="h-8 w-full rounded-md border bg-background px-2 text-sm"

            allowFreeText={catalogModels.length === 0}

          />

        </label>



        {modelOptions.length === 0 && providerStatus?.configured && (

          <p className="text-xs text-amber-800 bg-amber-50 border border-amber-200 rounded-lg px-2.5 py-2">

            {t('modelNoAllowed', 'No tens cap model permès per a aquest proveïdor. Contacta amb l\'administrador.')}

          </p>

        )}

      </PopoverContent>

    </Popover>

  )

}


