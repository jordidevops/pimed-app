import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Plus, Trash2, CheckCircle, Clock, AlertCircle, Shield, Copy, Check, RefreshCw } from 'lucide-react'
import { Button } from '../../../components/ui/button'
import { Input } from '../../../components/ui/input'
import { usePublicDomains } from '../api/usePublicDomains'
import { useAttachPublicDomain, useDeletePublicDomain, useRequestDomainCheck } from '../api/usePublicSiteMutations'
import { useToast } from '../../../hooks/use-toast'
import type { PublicDomainRow } from '../api/usePublicDomains'

interface DomainManagerProps {
  tenantId: string
  siteId: string
  canManage: boolean
}

// DNS status badge
function StatusBadge({ status }: { status: string | null }) {
  const { t } = useTranslation('public-portal')
  const map: Record<string, { label: string; icon: React.ReactNode; cls: string }> = {
    pending: {
      label: t('public_portal.domains.status_pending', 'Pendent verificació DNS'),
      icon: <Clock className="h-3 w-3" />,
      cls: 'bg-amber-50 text-amber-700',
    },
    dns_verified: {
      label: t('public_portal.domains.status_dns_verified', 'DNS verificat'),
      icon: <CheckCircle className="h-3 w-3" />,
      cls: 'bg-blue-50 text-blue-700',
    },
    ssl_active: {
      label: t('public_portal.domains.status_ssl_active', 'SSL actiu'),
      icon: <Shield className="h-3 w-3" />,
      cls: 'bg-green-50 text-green-700',
    },
    failed: {
      label: t('public_portal.domains.status_failed', 'Error'),
      icon: <AlertCircle className="h-3 w-3" />,
      cls: 'bg-red-50 text-red-700',
    },
  }

  const item = map[status ?? ''] ?? {
    label: status ?? '—',
    icon: null,
    cls: 'bg-muted text-muted-foreground',
  }

  return (
    <span className={`inline-flex items-center gap-1.5 text-xs font-medium px-2 py-0.5 rounded-full ${item.cls}`}>
      {item.icon}
      {item.label}
    </span>
  )
}

// Botó de copiar al porta-retalls
function CopyButton({ value, label }: { value: string; label: string }) {
  const [copied, setCopied] = useState(false)

  function handleCopy() {
    navigator.clipboard.writeText(value).then(() => {
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    })
  }

  return (
    <button
      type="button"
      onClick={handleCopy}
      aria-label={label}
      className="inline-flex items-center gap-1 text-muted-foreground hover:text-foreground transition-colors"
    >
      {copied
        ? <Check className="h-3.5 w-3.5 text-green-600" />
        : <Copy className="h-3.5 w-3.5" />}
    </button>
  )
}

// Fila de valor copiable
function DnsField({ label, value }: { label: string; value: string }) {
  const { t } = useTranslation('public-portal')
  return (
    <div>
      <p className="text-muted-foreground">{label}</p>
      <div className="flex items-center gap-1.5">
        <code className="font-mono text-foreground break-all">{value}</code>
        <CopyButton value={value} label={t('public_portal.domains.copy', 'Copiar')} />
      </div>
    </div>
  )
}

