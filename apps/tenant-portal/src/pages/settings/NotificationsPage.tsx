import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Bell, MessageSquare, Radio, Save, Send } from 'lucide-react'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { useTenant } from '../../contexts/TenantContext'
import { useToast } from '../../hooks/use-toast'
import {
  fetchMyNotificationPreferences,
  fetchPushConfig,
  fetchTwilioConfig,
  memberChannels,
  saveNotificationPreference,
  savePushConfig,
  saveTwilioConfig,
  sendTestNotification,
  sendTestSms,
  type NotificationChannel,
  type NotificationPreferenceEvent,
} from '../../features/notifications/api/notificationsSettingsService'

const CHANNEL_LABELS: Record<NotificationChannel, string> = {
  in_app: 'In-app',
  push: 'Push',
  email: 'Email',
  sms: 'SMS',
  whatsapp: 'WhatsApp',
}

function PreferencesPanel() {
  const { t } = useTranslation('settings')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  const { data, isLoading } = useQuery({
    queryKey: ['notification-preferences'],
    queryFn: fetchMyNotificationPreferences,
  })

  const [draft, setDraft] = useState<Record<string, NotificationChannel[]>>({})

  const events = useMemo(() => {
    if (!data?.events) return []
    return (data.events as NotificationPreferenceEvent[]).map((ev) => ({
      ...ev,
      channels_enabled: draft[ev.event_code] ?? memberChannels(ev.channels_enabled),
    }))
  }, [data, draft])

  const saveMutation = useMutation({
    mutationFn: async () => {
      for (const ev of events) {
        const original = memberChannels(
          (data?.events as NotificationPreferenceEvent[] | undefined)?.find(
            (e) => e.event_code === ev.event_code,
          )?.channels_enabled ?? [],
        )
        const next = ev.channels_enabled
        if (JSON.stringify(original) !== JSON.stringify(next) || draft[ev.event_code]) {
          await saveNotificationPreference(ev.event_code, next)
        }
      }
    },
    onSuccess: async () => {
      setDraft({})
      await queryClient.invalidateQueries({ queryKey: ['notification-preferences'] })
      toast({ description: t('notifications.prefs_saved', 'Preferències desades') })
    },
    onError: () => {
      toast({
        variant: 'destructive',
        description: t('notifications.prefs_error', 'Error en desar preferències'),
      })
    },
  })

  const testMutation = useMutation({
    mutationFn: () => sendTestNotification(['in_app', 'push', 'email']),
    onSuccess: () => {
      toast({
        description: t(
          'notifications.test_queued',
          'Notificació de prova encuada. Es processarà en uns segons.',
        ),
      })
    },
    onError: () => {
      toast({
        variant: 'destructive',
        description: t('notifications.test_error', 'No s\'ha pogut enviar la prova'),
      })
    },
  })

  function toggleChannel(eventCode: string, channel: NotificationChannel, enabled: boolean) {
    setDraft((prev) => {
      const base = prev[eventCode] ?? memberChannels(
        (data?.events as NotificationPreferenceEvent[] | undefined)?.find(
          (e) => e.event_code === eventCode,
        )?.channels_enabled ?? [],
      )
      const next = enabled
        ? [...new Set([...base, channel])]
        : base.filter((c) => c !== channel)
      return { ...prev, [eventCode]: next }
    })
  }

  if (isLoading) {
    return <div className="rounded-2xl border p-6 animate-pulse h-40" />
  }

  return (
    <div className="space-y-6">
      <p className="text-sm text-muted-foreground">
        {t(
          'notifications.prefs_description',
          'Tria com vols rebre cada tipus d\'esdeveniment (in-app, push i email).',
        )}
      </p>

      <div className="rounded-2xl border divide-y">
        {events.map((ev) => (
          <div key={ev.event_code} className="p-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <p className="font-medium text-sm">{ev.event_code}</p>
              {ev.description && (
                <p className="text-xs text-muted-foreground mt-0.5">{ev.description}</p>
              )}
            </div>
            <div className="flex flex-wrap gap-3">
              {memberChannels(ev.default_channels).map((ch) => (
                <label key={ch} className="inline-flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    className="rounded border-border"
                    checked={ev.channels_enabled.includes(ch)}
                    onChange={(e) => toggleChannel(ev.event_code, ch, e.target.checked)}
                  />
                  {CHANNEL_LABELS[ch]}
                </label>
              ))}
            </div>
          </div>
        ))}
      </div>

      <div className="flex flex-wrap gap-3">
        <button
          type="button"
          onClick={() => saveMutation.mutate()}
          disabled={saveMutation.isPending || Object.keys(draft).length === 0}
          className="inline-flex items-center gap-2 rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground disabled:opacity-50"
        >
          <Save className="h-4 w-4" />
          {t('save', 'Desar')}
        </button>
        <button
          type="button"
          onClick={() => testMutation.mutate()}
          disabled={testMutation.isPending}
          className="inline-flex items-center gap-2 rounded-lg border px-4 py-2 text-sm font-medium hover:bg-muted"
        >
          <Send className="h-4 w-4" />
          {t('notifications.send_test', 'Enviar notificació de prova')}
        </button>
      </div>
    </div>
  )
}

