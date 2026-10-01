import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useDocumentTemplates } from '@/features/signing/api/useDocumentTemplates'
import { useEffectiveSettings } from '@/hooks/useSettings'
import { searchContacts } from '@/features/contacts/api/contactsService'
import { generateClientOpId } from '@/features/attendance/api/clientOpId'
import { createFrameworkAgreement } from '../api/commercialFlowService'
import {
  COMMERCIAL_AGREEMENT_TEMPLATE_ID_KEY,
  parseCommercialSettingId,
  parseWorkGateDefault,
} from '../utils/deviationApprovalThreshold'
import { PLATFORM_AGREEMENT_TEMPLATE_ID,
  PLATFORM_MAINTENANCE_AGREEMENT_TEMPLATE_ID } from '../utils/commercialRelationshipBadges'
import {
  AGREEMENT_TEMPLATES_HREF,
  commercialTemplatesHref,
} from '../utils/commercialTemplatePaths'
import { AgreementTemplateSelect } from './AgreementTemplateSelect'

interface CreateFrameworkAgreementDialogProps {
  open: boolean
  tenantId: string
  /** When set, client is fixed (e.g. from contact detail). */
  clientId?: string | null
  clientName?: string | null
  onOpenChange: (open: boolean) => void
  onCreated: (agreementId: string) => void
}

