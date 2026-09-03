import { useState, useMemo } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { useTranslation } from 'react-i18next'
import { Star, MailX, AlertCircle } from 'lucide-react'
import { toast } from '@/hooks/use-toast'
import { useEmailDomains } from '../api/useEmailDomains'
import { useEmailConfig } from '../api/useEmailConfig'
import {
  useAddEmailDomain,
  useUpdateEmailDomain,
  useDeleteEmailDomain,
  useVerifyEmailDomain,
} from '../api/useEmailDomainsMutations'
import {
  addDomainSchema,
  createDomainUpdateSchema,
  type AddDomainFormValues,
  type DomainUpdateFormValues,
} from '../schemas/email.schema'
import { DnsRecordsModal } from './DnsRecordsModal'
import { Spinner } from '../../../components/ui/Spinner'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import {
  Table,
  TableHeader,
  TableBody,
  TableRow,
  TableHead,
  TableCell,
} from '@/components/ui/table'
import type { DomainVerificationStatus, EmailDomain } from '../types'

const STATUS_BADGE_CLASS: Record<DomainVerificationStatus, string> = {
  pending: 'bg-amber-100 text-amber-700 border-0 hover:bg-amber-100',
  verified: 'bg-green-100 text-green-700 border-0 hover:bg-green-100',
  failed: 'bg-red-100 text-red-700 border-0 hover:bg-red-100',
}

const STATUS_LABELS: Record<DomainVerificationStatus, string> = {
  pending: 'Pendent',
  verified: 'Verificat',
  failed: 'Error',
}

interface EmailDomainsTabProps {
  tenantId: string
}

interface DomainEditDialogProps {
  domain: EmailDomain
  tenantId: string
  onClose: () => void
}

/** Extreu nom i email d'un string en format `email@dom` o `Nom <email@dom>` */
function parseFromEmailField(val: string): { email: string; name: string | null } {
  const match = /^(.+?)<([^>]+)>\s*$/.exec(val.trim())
  if (match) {
    return { email: match[2].trim(), name: match[1].trim() || null }
  }
  return { email: val.trim(), name: null }
}

function DomainEditDialog({ domain, tenantId, onClose }: DomainEditDialogProps) {
  const { t } = useTranslation('email')
  const updateDomain = useUpdateEmailDomain(tenantId)
  const domainSchema = useMemo(() => createDomainUpdateSchema(domain.domain), [domain.domain])

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<DomainUpdateFormValues>({
    resolver: zodResolver(domainSchema),
    defaultValues: {
      default_from_email: domain.default_from_email ?? '',
      default_from_name: domain.default_from_name ?? '',
      default_reply_to: domain.default_reply_to ?? '',
    },
  })

  const onSave = async (values: DomainUpdateFormValues) => {
    const rawFrom = values.default_from_email?.trim() || null
    let fromEmail: string | null = rawFrom
    let fromName: string | null = values.default_from_name?.trim() || null

    if (rawFrom) {
      const parsed = parseFromEmailField(rawFrom)
      fromEmail = parsed.email
      // Si no han omplert el camp de nom per separat, usar el nom del format combinat
      if (!fromName && parsed.name) fromName = parsed.name
    }

    await updateDomain.mutateAsync({
      domainId: domain.id,
      updates: {
        default_from_email: fromEmail,
        default_from_name: fromName,
        default_reply_to: values.default_reply_to?.trim() || null,
      },
    })
    onClose()
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>
            {t('email.domains.edit_defaults_title', 'Configuració del domini {{domain}}', {
              domain: domain.domain,
            })}
          </DialogTitle>
        </DialogHeader>
        <form onSubmit={handleSubmit(onSave)} className="space-y-4 pt-2">
          <div className="space-y-1">
            <label htmlFor="default_from_email" className="text-sm font-medium">
              {t('email.domains.default_from_email_label', 'Adreça remitent per defecte')}
            </label>
            <Input
              id="default_from_email"
              type="text"
              placeholder={`noreply@${domain.domain}`}
              {...register('default_from_email')}
            />
            <p className="text-xs text-muted-foreground">
              {t(
                'email.domains.default_from_email_hint',
                "Adreça del domini verificat. Pot ser 'noreply@{{domain}}' o 'Empresa <noreply@{{domain}}>'.",
                { domain: domain.domain },
              )}
            </p>
            {errors.default_from_email && (
              <p className="text-sm text-destructive">{errors.default_from_email.message}</p>
            )}
          </div>

          <div className="space-y-1">
            <label htmlFor="default_from_name" className="text-sm font-medium">
              {t('email.domains.default_from_name_label', 'Nom del remitent per defecte')}
            </label>
            <Input
              id="default_from_name"
              type="text"
              placeholder={domain.domain}
              {...register('default_from_name')}
            />
            <p className="text-xs text-muted-foreground">
              {t(
                'email.domains.default_from_name_hint',
                'Opcional. Sobreescriu la configuració general de l\'account.',
              )}
            </p>
            {errors.default_from_name && (
              <p className="text-sm text-destructive">{errors.default_from_name.message}</p>
            )}
          </div>

          <div className="space-y-1">
            <label htmlFor="default_reply_to" className="text-sm font-medium">
              {t('email.domains.default_reply_to_label', 'Reply-To per defecte')}
            </label>
            <Input
              id="default_reply_to"
              type="email"
              placeholder="suport@empresa.cat"
              {...register('default_reply_to')}
            />
            <p className="text-xs text-muted-foreground">
              {t(
                'email.domains.default_reply_to_hint',
                'Opcional. Adreça per rebre respostes d\'aquest domini.',
              )}
            </p>
            {errors.default_reply_to && (
              <p className="text-sm text-destructive">{errors.default_reply_to.message}</p>
            )}
          </div>

          {updateDomain.isError && (
            <p className="text-sm text-destructive">
              {t('email.domains.save_defaults_error', 'Error en desar la configuració del domini.')}
            </p>
          )}

          <div className="flex justify-end gap-2 pt-2">
            <Button type="button" variant="outline" onClick={onClose}>
              {t('email.config.cancel', 'Cancel·lar')}
            </Button>
            <Button type="submit" disabled={updateDomain.isPending}>
              {updateDomain.isPending
                ? t('email.domains.saving_defaults', 'Desant...')
                : t('email.domains.save_defaults', 'Desar')}
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  )
}

