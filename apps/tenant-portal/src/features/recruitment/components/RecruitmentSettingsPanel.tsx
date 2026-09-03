import { useEffect, useState, type ReactNode } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Checkbox } from '@/components/ui/checkbox'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import { useTenant } from '@/contexts/TenantContext'
import { useToast } from '@/hooks/use-toast'
import { usePermission } from '@/hooks/usePermission'
import { supabase } from '@/lib/supabase'
import { fetchAiUserAccess } from '@/features/ai/api/aiRpc'
import {
  acceptRecruitmentAiChecklist,
  setRecruitmentAiAssistEnabled,
} from '../api/recruitmentService'
import { recruitmentKeys } from '../api/useRecruitment'
import { SlaNotifyEmailsField } from './SlaNotifyEmailsField'
import { PipelineStagesPanel } from './PipelineStagesPanel'

type LegalBasis = 'legitimate_interest' | 'consent' | 'other'
type SettingsSection = 'general' | 'capture' | 'pipeline' | 'ai'

type SettingsRow = {
  default_max_retention_months: number
  privacy_policy_url: string | null
  rights_sla_days: number
  rejection_notify_policy: 'on_decision' | 'on_posting_close'
  candidate_portal_base_url: string | null
  rights_sla_notify_emails: string[] | null
  import_legal_basis: LegalBasis
  import_legal_basis_note: string | null
  analytics_min_cohort: number
  inbound_enabled: boolean
  inbound_address_hint: string | null
  ai_assist_enabled: boolean
  ai_dpa_accepted_at: string | null
  ai_transfer_accepted_at: string | null
  ai_checklist_version: string | null
}

const PUBLIC_PORTAL_BASE =
  (import.meta.env.VITE_PUBLIC_PORTAL_BASE_URL as string | undefined)?.replace(/\/$/, '') ||
  'http://localhost:3002'

const SECTIONS: SettingsSection[] = ['general', 'capture', 'pipeline', 'ai']

function Panel({
  title,
  description,
  children,
}: {
  title: string
  description?: string
  children: ReactNode
}) {
  return (
    <div className="space-y-4 rounded-xl border bg-card p-4 sm:p-5">
      <div>
        <h3 className="font-semibold">{title}</h3>
        {description && <p className="mt-1 text-sm text-muted-foreground">{description}</p>}
      </div>
      {children}
    </div>
  )
}