export function CreateFrameworkAgreementDialog({
  open,
  tenantId,
  clientId: fixedClientId,
  clientName: fixedClientName,
  onOpenChange,
  onCreated,
}: CreateFrameworkAgreementDialogProps) {
  const { t } = useTranslation('projects')
  const { data: templates = [] } = useDocumentTemplates(open ? tenantId : undefined)
  const { data: effective } = useEffectiveSettings(
    { tenantId },
    { enabled: open && !!tenantId },
  )
  const [clientQuery, setClientQuery] = useState('')
  const [clientId, setClientId] = useState(fixedClientId ?? '')
  const [templateId, setTemplateId] = useState('')
  const [startsOn, setStartsOn] = useState('')
  const [endsOn, setEndsOn] = useState('')
  const [noticeDays, setNoticeDays] = useState('30')
  const [autoRenew, setAutoRenew] = useState(false)
  const [slaResponseHours, setSlaResponseHours] = useState('')
  const [slaResolutionHours, setSlaResolutionHours] = useState('')
  const [slaCoverageNotes, setSlaCoverageNotes] = useState('')
  const [billingCadence, setBillingCadence] = useState<'none' | 'monthly' | 'quarterly' | 'yearly'>('none')
  const [billingAmountEur, setBillingAmountEur] = useState('')
  const [billingAnchorDay, setBillingAnchorDay] = useState('1')
  const [blockWorkUntilActive, setBlockWorkUntilActive] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const agreementTemplates = templates.filter(
    (tpl) => tpl.category === 'commercial_agreement' && tpl.template_type === 'html' && tpl.id,
  )

  const contactsQuery = useQuery({
    queryKey: ['contacts', 'search', 'framework', clientQuery],
    queryFn: () => searchContacts({ q: clientQuery, limit: 20 }),
    enabled: open && !fixedClientId,
  })

  const contactOptions = useMemo(() => contactsQuery.data ?? [], [contactsQuery.data])

  useEffect(() => {
    if (!open) {
      setClientQuery('')
      setClientId(fixedClientId ?? '')
      setStartsOn('')
      setEndsOn('')
      setNoticeDays('30')
      setAutoRenew(false)
      setSlaResponseHours('')
      setSlaResolutionHours('')
      setSlaCoverageNotes('')
      setBillingCadence('none')
      setBillingAmountEur('')
      setBillingAnchorDay('1')
      setError(null)
      setBusy(false)
      return
    }
    setClientId(fixedClientId ?? '')
    setBlockWorkUntilActive(parseWorkGateDefault(effective) === 'require_signed_agreement')
    const settingId = parseCommercialSettingId(effective, COMMERCIAL_AGREEMENT_TEMPLATE_ID_KEY)
    const ids = agreementTemplates.map((tpl) => tpl.id).filter(Boolean) as string[]
    const first = ids[0] ?? ''
    const pick =
      (ids.includes(PLATFORM_MAINTENANCE_AGREEMENT_TEMPLATE_ID)
        ? PLATFORM_MAINTENANCE_AGREEMENT_TEMPLATE_ID
        : null) ||
      (settingId && ids.includes(settingId) ? settingId : null) ||
      (ids.includes(PLATFORM_AGREEMENT_TEMPLATE_ID) ? PLATFORM_AGREEMENT_TEMPLATE_ID : null) ||
      first
    setTemplateId(pick)
    // eslint-disable-next-line react-hooks/exhaustive-deps -- templates list identity is enough via length+first
  }, [open, fixedClientId, effective, agreementTemplates.length, agreementTemplates[0]?.id])

  async function handleCreate() {
    if (!clientId || !templateId || !endsOn.trim()) {
      setError(
        t(
          'projects.agreements.framework_required',
          'Cal client, plantilla i data de fi.',
        ),
      )
      return
    }
    setBusy(true)
    setError(null)
    try {
      const notice = noticeDays.trim() ? Number(noticeDays) : null
      const parsedSlaResponse = slaResponseHours.trim() ? Number(slaResponseHours) : null
      const parsedSlaResolution = slaResolutionHours.trim() ? Number(slaResolutionHours) : null
      if (
        parsedSlaResponse !== null
        && (!Number.isFinite(parsedSlaResponse) || parsedSlaResponse <= 0)
      ) {
        setError(t('projects.agreements.sla_hours_invalid', 'Les hores de resposta SLA han de ser un nombre positiu.'))
        setBusy(false)
        return
      }
      if (
        parsedSlaResolution !== null
        && (!Number.isFinite(parsedSlaResolution) || parsedSlaResolution <= 0)
      ) {
        setError(t('projects.agreements.sla_hours_invalid', 'Les hores de resolució SLA han de ser un nombre positiu.'))
        setBusy(false)
        return
      }
      let billingAmountCents: number | null = null
      if (billingCadence !== 'none') {
        const euros = Number(billingAmountEur.replace(',', '.'))
        if (!Number.isFinite(euros) || euros <= 0) {
          setError(t('projects.agreements.billing_amount_invalid', 'Indica un import periòdic positiu.'))
          setBusy(false)
          return
        }
        billingAmountCents = Math.round(euros * 100)
      }
      const parsedAnchor = billingAnchorDay.trim() ? Number(billingAnchorDay) : null
      if (
        billingCadence !== 'none'
        && parsedAnchor !== null
        && (!Number.isFinite(parsedAnchor) || parsedAnchor < 1 || parsedAnchor > 28)
      ) {
        setError(t('projects.agreements.billing_anchor_invalid', 'El dia de facturació ha d\'estar entre 1 i 28.'))
        setBusy(false)
        return
      }
      const id = await createFrameworkAgreement({
        tenantId,
        clientId,
        templateId,
        workGate: blockWorkUntilActive ? 'require_signed_agreement' : 'none',
        clientOpId: generateClientOpId(),
        startsOn: startsOn || null,
        endsOn,
        noticeDays: notice && notice > 0 ? notice : null,
        autoRenew,
        slaResponseHours: parsedSlaResponse,
        slaResolutionHours: parsedSlaResolution,
        slaCoverageNotes: slaCoverageNotes.trim() || null,
        billingCadence,
        billingAmountCents,
        billingAnchorDay: billingCadence !== 'none' ? parsedAnchor : null,
      })
      onCreated(id)
      onOpenChange(false)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] max-w-lg overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {t('projects.agreements.framework_title', 'Nou acord marc')}
          </DialogTitle>
          <DialogDescription>
            {t(
              'projects.agreements.framework_help',
              'Obre una relació comercial sense pressupost previ. Les visites o OS concretes es pressupostaran després.',
            )}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-3 py-1">
          {fixedClientId ? (
            <p className="text-sm text-foreground">
              {t('projects.agreements.framework_client', 'Client')}:{' '}
              <span className="font-medium">{fixedClientName ?? fixedClientId}</span>
            </p>
          ) : (
            <label className="flex flex-col gap-1.5 text-sm">
              <span className="font-medium">
                {t('projects.agreements.framework_client', 'Client')}
              </span>
              <input
                className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm"
                placeholder={t(
                  'projects.agreements.framework_client_search',
                  'Cerca per nom…',
                )}
                value={clientQuery}
                disabled={busy}
                onChange={(e) => setClientQuery(e.target.value)}
              />
              <select
                className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm"
                value={clientId}
                disabled={busy}
                onChange={(e) => setClientId(e.target.value)}
              >
                <option value="">
                  {t('projects.agreements.framework_client_pick', 'Tria un client')}
                </option>
                {contactOptions.map((c) => (
                  <option key={c.id} value={c.id!}>
                    {c.display_name}
                  </option>
                ))}
              </select>
            </label>
          )}

          <label className="flex flex-col gap-1.5 text-sm">
            <span className="font-medium">
              {t('projects.commercial.prepare_agreement_template', 'Plantilla d’acord')}
            </span>
            <AgreementTemplateSelect
              templates={agreementTemplates.map((tpl) => ({
                id: tpl.id!,
                name: tpl.name,
                is_platform_default: tpl.is_platform_default,
              }))}
              value={templateId}
              onChange={setTemplateId}
              disabled={busy}
            />
            <span className="text-xs text-muted-foreground">
              <Link to={AGREEMENT_TEMPLATES_HREF} className="text-indigo-600 hover:underline">
                {t('projects.agreements.manage_templates', 'Gestionar plantilles')}
              </Link>
              {' · '}
              <Link
                to={commercialTemplatesHref('commercial_agreement', { create: true })}
                className="text-indigo-600 hover:underline"
              >
                {t('projects.agreements.templates_new', 'Nova plantilla')}
              </Link>
            </span>
          </label>

          <div className="grid gap-3 sm:grid-cols-2">
            <label className="flex flex-col gap-1.5 text-sm">
              <span className="font-medium">
                {t('projects.agreements.validity_starts_label', 'Inici')}
              </span>
              <input
                type="date"
                className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm"
                value={startsOn}
                disabled={busy}
                onChange={(e) => setStartsOn(e.target.value)}
              />
            </label>
            <label className="flex flex-col gap-1.5 text-sm">
              <span className="font-medium">
                {t('projects.agreements.validity_ends_label', 'Fi')} *
              </span>
              <input
                type="date"
                className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm"
                value={endsOn}
                disabled={busy}
                onChange={(e) => setEndsOn(e.target.value)}
              />
            </label>
          </div>

          <label className="flex flex-col gap-1.5 text-sm">
            <span className="font-medium">
              {t('projects.agreements.validity_notice_label', 'Dies d’avís abans de la fi')}
            </span>
            <input
              type="number"
              min={1}
              className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm"
              value={noticeDays}
              disabled={busy}
              onChange={(e) => setNoticeDays(e.target.value)}
            />
          </label>

          <label className="flex items-start gap-2 text-sm">
            <input
              type="checkbox"
              className="mt-1"
              checked={autoRenew}
              disabled={busy}
              onChange={(e) => setAutoRenew(e.target.checked)}
            />
            <span>
              {t(
                'projects.agreements.auto_renew_label',
                'Renovar automàticament en arribar la data de fi',
              )}
            </span>
          </label>

          <div className="space-y-3 rounded-md border border-border p-3">
            <p className="text-sm font-medium">
              {t('projects.agreements.sla_section', 'SLA (opcional)')}
            </p>
            <div className="grid gap-3 sm:grid-cols-2">
              <label className="flex flex-col gap-1.5 text-sm">
                <span className="font-medium">
                  {t('projects.agreements.sla_response_label', 'Hores de resposta')}
                </span>
                <input
                  type="number"
                  min={1}
                  className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm"
                  value={slaResponseHours}
                  disabled={busy}
                  onChange={(e) => setSlaResponseHours(e.target.value)}
                />
              </label>
              <label className="flex flex-col gap-1.5 text-sm">
                <span className="font-medium">
                  {t('projects.agreements.sla_resolution_label', 'Hores de resolució')}
                </span>
                <input
                  type="number"
                  min={1}
                  className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm"
                  value={slaResolutionHours}
                  disabled={busy}
                  onChange={(e) => setSlaResolutionHours(e.target.value)}
                />
              </label>
            </div>
            <label className="flex flex-col gap-1.5 text-sm">
              <span className="font-medium">
                {t('projects.agreements.sla_coverage_label', 'Finestra de cobertura')}
              </span>
              <input
                type="text"
                className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm"
                placeholder={t(
                  'projects.agreements.sla_coverage_ph',
                  'p. ex. laborables 8-18',
                )}
                value={slaCoverageNotes}
                disabled={busy}
                onChange={(e) => setSlaCoverageNotes(e.target.value)}
              />
            </label>
          </div>

                    <div className="space-y-3 rounded-md border border-border p-3">
            <p className="text-sm font-medium">
              {t('projects.agreements.billing_section', 'Facturació periòdica (opcional)')}
            </p>
            <label className="flex flex-col gap-1.5 text-sm">
              <span className="font-medium">
                {t('projects.agreements.billing_cadence_label', 'Cadència')}
              </span>
              <select
                className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm"
                value={billingCadence}
                disabled={busy}
                onChange={(e) =>
                  setBillingCadence(e.target.value as 'none' | 'monthly' | 'quarterly' | 'yearly')
                }
              >
                <option value="none">{t('projects.agreements.billing_cadence_none', 'Sense quota')}</option>
                <option value="monthly">{t('projects.agreements.billing_cadence_monthly', 'Mensual')}</option>
                <option value="quarterly">{t('projects.agreements.billing_cadence_quarterly', 'Trimestral')}</option>
                <option value="yearly">{t('projects.agreements.billing_cadence_yearly', 'Anual')}</option>
              </select>
            </label>
            {billingCadence !== 'none' ? (
              <div className="grid gap-3 sm:grid-cols-2">
                <label className="flex flex-col gap-1.5 text-sm">
                  <span className="font-medium">
                    {t('projects.agreements.billing_amount_label', 'Import (€)')}
                  </span>
                  <input
                    type="number"
                    min={0}
                    step="0.01"
                    className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm"
                    value={billingAmountEur}
                    disabled={busy}
                    onChange={(e) => setBillingAmountEur(e.target.value)}
                  />
                </label>
                <label className="flex flex-col gap-1.5 text-sm">
                  <span className="font-medium">
                    {t('projects.agreements.billing_anchor_label', 'Dia del mes (1–28)')}
                  </span>
                  <input
                    type="number"
                    min={1}
                    max={28}
                    className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm"
                    value={billingAnchorDay}
                    disabled={busy}
                    onChange={(e) => setBillingAnchorDay(e.target.value)}
                  />
                </label>
              </div>
            ) : null}
          </div>

<label className="flex items-start gap-2 text-sm">
            <input
              type="checkbox"
              className="mt-1"
              checked={blockWorkUntilActive}
              disabled={busy}
              onChange={(e) => setBlockWorkUntilActive(e.target.checked)}
            />
            <span>
              {t(
                'projects.commercial.prepare_agreement_gate',
                'No iniciar la feina fins que aquest contracte estigui actiu',
              )}
            </span>
          </label>

          {error ? <p className="text-sm text-destructive">{error}</p> : null}
        </div>

        <DialogFooter>
          <Button type="button" variant="ghost" disabled={busy} onClick={() => onOpenChange(false)}>
            {t('projects.commercial.prepare_agreement_close', 'Tancar')}
          </Button>
          <Button type="button" disabled={busy} onClick={() => void handleCreate()}>
            {busy
              ? t('projects.agreements.framework_busy', 'Creant…')
              : t('projects.agreements.framework_confirm', 'Crear acord marc')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
