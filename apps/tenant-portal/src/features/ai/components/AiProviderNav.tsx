import { CheckCircle2, Circle } from 'lucide-react'
import { cn } from '@/lib/utils'
import type { AiProvider } from '@/features/ai/types/rpc'

type Props = {
  providers: AiProvider[]
  labels: Record<AiProvider, string>
  active: AiProvider
  configured: Record<AiProvider, boolean>
  defaultProvider: AiProvider
  onSelect: (provider: AiProvider) => void
}

export function AiProviderNav({
  providers,
  labels,
  active,
  configured,
  defaultProvider,
  onSelect,
}: Props) {
  return (
    <nav className="flex flex-col gap-1 min-w-[11rem] shrink-0" aria-label="Proveïdors IA">
      {providers.map((provider) => {
        const isActive = active === provider
        const isConfigured = configured[provider]
        const isDefault = defaultProvider === provider

        return (
          <button
            key={provider}
            type="button"
            onClick={() => onSelect(provider)}
            className={cn(
              'flex items-center gap-2 rounded-lg px-3 py-2 text-sm text-left transition',
              isActive
                ? 'bg-indigo-50 text-indigo-900 font-medium border border-indigo-200'
                : 'hover:bg-muted text-foreground border border-transparent',
            )}
          >
            {isConfigured ? (
              <CheckCircle2 className="h-4 w-4 text-emerald-600 shrink-0" />
            ) : (
              <Circle className="h-4 w-4 text-muted-foreground shrink-0" />
            )}
            <span className="flex-1 truncate">{labels[provider]}</span>
            {isDefault && (
              <span className="text-[10px] font-medium text-indigo-700 bg-indigo-100 px-1.5 py-0.5 rounded">
                def.
              </span>
            )}
          </button>
        )
      })}
    </nav>
  )
}