function IntegrationsPanel({ tenantId }: { tenantId: string }) {
  const { t } = useTranslation('settings')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  const { data: twilio } = useQuery({
    queryKey: ['twilio-config', tenantId],
    queryFn: fetchTwilioConfig,
  })

  const { data: push } = useQuery({
    queryKey: ['push-config', tenantId],
    queryFn: fetchPushConfig,
  })

  const [twilioForm, setTwilioForm] = useState({
    accountSid: '',
    authToken: '',
    smsFrom: '',
    whatsappFrom: '',
  })
  const [testSmsPhone, setTestSmsPhone] = useState('')

  const [pushForm, setPushForm] = useState({
    appId: '',
    restApiKey: '',
  })

  const twilioMutation = useMutation({
    mutationFn: () =>
      saveTwilioConfig(tenantId, {
        accountSid: twilioForm.accountSid,
        authToken: twilioForm.authToken,
        smsFromNumber: twilioForm.smsFrom || undefined,
        whatsappFromNumber: twilioForm.whatsappFrom || undefined,
      }),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['twilio-config', tenantId] })
      setTwilioForm((f) => ({ ...f, authToken: '' }))
      toast({ description: t('notifications.twilio_saved', 'Twilio configurat') })
    },
    onError: () => {
      toast({ variant: 'destructive', description: t('notifications.twilio_error', 'Error Twilio') })
    },
  })

  const testSmsMutation = useMutation({
    mutationFn: () => sendTestSms(testSmsPhone),
    onSuccess: () => {
      toast({
        description: t(
          'notifications.test_sms_queued',
          'SMS de prova encuat. Comprova el telèfon en uns moments.',
        ),
      })
    },
    onError: (err: Error) => {
      const code = err.message
      const msg = code === 'twilio_not_configured'
        ? t('notifications.twilio_not_configured', 'Twilio no configurat o desactivat')
        : code === 'phone_required'
          ? t('notifications.phone_required', 'Cal introduir un número de telèfon')
          : t('notifications.test_sms_error', 'Error enviant SMS de prova')
      toast({ variant: 'destructive', description: msg })
    },
  })

  const pushMutation = useMutation({
    mutationFn: () =>
      savePushConfig({
        appId: pushForm.appId,
        restApiKey: pushForm.restApiKey,
      }),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['push-config', tenantId] })
      setPushForm((f) => ({ ...f, restApiKey: '' }))
      toast({ description: t('notifications.push_saved', 'OneSignal configurat') })
    },
    onError: () => {
      toast({ variant: 'destructive', description: t('notifications.push_error', 'Error OneSignal') })
    },
  })

  return (
    <div className="space-y-8">
      <section className="rounded-2xl border p-5 space-y-4">
        <div className="flex items-center gap-2">
          <MessageSquare className="h-5 w-5 text-muted-foreground" />
          <h3 className="font-semibold">{t('notifications.twilio_title', 'Twilio (SMS / WhatsApp BYO)')}</h3>
        </div>
        {twilio?.configured && (
          <p className="text-xs text-muted-foreground">
            SID: {twilio.account_sid} · SMS: {twilio.sms_from_number ?? '—'}
            {twilio.last_error_code && ` · Error: ${twilio.last_error_code}`}
          </p>
        )}
        <div className="grid gap-3 sm:grid-cols-2">
          <input
            className="rounded-lg border px-3 py-2 text-sm"
            placeholder="Account SID"
            value={twilioForm.accountSid}
            onChange={(e) => setTwilioForm((f) => ({ ...f, accountSid: e.target.value }))}
          />
          <input
            className="rounded-lg border px-3 py-2 text-sm"
            placeholder="Auth Token"
            type="password"
            value={twilioForm.authToken}
            onChange={(e) => setTwilioForm((f) => ({ ...f, authToken: e.target.value }))}
          />
          <input
            className="rounded-lg border px-3 py-2 text-sm"
            placeholder="+34..."
            value={twilioForm.smsFrom}
            onChange={(e) => setTwilioForm((f) => ({ ...f, smsFrom: e.target.value }))}
          />
          <input
            className="rounded-lg border px-3 py-2 text-sm"
            placeholder="whatsapp:+34..."
            value={twilioForm.whatsappFrom}
            onChange={(e) => setTwilioForm((f) => ({ ...f, whatsappFrom: e.target.value }))}
          />
        </div>
        <button
          type="button"
          onClick={() => twilioMutation.mutate()}
          disabled={twilioMutation.isPending || !twilioForm.accountSid || !twilioForm.authToken}
          className="rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground disabled:opacity-50"
        >
          {t('notifications.save_twilio', 'Desar Twilio')}
        </button>

        {twilio?.configured && (
          <div className="pt-4 border-t space-y-3">
            <p className="text-xs font-medium text-muted-foreground">
              {t('notifications.test_sms_title', 'Provar SMS')}
            </p>
            <div className="flex gap-2">
              <input
                className="flex-1 rounded-lg border px-3 py-2 text-sm"
                placeholder="+34600000000"
                value={testSmsPhone}
                onChange={(e) => setTestSmsPhone(e.target.value)}
              />
              <button
                type="button"
                onClick={() => testSmsMutation.mutate()}
                disabled={testSmsMutation.isPending || !testSmsPhone.trim()}
                className="inline-flex items-center gap-2 rounded-lg border px-3 py-2 text-sm font-medium hover:bg-muted disabled:opacity-50"
              >
                <Send className="h-4 w-4" />
                {t('notifications.send_test_sms', 'Enviar')}
              </button>
            </div>
          </div>
        )}
      </section>

      <section className="rounded-2xl border p-5 space-y-4">
        <div className="flex items-center gap-2">
          <Radio className="h-5 w-5 text-muted-foreground" />
          <h3 className="font-semibold">{t('notifications.push_title', 'OneSignal (push BYO)')}</h3>
        </div>
        <p className="text-xs text-muted-foreground">
          {push?.configured
            ? `App ID: ${push.onesignal_app_id}`
            : t('notifications.push_fallback', 'Sense BYO, s\'usa la configuració de plataforma (si existeix).')}
        </p>
        <div className="grid gap-3 sm:grid-cols-2">
          <input
            className="rounded-lg border px-3 py-2 text-sm"
            placeholder="OneSignal App ID"
            value={pushForm.appId}
            onChange={(e) => setPushForm((f) => ({ ...f, appId: e.target.value }))}
          />
          <input
            className="rounded-lg border px-3 py-2 text-sm"
            placeholder="REST API Key"
            type="password"
            value={pushForm.restApiKey}
            onChange={(e) => setPushForm((f) => ({ ...f, restApiKey: e.target.value }))}
          />
        </div>
        <button
          type="button"
          onClick={() => pushMutation.mutate()}
          disabled={pushMutation.isPending || !pushForm.appId || !pushForm.restApiKey}
          className="rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground disabled:opacity-50"
        >
          {t('notifications.save_push', 'Desar OneSignal')}
        </button>
      </section>
    </div>
  )
}

export function NotificationsPage() {
  const { t } = useTranslation('settings')
  const { activeTenant, activeRole } = useTenant()
  const canManageIntegrations = activeRole === 'owner' || activeRole === 'manager'

  if (!activeTenant) return null

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-lg font-semibold flex items-center gap-2">
          <Bell className="h-5 w-5" />
          {t('notifications.page_title', 'Notificacions')}
        </h2>
        <p className="text-sm text-muted-foreground mt-0.5">
          {t('notifications.page_description', 'Preferències personals i integracions de canals.')}
        </p>
      </div>

      <Tabs defaultValue="preferences">
        <TabsList>
          <TabsTrigger value="preferences">
            {t('notifications.tab_preferences', 'Preferències')}
          </TabsTrigger>
          {canManageIntegrations && (
            <TabsTrigger value="integrations">
              {t('notifications.tab_integrations', 'Integracions')}
            </TabsTrigger>
          )}
        </TabsList>
        <TabsContent value="preferences" className="mt-6">
          <PreferencesPanel />
        </TabsContent>
        {canManageIntegrations && (
          <TabsContent value="integrations" className="mt-6">
            <IntegrationsPanel tenantId={activeTenant.id} />
          </TabsContent>
        )}
      </Tabs>
    </div>
  )
}