// DNS instructions for a domain
function DnsInstructions({
  domain,
  tenantId,
  siteId,
  canManage,
}: {
  domain: PublicDomainRow
  tenantId: string
  siteId: string
  canManage: boolean
}) {
  const { t } = useTranslation('public-portal')
  const { toast } = useToast()
  const checkMut = useRequestDomainCheck(tenantId, siteId)

  const cnameName = domain.domain ?? ''
  const cnameValue = (import.meta.env.VITE_PORTAL_DNS_CNAME_TARGET ?? 'proxy.public.example.com').trim()
  const txtPrefix = (import.meta.env.VITE_PORTAL_DNS_TXT_PREFIX ?? '_portal-verify').trim().replace(/\.$/, '')
  const txtName = `${txtPrefix}.${cnameName}`

  const canCheck = canManage && (domain.status === 'pending' || domain.status === 'failed')

  async function handleCheck() {
    try {
      await checkMut.mutateAsync(domain.id!)
      toast({
        title: t('public_portal.domains.check_requested', 'Verificació en curs. Actualitza en uns moments.'),
      })
    } catch {
      toast({
        title: t('public_portal.domains.check_error', 'Error en sol·licitar la verificació.'),
        variant: 'destructive',
      })
    }
  }

  return (
    <div className="mt-3 p-3 rounded-xl bg-muted/50 text-xs space-y-4">
      <p className="font-semibold text-foreground">
        {t('public_portal.domains.dns_instructions_title', 'Instruccions DNS')}
      </p>

      {/* Registre 1: CNAME */}
      <div className="space-y-1.5">
        <p className="font-medium text-foreground">
          {t('public_portal.domains.dns_step1', '1) Registre CNAME — apunta el domini al portal')}
        </p>
        <div className="grid grid-cols-2 gap-2">
          <DnsField label={t('public_portal.domains.dns_cname_host', 'Name / Nom')} value={cnameName} />
          <DnsField label={t('public_portal.domains.dns_cname_target', 'Target / Valor')} value={cnameValue} />
        </div>
        <p className="text-amber-700 dark:text-amber-400">
          {t('public_portal.domains.dns_cname_proxy_hint', 'Cloudflare: desactiva el proxy (núvol gris, "DNS only").')}
        </p>
      </div>

      {/* Registre 2: TXT de verificació */}
      {domain.verification_token && (
        <div className="space-y-1.5">
          <p className="font-medium text-foreground">
            {t('public_portal.domains.dns_step2', '2) Registre TXT — verifica la propietat del domini')}
          </p>
          <div className="grid grid-cols-2 gap-2">
            <DnsField label={t('public_portal.domains.dns_txt_name', 'Name / Nom')} value={txtName} />
            <DnsField label={t('public_portal.domains.dns_txt_value', 'Content / Valor')} value={domain.verification_token} />
          </div>
        </div>
      )}

      {/* Nota propagació DNS (pending/failed) */}
      {(domain.status === 'pending' || domain.status === 'failed') && (
        <p className="text-muted-foreground italic">
          {t('public_portal.domains.dns_propagation_note', 'La propagació DNS pot trigar entre uns minuts i 48h. La verificació automàtica s\'executa cada 5 minuts.')}
        </p>
      )}

      {/* Nota SSL automàtic (dns_verified) */}
      {domain.status === 'dns_verified' && (
        <p className="text-muted-foreground italic">
          {t('public_portal.domains.ssl_provisioning_note', 'DNS verificat correctament. L\'activació SSL és automàtica i pot trigar fins a 48h.')}
        </p>
      )}

      {/* Darrera verificació + botó verificar ara */}
      <div className="flex items-center justify-between gap-4">
        <div>
          {domain.last_checked_at ? (
            <p className="text-muted-foreground">
              {t('public_portal.domains.last_checked', 'Darrera verificació')}:{' '}
              {new Date(domain.last_checked_at).toLocaleString('ca-ES')}
            </p>
          ) : (
            <p className="text-muted-foreground italic">
              {t('public_portal.domains.never_checked', 'Pendent de primera verificació.')}
            </p>
          )}
          {domain.status === 'failed' && domain.failure_reason && (
            <p className="text-red-600 mt-0.5">{domain.failure_reason}</p>
          )}
        </div>
        {canCheck && (
          <Button
            size="sm"
            variant="outline"
            className="shrink-0"
            onClick={handleCheck}
            disabled={checkMut.isPending}
          >
            <RefreshCw className={`h-3.5 w-3.5 mr-1.5 ${checkMut.isPending ? 'animate-spin' : ''}`} />
            {t('public_portal.domains.verify_now', 'Verificar ara')}
          </Button>
        )}
      </div>
    </div>
  )
}