export function RecruitmentSettingsPanel() {
  const { t } = useTranslation('recruitment')
  const { activeTenant } = useTenant()
  const canManage = usePermission('recruitment.manage')
  const { toast } = useToast()
  const qc = useQueryClient()
  const [searchParams, setSearchParams] = useSearchParams()
  const sectionParam = searchParams.get('section') as SettingsSection | null
  const [section, setSection] = useState<SettingsSection>(
    sectionParam && SECTIONS.includes(sectionParam) ? sectionParam : 'general',
  )

  const [months, setMonths] = useState(12)
  const [slaDays, setSlaDays] = useState(30)
  const [notifyPolicy, setNotifyPolicy] = useState<'on_decision' | 'on_posting_close'>(
    'on_decision',
  )
  const [portalBaseUrl, setPortalBaseUrl] = useState('')
  const [slaEmails, setSlaEmails] = useState<string[]>([])
  const [legalBasis, setLegalBasis] = useState<LegalBasis>('legitimate_interest')
  const [legalBasisNote, setLegalBasisNote] = useState('')
  const [minCohort, setMinCohort] = useState(5)
  const [inboundEnabled, setInboundEnabled] = useState(false)
  const [inboundHint, setInboundHint] = useState('')
  const [acceptDpa, setAcceptDpa] = useState(false)
  const [acceptTransfer, setAcceptTransfer] = useState(false)
  const [aiEnabled, setAiEnabled] = useState(false)
  const [checklistAccepted, setChecklistAccepted] = useState(false)

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const db = supabase as any

  const { data } = useQuery({
    queryKey: [...recruitmentKeys.all, 'settings', activeTenant?.id],
    enabled: Boolean(activeTenant?.id),
    queryFn: async () => {
      const { data: row, error } = await db
        .from('recruitment_settings')
        .select(
          'default_max_retention_months, privacy_policy_url, rights_sla_days, rejection_notify_policy, candidate_portal_base_url, rights_sla_notify_emails, import_legal_basis, import_legal_basis_note, analytics_min_cohort, inbound_enabled, inbound_address_hint, ai_assist_enabled, ai_dpa_accepted_at, ai_transfer_accepted_at, ai_checklist_version',
        )
        .eq('tenant_id', activeTenant!.id)
        .maybeSingle()
      if (error) throw error
      return row as SettingsRow | null
    },
  })

  const { data: aiAccess } = useQuery({
    queryKey: [...recruitmentKeys.all, 'ai-access', activeTenant?.id],
    enabled: Boolean(activeTenant?.id),
    queryFn: () => fetchAiUserAccess(activeTenant!.id),
  })

  useEffect(() => {
    if (!data) return
    setMonths(data.default_max_retention_months)
    setSlaDays(data.rights_sla_days ?? 30)
    setNotifyPolicy(data.rejection_notify_policy ?? 'on_decision')
    setPortalBaseUrl(data.candidate_portal_base_url ?? '')
    setSlaEmails(data.rights_sla_notify_emails ?? [])
    setLegalBasis(data.import_legal_basis ?? 'legitimate_interest')
    setLegalBasisNote(data.import_legal_basis_note ?? '')
    setMinCohort(data.analytics_min_cohort ?? 5)
    setInboundEnabled(Boolean(data.inbound_enabled))
    setInboundHint(data.inbound_address_hint ?? '')
    setAiEnabled(Boolean(data.ai_assist_enabled))
    const accepted = Boolean(data.ai_dpa_accepted_at && data.ai_transfer_accepted_at)
    setChecklistAccepted(accepted)
    setAcceptDpa(accepted)
    setAcceptTransfer(accepted)
  }, [data])

  useEffect(() => {
    if (sectionParam && SECTIONS.includes(sectionParam) && sectionParam !== section) {
      setSection(sectionParam)
    }
  }, [sectionParam, section])

  function changeSection(next: string) {
    const value = next as SettingsSection
    setSection(value)
    setSearchParams(value === 'general' ? {} : { section: value }, { replace: true })
  }

  const saveMutation = useMutation({
    mutationFn: async () => {
      if (legalBasis === 'other' && !legalBasisNote.trim()) {
        throw new Error(t('settings.legal_basis_note_required'))
      }
      const { error } = await db
        .from('recruitment_settings')
        .update({
          default_max_retention_months: Math.min(12, Math.max(1, months)),
          rights_sla_days: Math.min(90, Math.max(1, slaDays)),
          rejection_notify_policy: notifyPolicy,
          candidate_portal_base_url: portalBaseUrl.trim().replace(/\/$/, '') || null,
          rights_sla_notify_emails: slaEmails,
          import_legal_basis: legalBasis,
          import_legal_basis_note:
            legalBasis === 'other' ? legalBasisNote.trim() : legalBasisNote.trim() || null,
          analytics_min_cohort: Math.min(20, Math.max(3, minCohort)),
          inbound_enabled: inboundEnabled,
          inbound_address_hint: inboundHint.trim() || null,
          updated_at: new Date().toISOString(),
        })
        .eq('tenant_id', activeTenant!.id)
      if (error) throw error
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: recruitmentKeys.all })
      toast({ description: t('form.save') })
    },
    onError: (err: Error) => toast({ variant: 'destructive', description: err.message }),
  })

  const checklistMutation = useMutation({
    mutationFn: async () => {
      if (!acceptDpa || !acceptTransfer) {
        throw new Error(t('settings.ai_checklist_required'))
      }
      return acceptRecruitmentAiChecklist(activeTenant!.id, true, true)
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: recruitmentKeys.all })
      setChecklistAccepted(true)
      toast({ description: t('settings.ai_checklist_saved') })
    },
    onError: (err: Error) => toast({ variant: 'destructive', description: err.message }),
  })

  const aiToggleMutation = useMutation({
    mutationFn: async (enabled: boolean) => {
      return setRecruitmentAiAssistEnabled(activeTenant!.id, enabled)
    },
    onSuccess: (res) => {
      setAiEnabled(res.ai_assist_enabled)
      void qc.invalidateQueries({ queryKey: recruitmentKeys.all })
      toast({ description: t('settings.ai_enabled_ok') })
    },
    onError: (err: Error) => toast({ variant: 'destructive', description: err.message }),
  })

  if (!canManage) {
    return (
      <p className="text-sm text-muted-foreground">{t('settings.forbidden')}</p>
    )
  }

  const aiConfigured = Boolean(aiAccess?.configured)
  const showSaveBar = section === 'general' || section === 'capture'

  return (
    <div className="space-y-4">
      <Tabs value={section} onValueChange={changeSection}>
        <TabsList className="flex h-auto flex-wrap gap-1">
          <TabsTrigger value="general">{t('settings.tab_general')}</TabsTrigger>
          <TabsTrigger value="capture">{t('settings.tab_capture')}</TabsTrigger>
          <TabsTrigger value="pipeline">{t('settings.tab_pipeline')}</TabsTrigger>
          <TabsTrigger value="ai">{t('settings.tab_ai')}</TabsTrigger>
        </TabsList>

        <TabsContent value="general" className="space-y-4 pt-2">
          <Panel
            title={t('settings.section_privacy')}
            description={t('settings.section_privacy_desc')}
          >
            <div className="grid gap-4 sm:grid-cols-2">
              <div className="space-y-2">
                <Label>{t('settings.max_retention')}</Label>
                <Input
                  type="number"
                  min={1}
                  max={12}
                  value={months}
                  onChange={(e) => setMonths(Number(e.target.value))}
                />
              </div>
              <div className="space-y-2">
                <Label>{t('settings.rights_sla_days')}</Label>
                <Input
                  type="number"
                  min={1}
                  max={90}
                  value={slaDays}
                  onChange={(e) => setSlaDays(Number(e.target.value))}
                />
                <p className="text-xs text-muted-foreground">{t('settings.rights_sla_days_hint')}</p>
              </div>
              <div className="space-y-2 sm:col-span-2">
                <Label>{t('settings.privacy_url')}</Label>
                <p className="text-sm text-muted-foreground">
                  {t(
                    'settings.privacy_url_legal_center',
                    'La política de candidats ja es gestiona al Legal Center (document privacy_candidates). Les ofertes públiques llegeixen aquesta font.',
                  )}{' '}
                  <Link to="/settings/legal" className="underline underline-offset-2">
                    {t('settings.open_legal_center', 'Obrir Legal')}
                  </Link>
                </p>
              </div>
              <div className="space-y-2 sm:col-span-2">
                <Label>{t('settings.candidate_portal_base_url')}</Label>
                <Input
                  placeholder={PUBLIC_PORTAL_BASE}
                  value={portalBaseUrl}
                  onChange={(e) => setPortalBaseUrl(e.target.value)}
                />
                <p className="text-xs text-muted-foreground">
                  {t('settings.candidate_portal_base_url_hint')}
                </p>
              </div>
              <div className="space-y-2 sm:col-span-2">
                <Label>{t('settings.rejection_notify_policy')}</Label>
                <Select
                  value={notifyPolicy}
                  onValueChange={(v) => setNotifyPolicy(v as 'on_decision' | 'on_posting_close')}
                >
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="on_decision">{t('settings.policy_on_decision')}</SelectItem>
                    <SelectItem value="on_posting_close">
                      {t('settings.policy_on_posting_close')}
                    </SelectItem>
                  </SelectContent>
                </Select>
                <p className="text-xs text-muted-foreground">{t('settings.rejection_notify_hint')}</p>
              </div>
            </div>
          </Panel>

          <Panel
            title={t('settings.section_notifications')}
            description={t('settings.section_notifications_desc')}
          >
            <div className="space-y-2">
              <Label>{t('settings.rights_sla_notify_emails')}</Label>
              <SlaNotifyEmailsField emails={slaEmails} onChange={setSlaEmails} />
            </div>
          </Panel>
        </TabsContent>

        <TabsContent value="capture" className="space-y-4 pt-2">
          <Panel
            title={t('settings.section_capture')}
            description={t('settings.section_capture_desc')}
          >
            <div className="grid gap-4 sm:grid-cols-2">
              <div className="space-y-2">
                <Label>{t('settings.import_legal_basis')}</Label>
                <Select value={legalBasis} onValueChange={(v) => setLegalBasis(v as LegalBasis)}>
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="legitimate_interest">
                      {t('settings.legal_basis_legitimate_interest')}
                    </SelectItem>
                    <SelectItem value="consent">{t('settings.legal_basis_consent')}</SelectItem>
                    <SelectItem value="other">{t('settings.legal_basis_other')}</SelectItem>
                  </SelectContent>
                </Select>
                <p className="text-xs text-muted-foreground">{t('settings.import_legal_basis_hint')}</p>
              </div>
              <div className="space-y-2">
                <Label>{t('settings.import_legal_basis_note')}</Label>
                <Input
                  value={legalBasisNote}
                  onChange={(e) => setLegalBasisNote(e.target.value)}
                  placeholder={t('settings.import_legal_basis_note_placeholder')}
                />
              </div>
              <div className="space-y-2">
                <Label>{t('settings.inbound_enabled')}</Label>
                <Select
                  value={inboundEnabled ? 'on' : 'off'}
                  onValueChange={(v) => setInboundEnabled(v === 'on')}
                >
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="off">{t('settings.inbound_off')}</SelectItem>
                    <SelectItem value="on">{t('settings.inbound_on')}</SelectItem>
                  </SelectContent>
                </Select>
                <p className="text-xs text-muted-foreground">{t('settings.inbound_enabled_hint')}</p>
              </div>
              <div className="space-y-2">
                <Label>{t('settings.inbound_address_hint')}</Label>
                <Input
                  value={inboundHint}
                  onChange={(e) => setInboundHint(e.target.value)}
                  placeholder="feina@empresa.com"
                />
              </div>
              <div className="space-y-2">
                <Label>{t('settings.analytics_min_cohort')}</Label>
                <Input
                  type="number"
                  min={3}
                  max={20}
                  value={minCohort}
                  onChange={(e) => setMinCohort(Number(e.target.value))}
                />
                <p className="text-xs text-muted-foreground">
                  {t('settings.analytics_min_cohort_hint')}
                </p>
              </div>
            </div>
          </Panel>
        </TabsContent>

        <TabsContent value="pipeline" className="pt-2">
          <PipelineStagesPanel />
        </TabsContent>

        <TabsContent value="ai" className="pt-2">
          <Panel title={t('settings.ai_title')} description={t('settings.ai_intro')}>
            <p className="text-xs text-muted-foreground">{t('settings.ai_art22')}</p>
            <p className="text-xs text-muted-foreground">{t('settings.ai_sensitive_hint')}</p>
            <Button type="button" variant="link" className="h-auto p-0" asChild>
              <Link to="/settings/ai">{t('settings.ai_link_settings')}</Link>
            </Button>

            <div className="flex items-start gap-2">
              <Checkbox
                id="ai-dpa"
                checked={acceptDpa}
                disabled={checklistAccepted}
                onCheckedChange={(v) => setAcceptDpa(v === true)}
              />
              <Label htmlFor="ai-dpa" className="font-normal leading-snug">
                {t('settings.ai_dpa')}
              </Label>
            </div>
            <p className="text-xs text-muted-foreground -mt-1 ml-6">
              {t(
                'settings.ai_dpa_legal_hint',
                'També podeu revisar la DPA comercial a Settings → Legal (document dpa_platform).',
              )}{' '}
              <Link to="/settings/legal" className="underline underline-offset-2">
                {t('settings.open_legal_center', 'Obrir Legal')}
              </Link>
            </p>
            <div className="flex items-start gap-2">
              <Checkbox
                id="ai-transfer"
                checked={acceptTransfer}
                disabled={checklistAccepted}
                onCheckedChange={(v) => setAcceptTransfer(v === true)}
              />
              <Label htmlFor="ai-transfer" className="font-normal leading-snug">
                {t('settings.ai_transfer')}
              </Label>
            </div>

            {!checklistAccepted && (
              <Button
                type="button"
                variant="secondary"
                disabled={checklistMutation.isPending || !acceptDpa || !acceptTransfer}
                onClick={() => checklistMutation.mutate()}
              >
                {t('settings.ai_accept_checklist')}
              </Button>
            )}

            <div className="max-w-xs space-y-2">
              <Label>{t('settings.ai_enabled')}</Label>
              <Select
                value={aiEnabled ? 'on' : 'off'}
                onValueChange={(v) => {
                  const next = v === 'on'
                  if (next && !aiConfigured) {
                    toast({ variant: 'destructive', description: t('settings.ai_need_config') })
                    return
                  }
                  if (next && !checklistAccepted) {
                    toast({ variant: 'destructive', description: t('settings.ai_need_checklist') })
                    return
                  }
                  aiToggleMutation.mutate(next)
                }}
                disabled={aiToggleMutation.isPending}
              >
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="off">{t('settings.ai_off')}</SelectItem>
                  <SelectItem value="on">{t('settings.ai_on')}</SelectItem>
                </SelectContent>
              </Select>
              {!aiConfigured && (
                <p className="text-xs text-amber-700 dark:text-amber-400">
                  {t('settings.ai_need_config')}
                </p>
              )}
            </div>
          </Panel>
        </TabsContent>
      </Tabs>

      {showSaveBar && (
        <div className="sticky bottom-0 z-[1] flex justify-end border-t bg-background/95 py-3 backdrop-blur">
          <Button
            type="button"
            disabled={saveMutation.isPending}
            onClick={() => saveMutation.mutate()}
          >
            {t('form.save')}
          </Button>
        </div>
      )}
    </div>
  )
}

export function RecruitmentSettingsPage() {
  const { t } = useTranslation('recruitment')
  return (
    <div className="space-y-2">
      <p className="mb-2 text-sm text-muted-foreground">{t('settings.page_intro')}</p>
      <RecruitmentSettingsPanel />
    </div>
  )
}
