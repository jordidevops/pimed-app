import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
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
import { callSignDocumentRouter } from '@/features/signing/api/signingService'
import { generateClientOpId } from '@/features/attendance/api/clientOpId'
import { supabase } from '@/lib/supabase'
import {
  markAgreementSentForSignature,
  prepareAgreementFromQuote,
  renderCommercialAgreementPdf,
  type CommercialAgreementKind,
} from '../api/commercialFlowService'
import {
  COMMERCIAL_AGREEMENT_TEMPLATE_ID_KEY,
  parseCommercialSettingId,
  parseWorkGateDefault,
} from '../utils/deviationApprovalThreshold'
import {
  PLATFORM_AGREEMENT_TEMPLATE_ID,
  PLATFORM_MAINTENANCE_AGREEMENT_TEMPLATE_ID,
} from '../utils/commercialRelationshipBadges'
import { AgreementFlowSteps } from './AgreementFlowSteps'
import { AgreementTemplateSelect } from './AgreementTemplateSelect'
import {
  AGREEMENT_TEMPLATES_HREF,
  commercialTemplatesHref,
} from '../utils/commercialTemplatePaths'

type AgreementRow = {
  id: string
  status: string
  active_version_id: string | null
}

type VersionRow = {
  id: string
  status: string
  source_quote_content_hash: string | null
  rendered_document_id: string | null
}

interface PrepareAgreementDialogProps {
  open: boolean
  mode: 'prepare' | 'followup'
  tenantId: string
  documentId: string
  buyerName: string
  onOpenChange: (open: boolean) => void
  onChanged: () => void
}

