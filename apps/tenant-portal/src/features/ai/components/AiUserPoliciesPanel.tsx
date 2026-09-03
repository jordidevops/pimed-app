import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Save, Trash2 } from 'lucide-react'
import { useToast } from '@/hooks/use-toast'
import {
  deleteAiUserPolicy,
  fetchAiUserPolicies,
  setAiUserPolicy,
} from '@/features/ai/api/aiRpc'
import type { AiUserPolicy, AiUserPolicyRow } from '@/features/ai/types/rpc'

type EditablePolicy = {
  policy: AiUserPolicy
  customHourly: string
  customDaily: string
  notes: string
}

export function AiUserPoliciesPanel({ tenantId }: { tenantId: string }) {
  const { t } = useTranslation('settings')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const [edits, setEdits] = useState<Record<string, EditablePolicy>>({})

  const { data: rows = [], isLoading } = useQuery<AiUserPolicyRow[]>({
    queryKey: ['ai_user_policies', tenantId],
    enabled: !!tenantId,
    queryFn: () => fetchAiUserPolicies(tenantId),
  })

  function getEdit(row: AiUserPolicyRow): EditablePolicy {
    return edits[row.user_id] ?? {
      policy: row.policy,
      customHourly: row.custom_hourly_limit?.toString() ?? '',
      customDaily: row.custom_daily_limit?.toString() ?? '',
      notes: row.notes ?? '',
    }
  }

  function updateEdit(userId: string, patch: Partial<EditablePolicy>) {
    const row = rows.find((r) => r.user_id === userId)
    if (!row) return
    setEdits((prev) => ({
      ...prev,
      [userId]: { ...getEdit(row), ...patch },
    }))
  }

  const saveMutation = useMutation({
    mutationFn: async (row: AiUserPolicyRow) => {
      const edit = getEdit(row)
      await setAiUserPolicy({
        tenantId,
        userId: row.user_id,
        policy: edit.policy,
        customHourlyLimit: edit.customHourly ? Number(edit.customHourly) : null,
        customDailyLimit: edit.customDaily ? Number(edit.customDaily) : null,
        notes: edit.notes.trim() || null,
        aiEnabled: row.ai_enabled ?? null,
        allowedModels: row.allowed_models ?? {},
        customTokensDailyLimit: row.custom_tokens_daily_limit ?? null,
      })
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['ai_user_policies', tenantId] })
      toast({ description: t('ai.policySaved', 'Política desada') })
    },
    onError: (err) => {
      toast({ variant: 'destructive', description: err instanceof Error ? err.message : String(err) })
    },
  })

  const resetMutation = useMutation({
    mutationFn: async (userId: string) => deleteAiUserPolicy(tenantId, userId),
    onSuccess: async (_, userId) => {
      setEdits((prev) => {
        const next = { ...prev }
        delete next[userId]
        return next
      })
      await queryClient.invalidateQueries({ queryKey: ['ai_user_policies', tenantId] })
      toast({ description: t('ai.policyReset', 'Política restablerta (allow)') })
    },
    onError: (err) => {
      toast({ variant: 'destructive', description: err instanceof Error ? err.message : String(err) })
    },
  })

  if (isLoading) {
    return <p className="text-sm text-muted-foreground">{t('ai.loading', 'Carregant...')}</p>
  }

  return (
    <div className="space-y-4">
      <p className="text-sm text-muted-foreground">
        {t('ai.userPoliciesHint', 'Defineix qui pot usar la IA i amb quins límits personalitzats. Només el propietari pot modificar aquestes polítiques.')}
      </p>

      <div className="overflow-x-auto rounded-xl border">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-muted-foreground border-b bg-muted/30">
              <th className="p-3 font-medium">{t('ai.member', 'Membre')}</th>
              <th className="p-3 font-medium">{t('ai.policy', 'Política')}</th>
              <th className="p-3 font-medium">{t('ai.customHourly', 'Límit/h')}</th>
              <th className="p-3 font-medium">{t('ai.customDaily', 'Límit/dia')}</th>
              <th className="p-3 font-medium">{t('ai.notes', 'Notes')}</th>
              <th className="p-3 font-medium" />
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const edit = getEdit(row)
              const isCustom = row.policy !== 'allow' || row.custom_hourly_limit || row.custom_daily_limit || row.notes
              return (
                <tr key={row.user_id} className="border-b last:border-0">
                  <td className="p-3">
                    <div className="font-medium text-foreground">{row.full_name || row.email}</div>
                    <div className="text-xs text-muted-foreground">{row.email} · {row.role}</div>
                  </td>
                  <td className="p-3">
                    <select
                      value={edit.policy}
                      onChange={(e) => updateEdit(row.user_id, { policy: e.target.value as AiUserPolicy })}
                      className="h-8 rounded-md border bg-background px-2 text-sm"
                    >
                      <option value="allow">{t('ai.policyAllow', 'Permetre')}</option>
                      <option value="warn_only">{t('ai.policyWarn', 'Avís')}</option>
                      <option value="block">{t('ai.policyBlock', 'Bloquejar')}</option>
                    </select>
                  </td>
                  <td className="p-3">
                    <input
                      type="number"
                      min={1}
                      value={edit.customHourly}
                      onChange={(e) => updateEdit(row.user_id, { customHourly: e.target.value })}
                      placeholder="—"
                      className="h-8 w-20 rounded-md border bg-background px-2 text-sm"
                    />
                  </td>
                  <td className="p-3">
                    <input
                      type="number"
                      min={1}
                      value={edit.customDaily}
                      onChange={(e) => updateEdit(row.user_id, { customDaily: e.target.value })}
                      placeholder="—"
                      className="h-8 w-20 rounded-md border bg-background px-2 text-sm"
                    />
                  </td>
                  <td className="p-3">
                    <input
                      value={edit.notes}
                      onChange={(e) => updateEdit(row.user_id, { notes: e.target.value })}
                      className="h-8 w-full min-w-[120px] rounded-md border bg-background px-2 text-sm"
                    />
                  </td>
                  <td className="p-3">
                    <div className="flex items-center gap-1">
                      <button
                        type="button"
                        onClick={() => void saveMutation.mutateAsync(row)}
                        disabled={saveMutation.isPending}
                        className="inline-flex items-center gap-1 text-xs text-indigo-700 hover:text-indigo-800 disabled:opacity-50"
                      >
                        <Save className="h-3.5 w-3.5" />
                        {t('ai.savePolicy', 'Desar')}
                      </button>
                      {isCustom && (
                        <button
                          type="button"
                          onClick={() => void resetMutation.mutateAsync(row.user_id)}
                          disabled={resetMutation.isPending}
                          className="inline-flex items-center gap-1 text-xs text-muted-foreground hover:text-destructive disabled:opacity-50 ml-2"
                        >
                          <Trash2 className="h-3.5 w-3.5" />
                        </button>
                      )}
                    </div>
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
    </div>
  )
}
