import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Loader2, Play } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { Button } from '@/components/ui/button'
import { Textarea } from '@/components/ui/textarea'
import { Label } from '@/components/ui/label'
import { getFunctionErrorMessage, getResponseErrorMessage } from '@/lib/functionErrors'
import type { AiProvider } from '@/features/ai/types/rpc'

type Props = {
  tenantId: string
  provider: AiProvider
  model: string
  systemPrompt: string
  temperature: number
  maxTokens: number
  embedded?: boolean
}

export function AiConnectionTest({
  tenantId,
  provider,
  model,
  systemPrompt,
  temperature,
  maxTokens,
  embedded = false,
}: Props) {
  const { t } = useTranslation('settings')
  const [userPrompt, setUserPrompt] = useState('Hola')
  const [loading, setLoading] = useState(false)
  const [result, setResult] = useState<Record<string, unknown> | null>(null)
  const [error, setError] = useState<string | null>(null)

  async function runTest() {
    setLoading(true)
    setError(null)
    setResult(null)
    try {
      const { data, error: fnError } = await supabase.functions.invoke('test-ai-connection', {
        headers: { 'x-tenant-id': tenantId },
        body: {
          provider,
          model,
          systemPrompt: systemPrompt || null,
          temperature,
          maxTokens,
          userPrompt,
          includeRaw: true,
        },
      })
      if (fnError) {
        const detailed = await getFunctionErrorMessage(fnError)
        throw new Error(detailed ?? fnError.message)
      }
      const responseError = getResponseErrorMessage(data)
      if (responseError) throw new Error(responseError)
      setResult(data as Record<string, unknown>)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className={embedded ? 'space-y-3' : 'space-y-3 rounded-lg border p-4 mt-6'}>
      {!embedded && (
        <>
          <h3 className="font-medium">{t('ai.connectionTestTitle', 'Prova de connexió')}</h3>
          <p className="text-sm text-muted-foreground">
            {t('ai.connectionTestHint', 'Envia una petició de prova amb els valors del formulari (no cal desar abans).')}
          </p>
        </>
      )}
      <div className="space-y-2">
        <Label htmlFor="ai-test-prompt">{t('ai.connectionTestPrompt', 'Prompt de prova')}</Label>
        <Textarea
          id="ai-test-prompt"
          value={userPrompt}
          onChange={(e) => setUserPrompt(e.target.value)}
          rows={2}
        />
      </div>
      <Button type="button" variant="secondary" onClick={() => void runTest()} disabled={loading || !model.trim()}>
        {loading ? <Loader2 className="h-4 w-4 animate-spin mr-2" /> : <Play className="h-4 w-4 mr-2" />}
        {t('ai.connectionTestRun', 'Provar connexió')}
      </Button>
      {error && <p className="text-sm text-destructive">{error}</p>}
      {result && (
        <div className="space-y-2 text-sm">
          <div className="rounded-md bg-muted p-3">
            <p className="font-medium mb-1">{t('ai.connectionTestResponse', 'Resposta')}</p>
            <p className="whitespace-pre-wrap">{String(result.content ?? '')}</p>
          </div>
          <details className="rounded-md border p-3">
            <summary className="cursor-pointer font-medium">
              {t('ai.connectionTestRequest', 'Petició i detalls')}
            </summary>
            <pre className="mt-2 text-xs overflow-auto max-h-64">
              {JSON.stringify(result, null, 2)}
            </pre>
          </details>
        </div>
      )}
    </div>
  )
}
