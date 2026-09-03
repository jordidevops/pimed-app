import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import {
  AlertTriangle,
  BuildingIcon,
  Check,
  Copy,
  Loader2,
  LockIcon,
  Mail,
  ShieldCheck,
  Trash2,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Checkbox } from '@/components/ui/checkbox'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import {
  buildInspectionUrl,
  createInspectionAccessLink,
  inspectionRangeDays,
  INSPECTION_DEFAULT_TTL_DAYS,
  INSPECTION_MAX_RANGE_DAYS,
  INSPECTION_MAX_TTL_DAYS,
  listActiveEmployees,
  listInspectionAccessLinks,
  revokeInspectionAccessLink,
  sendInspectionAccessEmail,
  summarizeUserAgent,
  type CreateInspectionLinkResult,
  type InspectionAccessLink,
} from '../../api/inspectionAccessService'

interface AttendanceInspectionAccessSectionProps {
  tenantId: string | null
  canManage: boolean
}

function FieldRow({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <div className="grid grid-cols-1 gap-1 sm:grid-cols-[1fr_260px] sm:items-start sm:gap-4">
      <div>
        <p className="text-sm text-foreground">{label}</p>
        {hint ? <p className="text-xs text-muted-foreground mt-0.5">{hint}</p> : null}
      </div>
      <div className="sm:pt-0.5">{children}</div>
    </div>
  )
}

function formatDate(value: string | null | undefined, locale: string): string {
  if (!value) return '—'
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) return '—'
  return parsed.toLocaleDateString(
    locale === 'en' ? 'en-GB' : locale === 'es' ? 'es-ES' : 'ca-ES',
  )
}

function formatDateTime(value: string | null | undefined, locale: string): string {
  if (!value) return '—'
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) return '—'
  return parsed.toLocaleString(
    locale === 'en' ? 'en-GB' : locale === 'es' ? 'es-ES' : 'ca-ES',
  )
}

function statusBadgeClass(status: InspectionAccessLink['status'] | string): string {
  if (status === 'active') return 'bg-emerald-100 text-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-300'
  if (status === 'revoked') return 'bg-amber-100 text-amber-900 dark:bg-amber-950/40 dark:text-amber-200'
  return 'bg-muted text-muted-foreground'
}