export function PrepareAgreementDialog({
  open,
  mode,
  tenantId,
  documentId,
  buyerName,
  onOpenChange,
  onChanged,
}: PrepareAgreementDialogProps) {
  const { t } = useTranslation('projects')
  const { data: templates = [] } = useDocumentTemplates(open ? tenantId : undefined)
  const { data: effective } = useEffectiveSettings(
    { tenantId },
    { enabled: open && !!tenantId },
  )
  const [templateId, setTemplateId] = useState('')
  const [agreement, setAgreement] = useState<AgreementRow | null>(null)
  const [version, setVersion] = useState<VersionRow | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [confirmed, setConfirmed] = useState(false)
  const [blockWorkUntilActive, setBlockWorkUntilActive] = useState(false)
  const [agreementKind, setAgreementKind] = useState<CommercialAgreementKind>('specific')
  const [startsOn, setStartsOn] = useState('')
  const [endsOn, setEndsOn] = useState('')
  const [noticeDays, setNoticeDays] = useState('')
  const [autoRenew, setAutoRenew] = useState(false)
  const [slaResponseHours, setSlaResponseHours] = useState('')
  const [slaResolutionHours, setSlaResolutionHours] = useState('')
  const [slaCoverageNotes, setSlaCoverageNotes] = useState('')
  const [billingCadence, setBillingCadence] = useState<'none' | 'monthly' | 'quarterly' | 'yearly'>('none')
  const [billingAmountEur, setBillingAmountEur] = useState('')
  const [billingAnchorDay, setBillingAnchorDay] = useState('1')

  const agreementTemplates = templates.filter(
    (tpl) => tpl.category === 'commercial_agreement' && tpl.template_type === 'html' && tpl.id,
  )

  useEffect(() => {
    if (!open) {
      setConfirmed(false)
      setBlockWorkUntilActive(false)
      setAgreementKind('specific')
      setStartsOn('')
      setEndsOn('')
      setNoticeDays('')
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
    setBlockWorkUntilActive(parseWorkGateDefault(effective) === 'require_signed_agreement')
    let cancelled = false
    void (async () => {
      const { data } = await supabase
        .from('commercial_agreements' as never)
        .select('id, status, active_version_id')
        .eq('source_quote_id', documentId)
        .neq('status', 'cancelled')
        .limit(1)
        .maybeSingle()
      if (cancelled) return
      const row = (data ?? null) as AgreementRow | null
      setAgreement(row)
      if (!row?.active_version_id) {
        setVersion(null)
        return
      }
      const { data: versionData } = await supabase
        .from('commercial_agreement_versions' as never)
        .select('id, status, source_quote_content_hash, rendered_document_id')
        .eq('id', row.active_version_id)
        .maybeSingle()
      if (!cancelled) setVersion((versionData ?? null) as VersionRow | null)
    })()
    return () => {
      cancelled = true
    }
  }, [open, documentId, effective])

  useEffect(() => {
    if (!open) return
    const kindPrefersMaintenance =
      agreementKind === 'recurring' || agreementKind === 'framework'
    const preferredId =
      (kindPrefersMaintenance ? PLATFORM_MAINTENANCE_AGREEMENT_TEMPLATE_ID : null)
      ?? parseCommercialSettingId(effective, COMMERCIAL_AGREEMENT_TEMPLATE_ID_KEY)
      ?? PLATFORM_AGREEMENT_TEMPLATE_ID
    const preferred =
      agreementTemplates.find((tpl) => tpl.id === preferredId)
      ?? (kindPrefersMaintenance
        ? agreementTemplates.find((tpl) => tpl.id === PLATFORM_MAINTENANCE_AGREEMENT_TEMPLATE_ID)
        : null)
      ?? agreementTemplates.find((tpl) => tpl.id === PLATFORM_AGREEMENT_TEMPLATE_ID)
    setTemplateId((current) => {
      if (!current) return preferred?.id || agreementTemplates[0]?.id || ''
      if (kindPrefersMaintenance && preferred?.id && current === PLATFORM_AGREEMENT_TEMPLATE_ID) {
        return preferred.id
      }
      return current
    })
  }, [open, templates, effective, agreementKind])

  async function reload() {
    const { data } = await supabase
      .from('commercial_agreements' as never)
      .select('id, status, active_version_id')
      .eq('source_quote_id', documentId)
      .neq('status', 'cancelled')
      .limit(1)
      .maybeSingle()
    const row = (data ?? null) as AgreementRow | null
    setAgreement(row)
    if (!row?.active_version_id) {
      setVersion(null)
      return
    }
    const { data: versionData } = await supabase
      .from('commercial_agreement_versions' as never)
      .select('id, status, source_quote_content_hash, rendered_document_id')
      .eq('id', row.active_version_id)
      .maybeSingle()
    setVersion((versionData ?? null) as VersionRow | null)
  }

  async function handlePrepare() {
    if (!templateId || busy) return
    if (
      (agreementKind === 'recurring' || agreementKind === 'framework') &&
      !endsOn.trim()
    ) {
      setError(t('projects.commercial.prepare_agreement_ends_required', 'Indica la data de fi del contracte.'))
      return
    }
    const parsedNotice = noticeDays.trim() ? Number(noticeDays) : null
    if (parsedNotice !== null && (!Number.isFinite(parsedNotice) || parsedNotice <= 0)) {
      setError(t('projects.commercial.prepare_agreement_notice_invalid', 'Els dies d\u2019av\u00eds han de ser un n\u00famero positiu.'))
      return
    }
    const showSla = agreementKind === 'recurring' || agreementKind === 'framework'
    const parsedSlaResponse = slaResponseHours.trim() ? Number(slaResponseHours) : null
    const parsedSlaResolution = slaResolutionHours.trim() ? Number(slaResolutionHours) : null
    if (
      showSla
      && parsedSlaResponse !== null
      && (!Number.isFinite(parsedSlaResponse) || parsedSlaResponse <= 0)
    ) {
      setError(t('projects.agreements.sla_hours_invalid', 'Les hores de resposta SLA han de ser un nombre positiu.'))
      return
    }
    if (
      showSla
      && parsedSlaResolution !== null
      && (!Number.isFinite(parsedSlaResolution) || parsedSlaResolution <= 0)
    ) {
      setError(t('projects.agreements.sla_hours_invalid', 'Les hores de resolució SLA han de ser un nombre positiu.'))
      return
    }
    let billingAmountCents: number | null = null
    if (showSla && billingCadence !== 'none') {
      const euros = Number(billingAmountEur.replace(',', '.'))
      if (!Number.isFinite(euros) || euros <= 0) {
        setError(t('projects.agreements.billing_amount_invalid', 'Indica un import periòdic positiu.'))
        return
      }
      billingAmountCents = Math.round(euros * 100)
    }
    const parsedAnchor = billingAnchorDay.trim() ? Number(billingAnchorDay) : null
    if (
      showSla
      && billingCadence !== 'none'
      && parsedAnchor !== null
      && (!Number.isFinite(parsedAnchor) || parsedAnchor < 1 || parsedAnchor > 28)
    ) {
      setError(t('projects.agreements.billing_anchor_invalid', 'El dia de facturació ha d\'estar entre 1 i 28.'))
      return
    }
    setBusy(true)
    setError(null)
    try {
      await prepareAgreementFromQuote({
        documentId,
        templateId,
        workGate: blockWorkUntilActive ? 'require_signed_agreement' : 'none',
        kind: agreementKind,
        startsOn: startsOn.trim() || null,
        endsOn: endsOn.trim() || null,
        noticeDays: parsedNotice,
        autoRenew: showSla ? autoRenew : false,
        slaResponseHours: showSla ? parsedSlaResponse : null,
        slaResolutionHours: showSla ? parsedSlaResolution : null,
        slaCoverageNotes: showSla ? slaCoverageNotes.trim() || null : null,
        billingCadence: showSla ? billingCadence : 'none',
        billingAmountCents: showSla ? billingAmountCents : null,
        billingAnchorDay:
          showSla && billingCadence !== 'none' ? parsedAnchor : null,
      })
      setConfirmed(true)
      await reload()
      onChanged()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  async function handleSend() {
    if (!version || busy) return
    setBusy(true)
    setError(null)
    try {
      const rendered = await renderCommercialAgreementPdf({
        versionId: version.id,
        tenantId,
      })
      if (!rendered.version_id) throw new Error('agreement_pdf_required')
      await reload()
      const fresh = version
      const { data: versionData } = await supabase
        .from('commercial_agreement_versions' as never)
        .select('id, status, source_quote_content_hash, rendered_document_id')
        .eq('id', fresh.id)
        .maybeSingle()
      const nextVersion = (versionData ?? null) as VersionRow | null
      setVersion(nextVersion)
      if (!nextVersion?.rendered_document_id) throw new Error('agreement_pdf_required')
      const opId = generateClientOpId()
      const result = await callSignDocumentRouter({
        tenant_id: tenantId,
        action: 'sign_native',
        source_type: 'document_existing',
        source_document_version_id: rendered.version_id,
        document_title: t('projects.commercial.agreement_pdf_title', 'Contracte de serveis'),
        native_sign_type: 'presential',
        output_format: 'pdf',
        output_profile: 'pdfa2b',
        signer_name: buyerName,
        signer_role: 'client',
        client_request_id: opId,
      })
      await markAgreementSentForSignature({
        versionId: nextVersion.id,
        submissionId: result.submission_id ?? null,
        clientOpId: opId,
      })
      await reload()
      onChanged()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  const followup = mode === 'followup' || agreement !== null
  const readyToSend = version?.status === 'draft'
  const pending = version?.status === 'pending_signature'
  const signed = version?.status === 'signed'

  const title = !followup
    ? t('projects.commercial.prepare_agreement_title', 'Preparar acord')
    : signed
      ? t('projects.commercial.agreement_status_signed', 'Acord firmat')
      : pending
        ? t('projects.commercial.agreement_status_pending', 'Acord pendent de firma')
        : t('projects.commercial.prepare_agreement_existing_title', 'Acord d’aquest pressupost')

  const description = !followup
    ? t(
        'projects.commercial.prepare_agreement_help',
        'Tria la plantilla d’acord. El pressupost acceptat queda com a annex. Acceptar no crea l’acord.',
      )
    : signed
      ? t(
          'projects.commercial.prepare_agreement_existing_signed',
          'El client ja l’ha firmat. El PDF és al Centre de signatures.',
        )
      : pending
        ? t(
            'projects.commercial.prepare_agreement_existing_pending',
            'Ja s’ha enviat al client. El PDF i la firma són al Centre de signatures.',
          )
        : t(
            'projects.commercial.prepare_agreement_existing_draft',
            'Ja està preparat. Encara no hi ha PDF: es crea quan l’envies a firmar.',
          )

  return (
    <Dialog open={open} onOpenChange={(next) => !busy && onOpenChange(next)}>
      <DialogContent className="flex max-h-[90vh] max-w-md flex-col gap-0 overflow-hidden p-0">
        <div className="shrink-0 space-y-3 border-b border-border px-6 pb-4 pt-6 pr-12">
          <DialogHeader>
            <DialogTitle>{title}</DialogTitle>
            <DialogDescription>{description}</DialogDescription>
          </DialogHeader>
          <AgreementFlowSteps
            agreementStatus={agreement?.status}
            versionStatus={version?.status}
            className="flex flex-wrap gap-2 text-xs"
          />
        </div>

        <div className="min-h-0 flex-1 space-y-4 overflow-y-auto px-6 py-4">
          {!followup ? (
            <>
              <label className="flex flex-col gap-1.5">
                <span className="text-sm font-medium">
                  {t('projects.commercial.prepare_agreement_type', 'Tipus d’acord')}
                </span>
                <select
                  className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm"
                  value={agreementKind}
                  disabled={busy}
                  onChange={(e) => setAgreementKind(e.target.value as CommercialAgreementKind)}
                >
                  <option value="specific">
                    {t('projects.commercial.prepare_agreement_type_specific', 'Obra puntual')}
                  </option>
                  <option value="recurring">
                    {t('projects.commercial.prepare_agreement_type_recurring', 'Manteniment / vigència')}
                  </option>
                  <option value="framework">
                    {t(
                      'projects.commercial.prepare_agreement_type_framework',
                      'Marc (amb annex de pressupost)',
                    )}
                  </option>
                </select>
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
                    {t('projects.agreements.validity_ends_label', 'Fi')}
                    {agreementKind === 'recurring' || agreementKind === 'framework' ? ' *' : ''}
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
                  placeholder="30"
                  value={noticeDays}
                  disabled={busy}
                  onChange={(e) => setNoticeDays(e.target.value)}
                />
              </label>
              {agreementKind === 'recurring' || agreementKind === 'framework' ? (
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
              ) : null}
              {agreementKind === 'recurring' || agreementKind === 'framework' ? (
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
              ) : null}
              {agreementKind === 'recurring' || agreementKind === 'framework' ? (
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
                        setBillingCadence(
                          e.target.value as 'none' | 'monthly' | 'quarterly' | 'yearly',
                        )
                      }
                    >
                      <option value="none">
                        {t('projects.agreements.billing_cadence_none', 'Sense quota')}
                      </option>
                      <option value="monthly">
                        {t('projects.agreements.billing_cadence_monthly', 'Mensual')}
                      </option>
                      <option value="quarterly">
                        {t('projects.agreements.billing_cadence_quarterly', 'Trimestral')}
                      </option>
                      <option value="yearly">
                        {t('projects.agreements.billing_cadence_yearly', 'Anual')}
                      </option>
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
              ) : null}
              <label className="flex flex-col gap-1.5">
                <span className="text-sm font-medium">
                  {t('projects.commercial.prepare_agreement_template', 'Plantilla d’acord')}
                </span>
                <p className="text-xs text-muted-foreground">
                  {t(
                    'projects.commercial.prepare_agreement_template_help',
                    'Model reutilitzable. Les dades del pressupost s’hi omplen en preparar.',
                  )}
                </p>
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
            </>
          ) : null}

          {error ? (
            <p className="text-sm text-destructive" role="alert">
              {error}
            </p>
          ) : null}
        </div>

        <DialogFooter className="shrink-0 flex-col items-stretch gap-2 border-t border-border px-6 py-4 sm:flex-col">
          {!followup ? (
            <label className="flex items-start gap-2 text-sm">
              <input
                type="checkbox"
                checked={blockWorkUntilActive}
                disabled={busy}
                onChange={(e) => setBlockWorkUntilActive(e.target.checked)}
              />
              <span>
                {t(
                  'projects.commercial.prepare_agreement_gate',
                  'No iniciar la feina fins que aquest acord estigui actiu',
                )}
              </span>
            </label>
          ) : null}
          {!followup ? (
            <label className="flex items-start gap-2 text-sm">
              <input
                type="checkbox"
                checked={confirmed}
                disabled={busy}
                onChange={(e) => setConfirmed(e.target.checked)}
              />
              <span>
                {t(
                  'projects.commercial.prepare_agreement_ack',
                  'Confirmo que vull preparar un contracte separat. Acceptar el pressupost no el crea automàticament.',
                )}
              </span>
            </label>
          ) : null}
          {!followup ? (
            <Button
              type="button"
              disabled={busy || !templateId || !confirmed}
              onClick={() => void handlePrepare()}
            >
              {t('projects.commercial.prepare_agreement_confirm', 'Preparar acord')}
            </Button>
          ) : null}
          {readyToSend ? (
            <Button type="button" disabled={busy} onClick={() => void handleSend()}>
              {t('projects.commercial.prepare_agreement_send', 'Enviar a firmar (client)')}
            </Button>
          ) : null}
          {followup ? (
            <Button type="button" variant="outline" asChild>
              <Link to="/agreements">
                {t('projects.commercial.prepare_agreement_open_list', 'Veure a Acords comercials')}
              </Link>
            </Button>
          ) : null}
          {version?.rendered_document_id ? (
            <Button type="button" variant="outline" asChild>
              <Link to={`/documents/${version.rendered_document_id}`}>
                {t('projects.commercial.prepare_agreement_open_pdf', 'Obrir el PDF')}
              </Link>
            </Button>
          ) : null}
          {pending || signed ? (
            <Button type="button" variant="outline" asChild>
              <Link to="/documents/signing">
                {t('projects.commercial.prepare_agreement_centre', 'Centre de signatures')}
              </Link>
            </Button>
          ) : null}
          <Button type="button" variant="outline" disabled={busy} onClick={() => onOpenChange(false)}>
            {followup
              ? t('projects.commercial.prepare_agreement_close', 'Tancar')
              : t('common.cancel', 'Cancel·lar')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
