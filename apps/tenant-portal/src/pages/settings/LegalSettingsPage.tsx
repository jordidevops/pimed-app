import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Scale } from 'lucide-react'
import { useToast } from '@/hooks/use-toast'
import { usePermission } from '@/hooks/usePermission'
import { Label } from '@/components/ui/label'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { Button } from '@/components/ui/button'
import {
  LEGAL_DOC_CODES,
  acknowledgeTenantPlatformDpa,
  executeCustomerPortalDsarRevoke,
  getCustomerPortalRetentionStatus,
  getTenantLegalCenter,
  listCustomerPortalDsarActions,
  previewTenantLegalDocument,
  setTenantLegalDocumentMode,
  upsertTenantLegalProfile,
  type LegalDocCode,
  type LegalDocMode,
  type TenantLegalProfile,
} from '@/features/legal/api/legalCenterService'
import { Link } from 'react-router-dom'
import DOMPurify from 'dompurify'

const PREVIEW_HTML_ALLOWED = {
  ALLOWED_TAGS: [
    'p', 'br', 'strong', 'em', 'ul', 'ol', 'li', 'h1', 'h2', 'h3', 'h4', 'span', 'a',
  ],
  ALLOWED_ATTR: ['href', 'title', 'rel', 'target', 'class'],
}

function isSafeHttpsUrl(url: string | null | undefined): boolean {
  if (!url?.trim()) return false
  try {
    return new URL(url.trim()).protocol === 'https:'
  } catch {
    return false
  }
}

const DOC_LABELS: Record<LegalDocCode, { ca: string }> = {
  privacy_customers: { ca: 'Privacitat clients / butlletí' },
  legal_notice: { ca: 'Avís legal (LSSI)' },
  portal_terms_customers: { ca: 'Condicions portal client' },
  cookie_notice: { ca: 'Avís de cookies' },
  privacy_website: { ca: 'Privacitat web / leads' },
  privacy_employees: { ca: 'Privacitat empleats' },
  employee_portal_terms: { ca: 'Condicions portal empleat' },
  privacy_candidates: { ca: 'Privacitat candidats' },
  dpa_platform: { ca: 'DPA plataforma (tenant)' },
}

function profileFromPayload(p: TenantLegalProfile | undefined) {
  return {
    legal_name: p?.legal_name ?? '',
    trade_name: p?.trade_name ?? '',
    nif: p?.nif ?? '',
    registry_info: p?.registry_info ?? '',
    privacy_email: p?.privacy_email ?? '',
    dpo_email: p?.dpo_email ?? '',
    dpo_name: p?.dpo_name ?? '',
    postal_address: p?.postal_address ?? '',
    website_url: p?.website_url ?? '',
    retention_summary: p?.retention_summary ?? '',
  }
}

