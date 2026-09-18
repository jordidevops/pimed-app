'use client'

import { useState, useTransition } from 'react'
import { toast } from 'sonner'
import { Loader2, Save } from 'lucide-react'
import { useTranslation } from 'react-i18next'

import { Button } from '@/components/ui/button'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'

import type { PlatformAiFeaturePrompt } from '@/app/admin/actions/ai-settings'
import { upsertPlatformAiFeaturePrompt } from '@/app/admin/actions/ai-settings'

export function AdminAiFeaturePrompts({ prompts }: { prompts: PlatformAiFeaturePrompt[] }) {
  const { t } = useTranslation('settings')
  const [forms, setForms] = useState<Record<string, string>>(() => {
    const initial: Record<string, string> = {}
    for (const row of prompts) initial[row.feature] = row.instructions
    return initial
  })
  const [savingFeature, setSavingFeature] = useState<string | null>(null)
  const [pending, startTransition] = useTransition()

  function save(row: PlatformAiFeaturePrompt) {
    const instructions = (forms[row.feature] ?? '').trim()
    if (!instructions) {
      toast.error(t('settings.ai.featurePromptInstructions', 'Instruccions'))
      return
    }
    setSavingFeature(row.feature)
    startTransition(async () => {
      try {
        await upsertPlatformAiFeaturePrompt({
          feature: row.feature,
          title: row.title,
          instructions,
        })
        toast.success(t('settings.ai.featurePromptSaved', 'Instruccions desades'))
      } catch (err) {
        toast.error(err instanceof Error ? err.message : String(err))
      } finally {
        setSavingFeature(null)
      }
    })
  }

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-lg font-semibold text-gray-900">
          {t('settings.ai.featurePromptsTitle', 'Instruccions de tasca (compositor)')}
        </h2>
        <p className="text-sm text-muted-foreground mt-1">
          {t(
            'settings.ai.featurePromptsHint',
            "Aquest text s'injecta a generate-ai-content per a cada tasca. Si hi ha fila, s'ignoren les instruccions system que enviï el client. El prompt genèric del proveïdor continua aplicant-se a totes les generacions.",
          )}
        </p>
      </div>

      {prompts.map((row) => (
        <Card key={row.feature}>
          <CardHeader>
            <CardTitle className="text-base">{row.title}</CardTitle>
            <CardDescription className="font-mono text-xs">{row.feature}</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="space-y-2">
              <Label>{t('settings.ai.featurePromptInstructions', 'Instruccions')}</Label>
              <Textarea
                rows={6}
                className="resize-y font-mono text-sm"
                value={forms[row.feature] ?? ''}
                onChange={(e) =>
                  setForms((prev) => ({ ...prev, [row.feature]: e.target.value }))
                }
              />
            </div>
            <div className="flex justify-end">
              <Button
                type="button"
                onClick={() => save(row)}
                disabled={pending && savingFeature === row.feature}
              >
                {pending && savingFeature === row.feature ? (
                  <Loader2 className="h-4 w-4 animate-spin mr-2" />
                ) : (
                  <Save className="h-4 w-4 mr-2" />
                )}
                {t('settings.ai.save', 'Desar')}
              </Button>
            </div>
          </CardContent>
        </Card>
      ))}
    </div>
  )
}
