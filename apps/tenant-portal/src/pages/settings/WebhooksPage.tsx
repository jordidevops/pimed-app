import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Link2, Plus, Send, Trash2 } from 'lucide-react'
import { useTenant } from '../../contexts/TenantContext'
import { useToast } from '../../hooks/use-toast'
import { useTenantFeatures } from '../../features/entity-timeline/api/useTenantFeatures'
import { TimelineFeatureDisabledNotice } from '../../features/entity-timeline/components/TimelineFeatureDisabledNotice'
import {
  TIMELINE_ENTITY_TYPES,
  TIMELINE_WEBHOOK_EVENTS,
  deleteTenantWebhook,
  fetchTenantWebhooks,
  fetchWebhookDeliveryLog,
  testTenantWebhook,
  upsertTenantWebhook,
  type TenantWebhook,
  type TimelineEntityType,
  type TimelineWebhookEvent,
} from '../../features/webhooks/api/webhooksService'

const EMPTY_FORM = {
  label: '',
  endpoint_url: '',
  events: ['timeline.comment.created'] as TimelineWebhookEvent[],
  entity_types: [] as TimelineEntityType[],
  is_active: true,
}

export function WebhooksPage() {
  const { t } = useTranslation('settings')
  const { toast } = useToast()
  const { activeRole, activeTenant } = useTenant()
  const { data: features, isLoading: featuresLoading } = useTenantFeatures()
  const queryClient = useQueryClient()
  const canManage = activeRole === 'owner' || activeRole === 'manager'

  const [editing, setEditing] = useState<TenantWebhook | null>(null)
  const [form, setForm] = useState(EMPTY_FORM)
  const [revealedSecret, setRevealedSecret] = useState<string | null>(null)
  const [selectedWebhookId, setSelectedWebhookId] = useState<string | null>(null)

  const { data: webhooks = [], isLoading } = useQuery({
    queryKey: ['tenant-webhooks'],
    queryFn: fetchTenantWebhooks,
    enabled: canManage,
  })

  const { data: deliveryLog = [] } = useQuery({
    queryKey: ['webhook-delivery-log', selectedWebhookId],
    queryFn: () => fetchWebhookDeliveryLog(selectedWebhookId ?? undefined),
    enabled: canManage,
  })

  const saveMutation = useMutation({
    mutationFn: () => upsertTenantWebhook({
      id: editing?.id,
      label: form.label,
      endpoint_url: form.endpoint_url,
      events: form.events,
      entity_types: form.entity_types.length ? form.entity_types : null,
      is_active: form.is_active,
    }),
    onSuccess: (result) => {
      if (result.secret) setRevealedSecret(result.secret)
      setEditing(null)
      setForm(EMPTY_FORM)
      void queryClient.invalidateQueries({ queryKey: ['tenant-webhooks'] })
      toast({ description: t('webhooks.saved', 'Webhook desat') })
    },
    onError: () => {
      toast({
        variant: 'destructive',
        description: t('webhooks.save_error', 'No s\'ha pogut desar el webhook'),
      })
    },
  })

  const deleteMutation = useMutation({
    mutationFn: deleteTenantWebhook,
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['tenant-webhooks'] })
      toast({ description: t('webhooks.deleted', 'Webhook eliminat') })
    },
  })

  const testMutation = useMutation({
    mutationFn: testTenantWebhook,
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['webhook-delivery-log'] })
      toast({
        description: t(
          'webhooks.test_queued',
          'Prova encuada. Executa process-webhook-queue o espera el cron.',
        ),
      })
    },
    onError: () => {
      toast({
        variant: 'destructive',
        description: t('webhooks.test_error', 'No s\'ha pogut enviar la prova'),
      })
    },
  })

  const eventLabels = useMemo(() => {
    const map: Record<string, string> = {}
    for (const ev of TIMELINE_WEBHOOK_EVENTS) {
      map[ev.code] = t(ev.labelKey, ev.code)
    }
    return map
  }, [t])

  function startCreate() {
    setEditing(null)
    setForm(EMPTY_FORM)
    setRevealedSecret(null)
  }

  function startEdit(webhook: TenantWebhook) {
    setEditing(webhook)
    setForm({
      label: webhook.label,
      endpoint_url: webhook.endpoint_url,
      events: webhook.events,
      entity_types: webhook.entity_types ?? [],
      is_active: webhook.is_active,
    })
    setRevealedSecret(null)
    setSelectedWebhookId(webhook.id)
  }

  function toggleEvent(code: TimelineWebhookEvent, checked: boolean) {
    setForm((prev) => {
      const next = checked
        ? [...new Set([...prev.events, code])]
        : prev.events.filter((e) => e !== code)
      return { ...prev, events: next.length ? next : ['timeline.comment.created'] }
    })
  }

  function toggleEntityType(type: TimelineEntityType, checked: boolean) {
    setForm((prev) => ({
      ...prev,
      entity_types: checked
        ? [...new Set([...prev.entity_types, type])]
        : prev.entity_types.filter((e) => e !== type),
    }))
  }

  if (!featuresLoading && features?.entity_timeline_webhooks === false) {
    return (
      <TimelineFeatureDisabledNotice
        titleKey="webhooks.feature_disabled_title"
        titleDefault="Webhooks de timeline no disponibles"
        descriptionKey="webhooks.feature_disabled_description"
        descriptionDefault="Aquesta funcionalitat no està inclosa al pla de la teva organització. Contacta amb suport per ampliar el pla."
      />
    )
  }

  if (!canManage) {
    return (
      <p className="text-sm text-muted-foreground">
        {t('webhooks.read_only', 'Només gestors i propietaris poden configurar webhooks.')}
      </p>
    )
  }

  return (
    <div className="space-y-8">
      <div>
        <h2 className="text-lg font-semibold flex items-center gap-2">
          <Link2 className="h-5 w-5" />
          {t('webhooks.title', 'Webhooks de timeline')}
        </h2>
        <p className="text-sm text-muted-foreground mt-1">
          {t(
            'webhooks.description',
            'Rep esdeveniments de comentaris, mencions i tasques resoltes a un endpoint HTTPS extern (Slack, n8n, etc.).',
          )}
        </p>
      </div>

      {revealedSecret && (
        <div className="rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm">
          <p className="font-medium">{t('webhooks.secret_once', 'Secret (només es mostra una vegada)')}</p>
          <code className="mt-2 block break-all text-xs">{revealedSecret}</code>
        </div>
      )}

      <div className="rounded-2xl border p-6 space-y-4">
        <div className="flex items-center justify-between">
          <h3 className="font-medium">
            {editing
              ? t('webhooks.edit_title', 'Editar webhook')
              : t('webhooks.new_title', 'Nou webhook')}
          </h3>
          {!editing && (
            <button
              type="button"
              onClick={startCreate}
              className="inline-flex items-center gap-1 text-sm text-primary"
            >
              <Plus className="h-4 w-4" />
              {t('webhooks.new', 'Nou')}
            </button>
          )}
        </div>

        <div className="grid gap-4 sm:grid-cols-2">
          <label className="space-y-1 text-sm">
            <span>{t('webhooks.label', 'Nom')}</span>
            <input
              className="w-full rounded-md border px-3 py-2"
              value={form.label}
              onChange={(e) => setForm((f) => ({ ...f, label: e.target.value }))}
            />
          </label>
          <label className="space-y-1 text-sm sm:col-span-2">
            <span>{t('webhooks.endpoint', 'URL HTTPS')}</span>
            <input
              className="w-full rounded-md border px-3 py-2 font-mono text-xs"
              placeholder="https://hooks.example.com/..."
              value={form.endpoint_url}
              onChange={(e) => setForm((f) => ({ ...f, endpoint_url: e.target.value }))}
            />
          </label>
        </div>

        <fieldset className="space-y-2">
          <legend className="text-sm font-medium">{t('webhooks.events_label', 'Esdeveniments')}</legend>
          <div className="flex flex-wrap gap-3">
            {TIMELINE_WEBHOOK_EVENTS.map((ev) => (
              <label key={ev.code} className="inline-flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={form.events.includes(ev.code)}
                  onChange={(e) => toggleEvent(ev.code, e.target.checked)}
                />
                {eventLabels[ev.code]}
              </label>
            ))}
          </div>
        </fieldset>

        <fieldset className="space-y-2">
          <legend className="text-sm font-medium">
            {t('webhooks.entity_types', 'Tipus d\'entitat (opcional)')}
          </legend>
          <p className="text-xs text-muted-foreground">
            {t('webhooks.entity_types_hint', 'Buit = tots els tipus')}
          </p>
          <div className="flex flex-wrap gap-3">
            {TIMELINE_ENTITY_TYPES.map((type) => (
              <label key={type} className="inline-flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={form.entity_types.includes(type)}
                  onChange={(e) => toggleEntityType(type, e.target.checked)}
                />
                {type}
              </label>
            ))}
          </div>
        </fieldset>

        <label className="inline-flex items-center gap-2 text-sm">
          <input
            type="checkbox"
            checked={form.is_active}
            onChange={(e) => setForm((f) => ({ ...f, is_active: e.target.checked }))}
          />
          {t('webhooks.active', 'Actiu')}
        </label>

        <div className="flex gap-2">
          <button
            type="button"
            disabled={saveMutation.isPending || !form.label || !form.endpoint_url}
            onClick={() => saveMutation.mutate()}
            className="rounded-md bg-primary px-4 py-2 text-sm text-primary-foreground disabled:opacity-50"
          >
            {t('save', 'Desar')}
          </button>
          {editing && (
            <button
              type="button"
              className="rounded-md border px-4 py-2 text-sm"
              onClick={startCreate}
            >
              {t('webhooks.cancel', 'Cancel·lar')}
            </button>
          )}
        </div>
      </div>

      <div className="rounded-2xl border overflow-hidden">
        <table className="w-full text-sm">
          <thead className="bg-muted/50 text-left">
            <tr>
              <th className="p-3">{t('webhooks.label', 'Nom')}</th>
              <th className="p-3">{t('webhooks.endpoint', 'URL')}</th>
              <th className="p-3">{t('webhooks.events_label', 'Esdeveniments')}</th>
              <th className="p-3" />
            </tr>
          </thead>
          <tbody>
            {isLoading && (
              <tr>
                <td colSpan={4} className="p-4 text-muted-foreground">
                  {t('saving', 'Carregant...')}
                </td>
              </tr>
            )}
            {!isLoading && webhooks.length === 0 && (
              <tr>
                <td colSpan={4} className="p-4 text-muted-foreground">
                  {t('webhooks.empty', 'Cap webhook configurat')}
                </td>
              </tr>
            )}
            {webhooks.map((wh) => (
              <tr key={wh.id} className="border-t">
                <td className="p-3">
                  <div className="font-medium">{wh.label}</div>
                  <div className="text-xs text-muted-foreground">{wh.secret_hint}</div>
                </td>
                <td className="p-3 font-mono text-xs break-all">{wh.endpoint_url}</td>
                <td className="p-3 text-xs">
                  {wh.events.map((e) => eventLabels[e] ?? e).join(', ')}
                </td>
                <td className="p-3">
                  <div className="flex justify-end gap-2">
                    <button
                      type="button"
                      title={t('webhooks.test', 'Provar')}
                      onClick={() => testMutation.mutate(wh.id)}
                      className="p-1.5 rounded hover:bg-muted"
                    >
                      <Send className="h-4 w-4" />
                    </button>
                    <button
                      type="button"
                      onClick={() => startEdit(wh)}
                      className="text-xs underline"
                    >
                      {t('webhooks.edit', 'Editar')}
                    </button>
                    <button
                      type="button"
                      onClick={() => deleteMutation.mutate(wh.id)}
                      className="p-1.5 rounded hover:bg-muted text-destructive"
                    >
                      <Trash2 className="h-4 w-4" />
                    </button>
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="space-y-3">
        <h3 className="font-medium">{t('webhooks.delivery_log', 'Registre d\'enviaments')}</h3>
        <div className="rounded-2xl border overflow-hidden">
          <table className="w-full text-sm">
            <thead className="bg-muted/50 text-left">
              <tr>
                <th className="p-3">{t('webhooks.log_event', 'Esdeveniment')}</th>
                <th className="p-3">{t('webhooks.log_status', 'Estat')}</th>
                <th className="p-3">{t('webhooks.log_http', 'HTTP')}</th>
                <th className="p-3">{t('webhooks.log_when', 'Data')}</th>
              </tr>
            </thead>
            <tbody>
              {deliveryLog.length === 0 && (
                <tr>
                  <td colSpan={4} className="p-4 text-muted-foreground">
                    {t('webhooks.log_empty', 'Sense enviaments encara')}
                  </td>
                </tr>
              )}
              {deliveryLog.map((row) => (
                <tr key={row.id} className="border-t">
                  <td className="p-3 font-mono text-xs">{row.event_type}</td>
                  <td className="p-3">{row.status}</td>
                  <td className="p-3">{row.response_status ?? row.error_message ?? '—'}</td>
                  <td className="p-3 text-xs text-muted-foreground">
                    {new Date(row.created_at).toLocaleString()}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  )
}