export function DomainManager({ tenantId, siteId, canManage }: DomainManagerProps) {
  const { t } = useTranslation('public-portal')
  const { toast } = useToast()
  const [addMode, setAddMode] = useState(false)
  const [newDomain, setNewDomain] = useState('')
  const [expandedId, setExpandedId] = useState<string | null>(null)

  const { data: domains = [], isLoading } = usePublicDomains(tenantId, siteId)
  const attachMut = useAttachPublicDomain(tenantId, siteId)
  const deleteMut = useDeletePublicDomain(tenantId, siteId)

  async function handleAdd() {
    const clean = newDomain.toLowerCase().trim()
    if (!clean) return
    try {
      await attachMut.mutateAsync(clean)
      toast({ title: t('public_portal.success.add_domain', 'Domini afegit. Configura el CNAME al teu proveïdor DNS.') })
      setNewDomain('')
      setAddMode(false)
    } catch {
      toast({ title: t('public_portal.errors.add_domain', 'Error afegint el domini.'), variant: 'destructive' })
    }
  }

  async function handleDelete(id: string) {
    try {
      await deleteMut.mutateAsync(id)
      toast({ title: t('public_portal.success.delete_domain', 'Domini eliminat.') })
    } catch {
      toast({ title: t('public_portal.errors.delete_domain', 'Error eliminant el domini.'), variant: 'destructive' })
    }
  }

  return (
    <section className="rounded-2xl border bg-card p-6 space-y-4">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="text-base font-semibold">
            {t('public_portal.domains.section_title', 'Dominis propis')}
          </h2>
          <p className="text-sm text-muted-foreground mt-0.5">
            {t(
              'public_portal.domains.section_description',
              'Vincula el teu domini propi al portal públic. Caldrà configurar un registre CNAME al teu proveïdor DNS.',
            )}
          </p>
        </div>
        {canManage && !addMode && (
          <Button size="sm" variant="outline" onClick={() => setAddMode(true)}>
            <Plus className="h-4 w-4 mr-1.5" />
            {t('public_portal.domains.add_domain', 'Afegir domini')}
          </Button>
        )}
      </div>

      {/* Add domain form */}
      {addMode && canManage && (
        <div className="flex items-center gap-2">
          <Input
            value={newDomain}
            onChange={(e) => setNewDomain(e.target.value)}
            placeholder={t('public_portal.domains.domain_placeholder', 'www.la-meva-empresa.cat')}
            className="flex-1"
          />
          <Button
            size="sm"
            onClick={handleAdd}
            disabled={attachMut.isPending || !newDomain.trim()}
          >
            {t('public_portal.domains.save_domain', 'Afegir domini')}
          </Button>
          <Button
            size="sm"
            variant="ghost"
            onClick={() => { setAddMode(false); setNewDomain('') }}
          >
            {t('public_portal.domains.cancel', 'Cancel·lar')}
          </Button>
        </div>
      )}

      {/* Domain list */}
      {isLoading ? (
        <div className="space-y-2">
          {[1, 2].map((i) => (
            <div key={i} className="h-12 rounded-xl bg-muted animate-pulse" />
          ))}
        </div>
      ) : domains.length === 0 ? (
        <p className="text-sm text-muted-foreground italic">
          {t('public_portal.domains.no_domains', 'Cap domini vinculat.')}
        </p>
      ) : (
        <ul className="divide-y divide-border rounded-xl border overflow-hidden">
          {domains.map((d) => (
            <li key={d.id}>
              <div
                className="flex items-center justify-between gap-3 px-4 py-3 cursor-pointer hover:bg-muted/30 transition"
                onClick={() => setExpandedId(expandedId === d.id ? null : d.id)}
              >
                <div className="min-w-0">
                  <p className="text-sm font-medium truncate">{d.domain}</p>
                </div>
                <div className="flex items-center gap-2 shrink-0">
                  <StatusBadge status={d.status} />
                  {canManage && (
                    <Button
                      size="sm"
                      variant="ghost"
                      className="h-7 w-7 p-0 text-muted-foreground hover:text-destructive"
                      onClick={(e) => { e.stopPropagation(); handleDelete(d.id!) }}
                      disabled={deleteMut.isPending}
                      aria-label={t('public_portal.domains.delete_domain', 'Eliminar')}
                    >
                      <Trash2 className="h-3.5 w-3.5" />
                    </Button>
                  )}
                </div>
              </div>
              {expandedId === d.id && (
                <div className="px-4 pb-3">
                  <DnsInstructions domain={d} tenantId={tenantId} siteId={siteId} canManage={canManage} />
                </div>
              )}
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}