export function LegalSettingsPage() {
  const { t } = useTranslation('settings')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const canManage = usePermission('settings.manage')
  const [form, setForm] = useState(profileFromPayload(undefined))
  const [previewHtml, setPreviewHtml] = useState<string | null>(null)
  const [previewTitle, setPreviewTitle] = useState<string | null>(null)
  const [dsarContactId, setDsarContactId] = useState('')
  const [dsarReason, setDsarReason] = useState('')
  const [dsarBlockVersions, setDsarBlockVersions] = useState(false)

  const query = useQuery({
    queryKey: ['tenant-legal-center'],
    enabled: canManage,
    queryFn: getTenantLegalCenter,
  })

  const retentionQuery = useQuery({
    queryKey: ['customer-portal-retention-status'],
    enabled: canManage,
    queryFn: getCustomerPortalRetentionStatus,
  })

  const dsarQuery = useQuery({
    queryKey: ['customer-portal-dsar-actions'],
    enabled: canManage,
    queryFn: () => listCustomerPortalDsarActions(10),
  })

  useEffect(() => {
    if (!query.data?.profile) return
    setForm(profileFromPayload(query.data.profile))
  }, [query.data?.profile])

  const docsByCode = useMemo(() => {
    const map = new Map<string, { mode: LegalDocMode; external_url: string | null }>()
    for (const d of query.data?.documents ?? []) {
      map.set(d.code, { mode: d.mode, external_url: d.external_url })
    }
    return map
  }, [query.data?.documents])

  const saveProfile = useMutation({
    mutationFn: () => upsertTenantLegalProfile(form),
    onSuccess: (data) => {
      void queryClient.setQueryData(['tenant-legal-center'], data)
      toast({
        title: t('legal.profileSaved', 'Perfil legal desat'),
      })
    },
    onError: () => {
      toast({
        variant: 'destructive',
        title: t('legal.profileSaveError', 'No s\'ha pogut desar el perfil legal'),
      })
    },
  })

  const setMode = useMutation({
    mutationFn: (params: {
      code: LegalDocCode
      mode: LegalDocMode
      externalUrl?: string | null
    }) => setTenantLegalDocumentMode(params),
    onSuccess: (data) => {
      void queryClient.setQueryData(['tenant-legal-center'], data)
      toast({ title: t('legal.modeSaved', 'Mode del document actualitzat') })
    },
    onError: () => {
      toast({
        variant: 'destructive',
        title: t('legal.modeSaveError', 'No s\'ha pogut actualitzar el mode'),
      })
    },
  })

  const dsarMutate = useMutation({
    mutationFn: () =>
      executeCustomerPortalDsarRevoke({
        contactId: dsarContactId.trim(),
        reason: dsarReason.trim() || undefined,
        blockAccountVersions: dsarBlockVersions,
      }),
    onSuccess: (res) => {
      void queryClient.invalidateQueries({ queryKey: ['customer-portal-dsar-actions'] })
      void queryClient.invalidateQueries({ queryKey: ['customer-portal-retention-status'] })
      toast({
        title: t('legal.dsarDone', 'Accés customer-portal revocat'),
        description: t(
          'legal.dsarDoneDesc',
          '{{shares}} shares, {{grants}} grants, {{invites}} invitacions',
          {
            shares: res.shares_revoked,
            grants: res.grants_revoked,
            invites: res.invitations_revoked,
          },
        ),
      })
      setDsarContactId('')
      setDsarReason('')
      setDsarBlockVersions(false)
    },
    onError: (e) => {
      toast({
        variant: 'destructive',
        title: t('legal.dsarError', 'No s\'ha pogut executar el DSAR'),
        description: (e as Error).message,
      })
    },
  })

  const ackDpa = useMutation({
    mutationFn: acknowledgeTenantPlatformDpa,
    onSuccess: (data) => {
      void queryClient.setQueryData(['tenant-legal-center'], data)
      toast({ title: t('legal.dpaAckSaved', 'DPA de plataforma reconeguda') })
    },
    onError: (e) => {
      toast({
        variant: 'destructive',
        title: t('legal.dpaAckError', 'No s\'ha pogut registrar el reconeixement'),
        description: (e as Error).message,
      })
    },
  })

  async function handlePreview(code: LegalDocCode) {
    try {
      const res = await previewTenantLegalDocument(code, 'ca')
      if (!res.ok) {
        toast({
          variant: 'destructive',
          title: t('legal.previewError', 'No s\'ha pogut previsualitzar'),
          description: res.error,
        })
        return
      }
      if (res.mode === 'external_url' && res.external_url) {
        if (!isSafeHttpsUrl(res.external_url)) {
          toast({
            variant: 'destructive',
            title: t('legal.invalidExternalUrl', 'URL externa no vàlida (cal https://)'),
          })
          return
        }
        window.open(res.external_url, '_blank', 'noopener,noreferrer')
        return
      }
      setPreviewTitle(res.title ?? code)
      setPreviewHtml(DOMPurify.sanitize(res.body_html ?? '', PREVIEW_HTML_ALLOWED))
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('legal.previewError', 'No s\'ha pogut previsualitzar'),
        description: (e as Error).message,
      })
    }
  }

  if (!canManage) {
    return (
      <p className="text-sm text-muted-foreground">
        {t('legal.noPermission', 'Cal el permís settings.manage per gestionar Legal.')}
      </p>
    )
  }

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-lg font-semibold flex items-center gap-2">
          <Scale className="h-5 w-5" />
          {t('legal.title', 'Legal i compliment')}
        </h2>
        <p className="mt-1 text-sm text-muted-foreground">
          {t(
            'legal.subtitle',
            'Plantilles de la plataforma amb els vostres dades. Sou el responsable del tractament; la plataforma és l’encarregat.',
          )}
        </p>
        {query.data?.disclaimer ? (
          <p className="mt-2 text-xs text-muted-foreground border rounded-md p-3 bg-muted/40">
            {query.data.disclaimer}
          </p>
        ) : null}
        {query.data?.incomplete ? (
          <p className="mt-2 text-sm text-amber-800 bg-amber-50 border border-amber-200 rounded-md p-3">
            {t(
              'legal.incompleteBanner',
              'Falten el nom legal o l’email de privacitat. Completeu-los per mostrar polítiques coherents (no bloqueja publicar butlletins).',
            )}
          </p>
        ) : null}
        {query.data && query.data.dpa_acknowledged !== true ? (
          <div className="mt-2 text-sm text-amber-800 bg-amber-50 border border-amber-200 rounded-md p-3 space-y-2">
            <p>
              {t(
                'legal.dpaSoftBanner',
                'Pendents de revisar la DPA plataforma (encarregat). És un deure soft: no bloqueja publicació ni careers. La IA de selecció té el seu propi checklist.',
              )}
            </p>
            <div className="flex flex-wrap gap-2">
              <Button
                type="button"
                size="sm"
                variant="outline"
                onClick={() => void handlePreview('dpa_platform')}
              >
                {t('legal.previewDpa', 'Previsualitzar DPA')}
              </Button>
              <Button
                type="button"
                size="sm"
                disabled={ackDpa.isPending}
                onClick={() => ackDpa.mutate()}
              >
                {t('legal.ackDpa', 'He revisat la DPA')}
              </Button>
            </div>
          </div>
        ) : query.data?.dpa_acknowledged_at ? (
          <p className="mt-2 text-xs text-muted-foreground">
            {t('legal.dpaAckedAt', 'DPA reconeguda')}:{' '}
            {new Date(query.data.dpa_acknowledged_at).toLocaleString()}
          </p>
        ) : null}
        {query.data?.privacy_candidates_note ? (
          <p className="mt-2 text-xs text-muted-foreground border rounded-md p-3">
            {query.data.privacy_candidates_note}
          </p>
        ) : null}
      </div>

      <section className="rounded-2xl border p-5 space-y-3">
        <h3 className="text-sm font-semibold">
          {t('legal.profileTitle', 'Identitat del responsable')}
        </h3>
        <div className="grid gap-3 sm:grid-cols-2">
          {(
            [
              ['legal_name', 'Nom legal'],
              ['trade_name', 'Nom comercial'],
              ['nif', 'NIF'],
              ['privacy_email', 'Email privacitat'],
              ['dpo_email', 'Email DPO'],
              ['dpo_name', 'Nom DPO'],
              ['website_url', 'Web'],
            ] as const
          ).map(([key, label]) => (
            <div key={key} className="space-y-1">
              <Label htmlFor={`legal-${key}`}>{t(`legal.field_${key}`, label)}</Label>
              <Input
                id={`legal-${key}`}
                value={form[key]}
                onChange={(e) => setForm((f) => ({ ...f, [key]: e.target.value }))}
                disabled={saveProfile.isPending}
              />
            </div>
          ))}
        </div>
        <div className="space-y-1">
          <Label htmlFor="legal-postal">{t('legal.field_postal_address', 'Adreça')}</Label>
          <Textarea
            id="legal-postal"
            rows={2}
            value={form.postal_address}
            onChange={(e) => setForm((f) => ({ ...f, postal_address: e.target.value }))}
            disabled={saveProfile.isPending}
          />
        </div>
        <div className="space-y-1">
          <Label htmlFor="legal-registry">{t('legal.field_registry_info', 'Registre mercantil')}</Label>
          <Textarea
            id="legal-registry"
            rows={2}
            value={form.registry_info}
            onChange={(e) => setForm((f) => ({ ...f, registry_info: e.target.value }))}
            disabled={saveProfile.isPending}
          />
        </div>
        <div className="space-y-1">
          <Label htmlFor="legal-retention">
            {t('legal.field_retention_summary', 'Resum de conservació')}
          </Label>
          <Textarea
            id="legal-retention"
            rows={2}
            value={form.retention_summary}
            onChange={(e) => setForm((f) => ({ ...f, retention_summary: e.target.value }))}
            disabled={saveProfile.isPending}
            placeholder={t(
              'legal.retentionPlaceholder',
              'Ex.: versions de butlletí ≥ 365 dies; sessions curtes; logs 12–24 mesos.',
            )}
          />
        </div>
        <Button
          type="button"
          size="sm"
          disabled={saveProfile.isPending || query.isLoading}
          onClick={() => saveProfile.mutate()}
        >
          {t('legal.saveProfile', 'Desar perfil')}
        </Button>
      </section>

      <section className="rounded-2xl border p-5 space-y-3">
        <h3 className="text-sm font-semibold">
          {t('legal.documentsTitle', 'Documents')}
        </h3>
        <p className="text-xs text-muted-foreground">
          {t(
            'legal.documentsHint',
            'Mode plantilla (recomanat), URL externa, o editat (publiqueu el cos des d’una versió futura).',
          )}
        </p>
        <ul className="space-y-3">
          {LEGAL_DOC_CODES.map((code) => {
            const row = docsByCode.get(code)
            const mode = row?.mode ?? 'template'
            return (
              <li
                key={code}
                className="rounded-lg border border-border p-3 space-y-2"
              >
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <p className="text-sm font-medium">{DOC_LABELS[code].ca}</p>
                  <div className="flex gap-2">
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      onClick={() => void handlePreview(code)}
                    >
                      {t('legal.preview', 'Previsualitzar')}
                    </Button>
                  </div>
                </div>
                <div className="flex flex-wrap gap-2 items-end">
                  <div className="space-y-1 min-w-[10rem]">
                    <Label htmlFor={`mode-${code}`}>{t('legal.mode', 'Mode')}</Label>
                    <select
                      id={`mode-${code}`}
                      className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                      value={mode}
                      disabled={setMode.isPending}
                      onChange={(e) => {
                        const next = e.target.value as LegalDocMode
                        if (next === 'edited') {
                          toast({
                            variant: 'destructive',
                            title: t(
                              'legal.editedUnavailable',
                              'Mode editat encara no té editor/publicació a la UI',
                            ),
                            description: t(
                              'legal.editedUnavailableHint',
                              'Usa plantilla o URL externa (https://).',
                            ),
                          })
                          return
                        }
                        if (next === 'external_url') {
                          const url =
                            row?.external_url ||
                            window.prompt(
                              t(
                                'legal.externalUrlPrompt',
                                'URL externa del document (https://…)',
                              ),
                              'https://',
                            )
                          if (!url) return
                          if (!isSafeHttpsUrl(url)) {
                            toast({
                              variant: 'destructive',
                              title: t(
                                'legal.invalidExternalUrl',
                                'URL externa no vàlida (cal https://)',
                              ),
                            })
                            return
                          }
                          setMode.mutate({ code, mode: next, externalUrl: url.trim() })
                        } else {
                          setMode.mutate({ code, mode: next })
                        }
                      }}
                    >
                      <option value="template">
                        {t('legal.mode_template', 'Plantilla plataforma')}
                      </option>
                      {mode === 'edited' ? (
                        <option value="edited">
                          {t('legal.mode_edited', 'Editat (sense publicació UI)')}
                        </option>
                      ) : null}
                      <option value="external_url">
                        {t('legal.mode_external', 'URL externa')}
                      </option>
                    </select>
                  </div>
                  {mode === 'edited' ? (
                    <p className="text-xs text-amber-700 dark:text-amber-400 max-w-md">
                      {t(
                        'legal.editedStuckHint',
                        'Aquest document està en mode editat sense editor. Torna a plantilla o URL externa per publicar contingut visible.',
                      )}
                    </p>
                  ) : null}
                  {mode === 'external_url' && row?.external_url ? (
                    <p className="text-xs text-muted-foreground truncate max-w-md">
                      {row.external_url}
                    </p>
                  ) : null}
                </div>
              </li>
            )
          })}
        </ul>
      </section>

      <section className="rounded-2xl border p-5 space-y-3">
        <h3 className="text-sm font-semibold">
          {t('legal.retentionTitle', 'Retenció customer-portal')}
        </h3>
        <p className="text-xs text-muted-foreground">
          {t(
            'legal.retentionHint',
            'Jobs nocturns: drafts, sessions, logs i estats de versió (active → blocked → purge_eligible). No s’esborren versions publicades automàticament.',
          )}
        </p>
        {retentionQuery.isLoading ? (
          <p className="text-sm text-muted-foreground">{t('legal.loading', 'Carregant…')}</p>
        ) : retentionQuery.data ? (
          <div className="grid gap-2 sm:grid-cols-2 text-sm">
            <p>
              {t('legal.retentionEnabled', 'Purge actiu')}:{' '}
              {retentionQuery.data.settings.enabled
                ? t('legal.yes', 'Sí')
                : t('legal.no', 'No')}
            </p>
            <p>
              {t('legal.retentionVersionDays', 'Versions (≥ dies)')}:{' '}
              {retentionQuery.data.settings.version_retention_days}
            </p>
            <p>
              {t('legal.retentionDraftDays', 'Drafts (dies)')}:{' '}
              {retentionQuery.data.settings.draft_retention_days}
            </p>
            <p>
              {t('legal.retentionLogMonths', 'Access logs (mesos)')}:{' '}
              {retentionQuery.data.settings.access_log_retention_months}
            </p>
            <p>
              {t('legal.versionActive', 'Versions actives')}:{' '}
              {retentionQuery.data.version_counts.active}
            </p>
            <p>
              {t('legal.versionBlocked', 'Bloquejades')}:{' '}
              {retentionQuery.data.version_counts.access_blocked}
            </p>
            <p>
              {t('legal.versionPurgeEligible', 'Purge-eligible')}:{' '}
              {retentionQuery.data.version_counts.purge_eligible}
            </p>
            {retentionQuery.data.last_run ? (
              <p className="sm:col-span-2 text-xs text-muted-foreground">
                {t('legal.lastRun', 'Darrer run')}: {retentionQuery.data.last_run.job_kind} ·{' '}
                {retentionQuery.data.last_run.status} ·{' '}
                {new Date(retentionQuery.data.last_run.started_at).toLocaleString()}
              </p>
            ) : (
              <p className="sm:col-span-2 text-xs text-muted-foreground">
                {t('legal.noRunYet', 'Encara no hi ha runs de retenció.')}
              </p>
            )}
          </div>
        ) : (
          <p className="text-sm text-destructive">
            {t('legal.retentionLoadError', 'No s\'ha pogut carregar l\'estat de retenció')}
          </p>
        )}
        <p className="text-xs text-muted-foreground">
          {t(
            'legal.otherModules',
            'Altres mòduls DSAR:',
          )}{' '}
          <Link to="/recruitment/rights" className="underline underline-offset-2">
            {t('legal.recruitmentRights', 'Recruitment rights')}
          </Link>
          {' · '}
          {t(
            'legal.employeePersonalData',
            'Portal empleat: /portal/personal-data i /portal/legal/…',
          )}
        </p>
      </section>

      <section className="rounded-2xl border p-5 space-y-3">
        <h3 className="text-sm font-semibold">
          {t('legal.dsarTitle', 'DSAR mínim (customer-portal)')}
        </h3>
        <p className="text-xs text-muted-foreground">
          {t(
            'legal.dsarHint',
            'Revoca shares, grants, invitacions i sessions d’un contacte. No esborra versions publicades (evidència). Opcionalment bloqueja la lectura al portal.',
          )}
        </p>
        <div className="grid gap-3 sm:grid-cols-2">
          <div className="space-y-1 sm:col-span-2">
            <Label htmlFor="dsar-contact">
              {t('legal.dsarContactId', 'ID del contacte (UUID)')}
            </Label>
            <Input
              id="dsar-contact"
              value={dsarContactId}
              onChange={(e) => setDsarContactId(e.target.value)}
              placeholder="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
              disabled={dsarMutate.isPending}
            />
          </div>
          <div className="space-y-1 sm:col-span-2">
            <Label htmlFor="dsar-reason">{t('legal.dsarReason', 'Motiu')}</Label>
            <Input
              id="dsar-reason"
              value={dsarReason}
              onChange={(e) => setDsarReason(e.target.value)}
              placeholder={t('legal.dsarReasonPlaceholder', 'dsar_erasure_request')}
              disabled={dsarMutate.isPending}
            />
          </div>
        </div>
        <label className="flex items-center gap-2 text-sm">
          <input
            type="checkbox"
            checked={dsarBlockVersions}
            onChange={(e) => setDsarBlockVersions(e.target.checked)}
            disabled={dsarMutate.isPending}
          />
          {t(
            'legal.dsarBlockVersions',
            'Bloquejar també la lectura de versions d’aquest compte al portal',
          )}
        </label>
        <Button
          type="button"
          variant="destructive"
          size="sm"
          disabled={dsarMutate.isPending || !dsarContactId.trim()}
          onClick={() => {
            if (
              !window.confirm(
                t(
                  'legal.dsarConfirm',
                  'Revocar tot l’accés customer-portal d’aquest contacte?',
                ),
              )
            ) {
              return
            }
            dsarMutate.mutate()
          }}
        >
          {t('legal.dsarRun', 'Executar revocació DSAR')}
        </Button>
        {dsarQuery.data && dsarQuery.data.length > 0 ? (
          <ul className="space-y-2 border-t pt-3">
            {dsarQuery.data.map((a) => (
              <li key={a.id} className="text-xs text-muted-foreground">
                {new Date(a.created_at).toLocaleString()} ·{' '}
                {a.contact_display_name || a.contact_id} · {a.reason || '—'}
              </li>
            ))}
          </ul>
        ) : null}
      </section>

      {previewHtml != null ? (
        <section className="rounded-2xl border p-5 space-y-2">
          <div className="flex items-center justify-between gap-2">
            <h3 className="text-sm font-semibold">{previewTitle}</h3>
            <Button type="button" variant="ghost" size="sm" onClick={() => setPreviewHtml(null)}>
              {t('legal.closePreview', 'Tancar')}
            </Button>
          </div>
          <div
            className="prose prose-sm max-w-none border rounded-md p-4 bg-background"
            dangerouslySetInnerHTML={{ __html: previewHtml }}
          />
        </section>
      ) : null}
    </div>
  )
}