export function AttendanceInspectionAccessSection({
  tenantId,
  canManage,
}: AttendanceInspectionAccessSectionProps) {
  const { t, i18n } = useTranslation('settings')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  const [employeeId, setEmployeeId] = useState('')
  const [periodFrom, setPeriodFrom] = useState('')
  const [periodTo, setPeriodTo] = useState('')
  const [ttlDays, setTtlDays] = useState(INSPECTION_DEFAULT_TTL_DAYS)
  const [label, setLabel] = useState('')
  const [includeConsolidated, setIncludeConsolidated] = useState(true)
  const [creating, setCreating] = useState(false)
  const [revokingId, setRevokingId] = useState<string | null>(null)

  const [revealOpen, setRevealOpen] = useState(false)
  const [created, setCreated] = useState<CreateInspectionLinkResult | null>(null)
  const [copied, setCopied] = useState(false)
  const [recipients, setRecipients] = useState('')
  const [sendingEmail, setSendingEmail] = useState(false)
  const [emailSent, setEmailSent] = useState(false)

  const employeesQuery = useQuery({
    queryKey: ['inspection_active_employees'],
    queryFn: listActiveEmployees,
    enabled: canManage,
  })

  const linksQuery = useQuery({
    queryKey: ['inspection_access_links'],
    queryFn: () => listInspectionAccessLinks(false),
    enabled: canManage,
  })

  const rangeDays = useMemo(() => {
    if (!periodFrom || !periodTo) return NaN
    return inspectionRangeDays(periodFrom, periodTo)
  }, [periodFrom, periodTo])

  const rangeInvalid = !Number.isNaN(rangeDays) && (rangeDays < 0 || rangeDays > INSPECTION_MAX_RANGE_DAYS)
  const ttlInvalid = ttlDays < 1 || ttlDays > INSPECTION_MAX_TTL_DAYS
  const canGenerate =
    canManage && !!employeeId && !!periodFrom && !!periodTo && !rangeInvalid && !ttlInvalid && !creating

  const revealUrl = created ? buildInspectionUrl(created.id, created.urlSecret) : ''

  async function handleGenerate() {
    if (!canGenerate) return
    setCreating(true)
    try {
      const result = await createInspectionAccessLink({
        employeeId,
        periodFrom,
        periodTo,
        ttlDays,
        label: label.trim() || null,
        includeConsolidated,
      })
      setCreated(result)
      setCopied(false)
      setRecipients('')
      setEmailSent(false)
      setRevealOpen(true)
      setEmployeeId('')
      setPeriodFrom('')
      setPeriodTo('')
      setLabel('')
      setIncludeConsolidated(true)
      setTtlDays(INSPECTION_DEFAULT_TTL_DAYS)
      void linksQuery.refetch()
    } catch (err) {
      toast({
        variant: 'destructive',
        description:
          err instanceof Error && err.message
            ? err.message
            : t('config.inspection_access.create_error', 'No s\'ha pogut generar l\'enllaç d\'inspecció'),
      })
    } finally {
      setCreating(false)
    }
  }

  async function handleCopy() {
    if (!revealUrl) return
    await navigator.clipboard.writeText(revealUrl)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  async function handleRevoke(linkId: string) {
    setRevokingId(linkId)
    try {
      await revokeInspectionAccessLink(linkId)
      await queryClient.invalidateQueries({ queryKey: ['inspection_access_links'] })
      toast({ description: t('config.inspection_access.revoked', 'Enllaç revocat') })
    } catch {
      toast({
        variant: 'destructive',
        description: t('config.inspection_access.revoke_error', 'No s\'ha pogut revocar l\'enllaç'),
      })
    } finally {
      setRevokingId(null)
    }
  }

  async function handleSendEmail() {
    if (!created || !tenantId) return
    const list = recipients
      .split(',')
      .map((r) => r.trim().toLowerCase())
      .filter((r) => r.includes('@'))
    if (list.length === 0) {
      toast({
        variant: 'destructive',
        description: t('config.inspection_access.email_no_recipients', 'Introdueix almenys una adreça de correu vàlida'),
      })
      return
    }
    setSendingEmail(true)
    try {
      await sendInspectionAccessEmail({
        tenantId,
        linkId: created.id,
        secret: created.urlSecret,
        recipients: list,
        locale: i18n.language,
      })
      setEmailSent(true)
      toast({ description: t('config.inspection_access.email_sent', 'Correu enviat correctament') })
    } catch (err) {
      toast({
        variant: 'destructive',
        description:
          err instanceof Error && err.message
            ? err.message
            : t('config.inspection_access.email_error', 'No s\'ha pogut enviar el correu'),
      })
    } finally {
      setSendingEmail(false)
    }
  }

  const links = linksQuery.data ?? []

  return (
    <section className="rounded-2xl border bg-card p-6 space-y-5">
      <div className="flex items-start justify-between gap-4">
        <div className="space-y-0.5">
          <div className="flex items-center gap-2">
            <h2 className="text-base font-semibold text-foreground">
              {t('config.inspection_access.title', 'Accés per a la Inspecció de Treball')}
            </h2>
            <span className="inline-flex items-center gap-1 rounded-full bg-muted text-muted-foreground text-xs font-medium px-2 py-0.5">
              <BuildingIcon className="h-3 w-3" />
              Tenant
            </span>
          </div>
          <p className="text-sm text-muted-foreground">
            {t(
              'config.inspection_access.description',
              'Genera un enllaç temporal perquè la Inspecció consulti els fitxatges d\'un empleat en un període concret, sense necessitat de compte.',
            )}
          </p>
        </div>
        {!canManage && <LockIcon className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" />}
      </div>

      {!canManage && (
        <p className="text-sm text-muted-foreground italic">
          {t('config.read_only', 'Només els gestors i propietaris poden modificar la configuració.')}
        </p>
      )}

      {canManage && (
        <>
          <div className="space-y-4">
            <FieldRow label={t('config.inspection_access.employee', 'Empleat')}>
              <select
                value={employeeId}
                onChange={(e) => setEmployeeId(e.target.value)}
                className="w-full h-9 rounded-md border border-input bg-background px-3 text-sm"
              >
                <option value="">
                  {employeesQuery.isLoading
                    ? t('config.inspection_access.loading_employees', 'Carregant…')
                    : t('config.inspection_access.select_employee', 'Selecciona un empleat')}
                </option>
                {(employeesQuery.data ?? []).map((emp) => (
                  <option key={emp.id} value={emp.id}>
                    {emp.full_name}
                  </option>
                ))}
              </select>
            </FieldRow>

            <FieldRow
              label={t('config.inspection_access.period', 'Període')}
              hint={t('config.inspection_access.period_hint', 'Màxim 400 dies (un any complet).')}
            >
              <div className="flex flex-col gap-2">
                <Input
                  type="date"
                  value={periodFrom}
                  onChange={(e) => setPeriodFrom(e.target.value)}
                  className="h-9"
                />
                <Input
                  type="date"
                  value={periodTo}
                  onChange={(e) => setPeriodTo(e.target.value)}
                  className="h-9"
                />
                {rangeInvalid ? (
                  <p className="text-xs text-destructive">
                    {rangeDays < 0
                      ? t('config.inspection_access.period_order_error', 'La data final ha de ser posterior a la inicial.')
                      : t('config.inspection_access.period_range_error', 'El període no pot superar els 400 dies.')}
                  </p>
                ) : null}
              </div>
            </FieldRow>

            <FieldRow
              label={t('config.inspection_access.ttl', 'Caducitat (dies)')}
              hint={t('config.inspection_access.ttl_hint', 'Per defecte 7 dies. Màxim 30.')}
            >
              <Input
                type="number"
                min={1}
                max={INSPECTION_MAX_TTL_DAYS}
                value={ttlDays}
                onChange={(e) => setTtlDays(Number(e.target.value) || INSPECTION_DEFAULT_TTL_DAYS)}
                className="h-9"
              />
            </FieldRow>

            <FieldRow label={t('config.inspection_access.label', 'Etiqueta (opcional)')}>
              <Input
                value={label}
                onChange={(e) => setLabel(e.target.value)}
                placeholder={t('config.inspection_access.label_placeholder', 'Ex.: Inspecció març 2026')}
                className="h-9"
              />
            </FieldRow>

            <FieldRow
              label={t('config.inspection_access.include_consolidated', 'Mostrar registre consolidat')}
              hint={t(
                'config.inspection_access.include_consolidated_hint',
                'Si està actiu, l’enllaç també inclou el resum diari consolidat a més dels fitxatges reals.',
              )}
            >
              <div className="flex items-center gap-2 pt-1">
                <Checkbox
                  id="inspection-include-consolidated"
                  checked={includeConsolidated}
                  onCheckedChange={(v) => setIncludeConsolidated(v === true)}
                />
                <label htmlFor="inspection-include-consolidated" className="text-sm cursor-pointer">
                  {t('config.inspection_access.include_consolidated_check', 'Incloure pestanya de registre consolidat')}
                </label>
              </div>
            </FieldRow>

            <div className="flex justify-end">
              <Button type="button" size="sm" className="gap-1.5" disabled={!canGenerate} onClick={() => void handleGenerate()}>
                {creating ? <Loader2 className="h-4 w-4 animate-spin" /> : <ShieldCheck className="h-4 w-4" />}
                {t('config.inspection_access.generate', 'Generar enllaç')}
              </Button>
            </div>
          </div>

          <div className="space-y-2 pt-2 border-t">
            <p className="text-sm font-medium text-foreground">
              {t('config.inspection_access.links_title', 'Enllaços')}
            </p>
            {linksQuery.isLoading ? (
              <p className="text-xs text-muted-foreground">{t('config.inspection_access.loading', 'Carregant…')}</p>
            ) : links.length === 0 ? (
              <p className="text-xs text-muted-foreground">
                {t('config.inspection_access.no_links', 'Encara no hi ha cap enllaç d\'inspecció.')}
              </p>
            ) : (
              <ul className="divide-y rounded-md border">
                {links.map((link: InspectionAccessLink) => {
                  const status = link.status ?? (link.is_active ? 'active' : link.revoked_at ? 'revoked' : 'expired')
                  const statusLabel =
                    status === 'active'
                      ? t('config.inspection_access.status_active', 'Actiu')
                      : status === 'revoked'
                        ? t('config.inspection_access.revoked_badge', 'Revocat')
                        : t('config.inspection_access.expired_badge', 'Caducat')
                  return (
                    <li key={link.id} className="flex flex-col gap-2 px-3 py-3 sm:flex-row sm:items-start sm:justify-between">
                      <div className="min-w-0 space-y-1.5">
                        <div className="flex flex-wrap items-center gap-2">
                          <p className="text-sm text-foreground truncate">
                            {link.employee_name}
                            {link.label ? <span className="text-muted-foreground"> · {link.label}</span> : null}
                          </p>
                          <span
                            className={`inline-flex rounded-full px-2 py-0.5 text-[11px] font-medium ${statusBadgeClass(status)}`}
                          >
                            {statusLabel}
                          </span>
                          {link.include_consolidated ? (
                            <span className="text-[11px] text-muted-foreground">
                              {t('config.inspection_access.with_consolidated', '+ consolidat')}
                            </span>
                          ) : (
                            <span className="text-[11px] text-muted-foreground">
                              {t('config.inspection_access.punches_only', 'Només fitxatges')}
                            </span>
                          )}
                        </div>
                        <p className="text-xs text-muted-foreground">
                          {formatDate(link.period_from, i18n.language)} – {formatDate(link.period_to, i18n.language)}
                          {' · '}
                          {t('config.inspection_access.expires', 'Caduca {{date}}', {
                            date: formatDate(link.expires_at, i18n.language),
                          })}
                          {' · '}
                          {t('config.inspection_access.accesses', '{{count}} accessos', { count: link.access_count })}
                        </p>
                        <div className="grid gap-1 text-xs text-muted-foreground sm:grid-cols-2">
                          <p>
                            <span className="font-medium text-foreground/80">
                              {t('config.inspection_access.first_access', 'Primer accés')}:
                            </span>{' '}
                            {link.first_accessed_at
                              ? `${formatDateTime(link.first_accessed_at, i18n.language)} · ${link.first_access_ip ?? '—'} · ${summarizeUserAgent(link.first_access_user_agent)}`
                              : t('config.inspection_access.never_accessed', 'Encara no s’ha obert')}
                          </p>
                          <p>
                            <span className="font-medium text-foreground/80">
                              {t('config.inspection_access.last_access', 'Últim accés')}:
                            </span>{' '}
                            {link.last_accessed_at
                              ? `${formatDateTime(link.last_accessed_at, i18n.language)} · ${link.last_access_ip ?? '—'} · ${summarizeUserAgent(link.last_access_user_agent)}`
                              : '—'}
                          </p>
                        </div>
                      </div>
                      {status === 'active' ? (
                        <Button
                          type="button"
                          variant="outline"
                          size="sm"
                          className="gap-1.5 shrink-0 self-start"
                          disabled={revokingId === link.id}
                          onClick={() => void handleRevoke(link.id)}
                        >
                          {revokingId === link.id ? (
                            <Loader2 className="h-3.5 w-3.5 animate-spin" />
                          ) : (
                            <Trash2 className="h-3.5 w-3.5" />
                          )}
                          {t('config.inspection_access.revoke', 'Revocar')}
                        </Button>
                      ) : null}
                    </li>
                  )
                })}
              </ul>
            )}
          </div>
        </>
      )}

      <Dialog open={revealOpen} onOpenChange={setRevealOpen}>
        <DialogContent className="sm:max-w-lg">
          <DialogHeader>
            <DialogTitle>{t('config.inspection_access.reveal_title', 'Enllaç d\'inspecció generat')}</DialogTitle>
            <DialogDescription>
              {t(
                'config.inspection_access.reveal_description',
                'Copia l\'enllaç ara. Per seguretat, el secret no es tornarà a mostrar.',
              )}
            </DialogDescription>
          </DialogHeader>

          <div className="rounded-md border border-amber-500/40 bg-amber-50 dark:bg-amber-950/20 px-3 py-2.5 flex gap-2">
            <AlertTriangle className="h-4 w-4 shrink-0 text-amber-600 mt-0.5" />
            <p className="text-xs text-amber-800 dark:text-amber-200">
              {t(
                'config.inspection_access.confidentiality',
                'Confidencial: qualsevol persona amb aquest enllaç podrà veure les dades fins a la caducitat o fins que el revoquis.',
              )}
            </p>
          </div>

          {created ? (
            <div className="space-y-3 py-1">
              <div className="text-sm text-muted-foreground space-y-0.5">
                <p>
                  {t('config.inspection_access.reveal_employee', 'Empleat')}: <span className="text-foreground">{created.employeeName}</span>
                </p>
                <p>
                  {t('config.inspection_access.reveal_period', 'Període')}:{' '}
                  <span className="text-foreground">
                    {formatDate(created.periodFrom, i18n.language)} – {formatDate(created.periodTo, i18n.language)}
                  </span>
                </p>
                <p>
                  {t('config.inspection_access.reveal_expires', 'Caduca')}:{' '}
                  <span className="text-foreground">{formatDate(created.expiresAt, i18n.language)}</span>
                </p>
              </div>

              <div className="space-y-1">
                <label className="text-sm font-medium">{t('config.inspection_access.url_field', 'Enllaç')}</label>
                <div className="flex gap-2">
                  <Input readOnly value={revealUrl} className="font-mono text-xs" />
                  <Button
                    type="button"
                    variant="outline"
                    size="icon"
                    onClick={() => void handleCopy()}
                    aria-label={t('config.inspection_access.copy', 'Copiar')}
                  >
                    {copied ? <Check className="h-4 w-4 text-green-600" /> : <Copy className="h-4 w-4" />}
                  </Button>
                </div>
              </div>

              <div className="space-y-1 pt-2 border-t">
                <label className="text-sm font-medium">
                  {t('config.inspection_access.email_recipients', 'Enviar per correu (opcional)')}
                </label>
                <p className="text-xs text-muted-foreground">
                  {t('config.inspection_access.email_recipients_hint', 'Adreces separades per comes.')}
                </p>
                <div className="flex gap-2">
                  <Input
                    value={recipients}
                    onChange={(e) => setRecipients(e.target.value)}
                    placeholder="inspeccio@exemple.cat"
                    className="text-sm"
                  />
                  <Button
                    type="button"
                    variant="outline"
                    className="gap-1.5 shrink-0"
                    disabled={sendingEmail || !recipients.trim()}
                    onClick={() => void handleSendEmail()}
                  >
                    {sendingEmail ? <Loader2 className="h-4 w-4 animate-spin" /> : <Mail className="h-4 w-4" />}
                    {t('config.inspection_access.send', 'Enviar')}
                  </Button>
                </div>
                {emailSent ? (
                  <p className="text-xs text-emerald-700 dark:text-emerald-400">
                    {t('config.inspection_access.email_sent', 'Correu enviat correctament')}
                  </p>
                ) : null}
              </div>
            </div>
          ) : null}

          <DialogFooter>
            <Button type="button" onClick={() => setRevealOpen(false)}>
              {t('config.inspection_access.done', 'Fet')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </section>
  )
}