export function EmailDomainsTab({ tenantId }: EmailDomainsTabProps) {
  const { t } = useTranslation('email')
  const supportEmail = import.meta.env.VITE_SUPPORT_EMAIL as string | undefined
  const { data: emailConfig, isLoading: configLoading } = useEmailConfig(tenantId)
  const { data: domains = [], isLoading: domainsLoading, isError } = useEmailDomains(tenantId)
  const addDomain = useAddEmailDomain(tenantId)
  const updateDomain = useUpdateEmailDomain(tenantId)
  const deleteDomain = useDeleteEmailDomain(tenantId)
  const verifyDomain = useVerifyEmailDomain(tenantId)

  const isLoading = configLoading || domainsLoading

  const customDomainsEnabled = emailConfig?.custom_domains_enabled ?? false
  const maxCustomDomains = emailConfig?.max_custom_domains ?? 1
  const atLimit = domains.length >= maxCustomDomains

  const openSupportMail = () => {
    if (!supportEmail) {
      toast({
        title: t('email.domains.support_email_missing', "Falta configurar l'email de suport."),
        variant: 'destructive',
      })
      return
    }

    window.open(`mailto:${supportEmail}`, '_blank')
  }

  const [dnsModalDomain, setDnsModalDomain] = useState<EmailDomain | null>(null)
  const [editingDomain, setEditingDomain] = useState<EmailDomain | null>(null)
  const [verifyingId, setVerifyingId] = useState<string | null>(null)

  const {
    register,
    handleSubmit,
    reset,
    formState: { errors },
  } = useForm<AddDomainFormValues>({
    resolver: zodResolver(addDomainSchema),
  })

  const onAdd = async (values: AddDomainFormValues) => {
    await addDomain.mutateAsync(values.domain)
    reset()
  }

  const handleSetPrimary = (domainId: string) => {
    updateDomain.mutate({ domainId, updates: { is_primary: true } })
  }

  const handleVerify = async (domainId: string) => {
    setVerifyingId(domainId)
    try {
      const result = await verifyDomain.mutateAsync(domainId)
      if (result.status === 'verified') {
        toast({
          title: t('email.domains.verify_success', 'Domini verificat correctament.'),
        })
      } else if (result.status === 'failed') {
        toast({
          title: t(
            'email.domains.verify_failed',
            'La verificació ha fallat. Comprova que els registres DNS estan correctes.',
          ),
          variant: 'destructive',
        })
      } else {
        toast({
          title: t(
            'email.domains.verify_pending',
            'Els registres DNS encara no s\'han propagat. Torna-ho a intentar en uns minuts.',
          ),
        })
      }
    } catch (err) {
      toast({
        title: err instanceof Error ? err.message : t('email.domains.verify_error', 'Error en verificar el domini.'),
        variant: 'destructive',
      })
    } finally {
      setVerifyingId(null)
    }
  }

  if (isLoading) {
    return (
      <div className="flex justify-center py-12">
        <Spinner />
      </div>
    )
  }

  if (isError) {
    return (
      <div className="rounded-lg border border-destructive/30 bg-destructive/10 p-5 text-sm text-destructive">
        {t('email.domains.load_error', 'Error en carregar els dominis.')}
      </div>
    )
  }

  // ── Feature desactivada: empty state amb CTA a suport ───────────────────
  if (!customDomainsEnabled) {
    return (
      <div className="rounded-lg border border-dashed p-12 flex flex-col items-center gap-4 text-center">
        <MailX className="h-10 w-10 text-muted-foreground/50" />
        <div className="space-y-1">
          <p className="text-sm font-medium">
            {t('email.domains.feature_disabled_title', 'Dominis personalitzats no disponibles')}
          </p>
          <p className="text-sm text-muted-foreground">
            {t(
              'email.domains.feature_disabled_description',
              "Aquesta funcionalitat no està inclosa en el teu pla actual. Contacta amb el nostre equip per activar-la.",
            )}
          </p>
        </div>
        <Button
          variant="outline"
          size="sm"
          onClick={openSupportMail}
        >
          {t('email.domains.feature_disabled_cta', 'Contactar amb suport')}
        </Button>
      </div>
    )
  }

  return (
    <div className="space-y-6">
      {/* Info sobre el model de dominis */}
      <div className="rounded-lg border bg-muted/40 p-4 text-sm text-muted-foreground">
        {t(
          'email.domains.info',
          "Cada domini necessita verificació DNS independent. Un cop verificat, pots usar-lo com a adreça remitent en els correus. Pots tenir múltiples dominis verificats simultàniament.",
        )}
      </div>

      {/* Formulari d'addició o missatge de límit assolit */}
      <div className="rounded-lg border bg-card p-6">
        <div className="flex items-center justify-between mb-4">
          <h2 className="text-base font-semibold">
            {t('email.domains.add_domain_title', 'Afegir nou domini')}
          </h2>
          <span className="text-xs text-muted-foreground">
            {t('email.domains.quota_indicator', '{{used}}/{{max}} dominis', {
              used: domains.length,
              max: maxCustomDomains,
            })}
          </span>
        </div>

        {atLimit ? (
          <div className="flex items-start gap-3 rounded-lg border border-amber-200 bg-amber-50 p-4">
            <AlertCircle className="h-4 w-4 text-amber-600 mt-0.5 shrink-0" />
            <div className="space-y-2">
              <p className="text-sm text-amber-800">
                {t(
                  'email.domains.quota_reached',
                  "Has arribat al límit de {{max}} domini(s) inclòs(os) en el teu pla. Vols afegir-ne un altre?",
                  { max: maxCustomDomains },
                )}
              </p>
              <Button
                variant="outline"
                size="sm"
                onClick={openSupportMail}
              >
                {t('email.domains.quota_reached_cta', 'Contactar per ampliar el límit')}
              </Button>
            </div>
          </div>
        ) : (
          <form onSubmit={handleSubmit(onAdd)} className="flex gap-3 items-start">
            <div className="flex-1">
              <Input
                {...register('domain')}
                type="text"
                placeholder="empresa.cat"
              />
              {errors.domain && (
                <p className="mt-1 text-sm text-destructive">{errors.domain.message}</p>
              )}
              {addDomain.isError && (
                <p className="mt-1 text-sm text-destructive">
                  {t(
                    'email.domains.add_error',
                    "Error en afegir el domini: {{error}}",
                    {
                      error:
                        addDomain.error instanceof Error
                          ? addDomain.error.message
                          : t('email.domains.add_error_unknown', 'Error desconegut.'),
                    },
                  )}
                </p>
              )}
            </div>
            <Button type="submit" disabled={addDomain.isPending} className="shrink-0">
              {addDomain.isPending
                ? t('email.domains.adding', 'Afegint...')
                : t('email.domains.add_button', 'Afegir')}
            </Button>
          </form>
        )}
      </div>

      {/* Taula de dominis */}
      {domains.length === 0 ? (
        <div className="rounded-lg border border-dashed p-10 text-center">
          <p className="text-sm text-muted-foreground">
            {t('email.domains.empty', "Encara no has afegit cap domini personalitzat.")}
          </p>
        </div>
      ) : (
        <div className="rounded-lg border overflow-hidden">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>{t('email.domains.col_domain', 'Domini')}</TableHead>
                <TableHead>{t('email.domains.col_status', 'Estat')}</TableHead>
                <TableHead>{t('email.domains.col_verified_at', 'Verificat el')}</TableHead>
                <TableHead className="text-right">
                  {t('email.domains.col_actions', 'Accions')}
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {domains.map((d) => (
                <TableRow key={d.id}>
                  <TableCell className="font-medium">
                    <span className="flex items-center gap-2">
                      {d.is_primary && (
                        <Star
                          className="h-3.5 w-3.5 fill-amber-400 text-amber-400 shrink-0"
                          aria-label={t('email.domains.primary_badge', 'Principal')}
                        />
                      )}
                      {d.domain}
                    </span>
                  </TableCell>
                  <TableCell>
                    <Badge
                      className={STATUS_BADGE_CLASS[d.verification_status as DomainVerificationStatus]}
                    >
                      {t(
                        `email.domains.status_${d.verification_status}`,
                        STATUS_LABELS[d.verification_status as DomainVerificationStatus],
                      )}
                    </Badge>
                  </TableCell>
                  <TableCell className="text-muted-foreground">
                    {d.verified_at
                      ? new Date(d.verified_at).toLocaleDateString('ca-ES')
                      : '—'}
                  </TableCell>
                  <TableCell className="text-right">
                    <div className="flex items-center justify-end gap-2">
                      {d.verification_status === 'verified' && !d.is_primary && (
                        <Button
                          type="button"
                          variant="ghost"
                          size="sm"
                          disabled={updateDomain.isPending}
                          onClick={() => handleSetPrimary(d.id)}
                          title={t('email.domains.set_primary_hint', 'El domini principal s\'usa per enviar correus quan no s\'especifica cap domini.')}
                        >
                          {t('email.domains.set_primary', 'Definir com a principal')}
                        </Button>
                      )}
                      {d.verification_status === 'verified' && (
                        <Button
                          type="button"
                          variant="ghost"
                          size="sm"
                          onClick={() => setEditingDomain(d)}
                        >
                          {t('email.domains.edit_defaults', 'Editar configuració')}
                        </Button>
                      )}
                      {(d.verification_status === 'pending' || d.verification_status === 'failed') &&
                        d.provider_domain_id && (
                          <Button
                            type="button"
                            variant="ghost"
                            size="sm"
                            disabled={verifyingId === d.id}
                            onClick={() => handleVerify(d.id)}
                          >
                            {verifyingId === d.id
                              ? t('email.domains.verifying', 'Comprovant...')
                              : t('email.domains.verify_btn', 'Comprovar verificació')}
                          </Button>
                        )}
                      {d.verification_status === 'pending' && d.dns_records && (
                        <Button
                          type="button"
                          variant="ghost"
                          size="sm"
                          onClick={() => setDnsModalDomain(d)}
                        >
                          {t('email.domains.view_dns', 'Veure DNS')}
                        </Button>
                      )}
                      <Button
                        type="button"
                        variant="ghost"
                        size="sm"
                        disabled={deleteDomain.isPending}
                        onClick={() => deleteDomain.mutate(d.id)}
                        className="text-destructive hover:text-destructive"
                      >
                        {t('email.domains.delete', 'Eliminar')}
                      </Button>
                    </div>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}

      {/* Dialog d'edició del domini */}
      {editingDomain && (
        <DomainEditDialog
          domain={editingDomain}
          tenantId={tenantId}
          onClose={() => setEditingDomain(null)}
        />
      )}

      {/* Modal registres DNS */}
      {dnsModalDomain && (
        <DnsRecordsModal
          domain={dnsModalDomain}
          onClose={() => setDnsModalDomain(null)}
        />
      )}
    </div>
  )
}
