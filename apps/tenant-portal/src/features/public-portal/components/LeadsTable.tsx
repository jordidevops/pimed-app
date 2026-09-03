import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { UserPlus, Mail, Phone, MessageSquare, Globe } from 'lucide-react'
import { Button } from '../../../components/ui/button'
import { usePublicLeads } from '../api/usePublicLeads'
import { usePromoteLeadToContact } from '../api/usePublicSiteMutations'
import { useToast } from '../../../hooks/use-toast'
import type { PublicSiteRow } from '../api/usePublicSite'

interface LeadsTableProps {
  tenantId: string
  sites: PublicSiteRow[]
  canManage: boolean
}

const STATUS_STYLES: Record<string, string> = {
  new: 'bg-blue-50 text-blue-700',
  contacted: 'bg-amber-50 text-amber-700',
  converted: 'bg-green-50 text-green-700',
  discarded: 'bg-muted text-muted-foreground',
}

export function LeadsTable({ tenantId, sites, canManage }: LeadsTableProps) {
  const { t } = useTranslation('public-portal')
  const { toast } = useToast()
  const [siteFilter, setSiteFilter] = useState<string>('')

  const { data: leads = [], isLoading, isError } = usePublicLeads(tenantId, {
    siteId: siteFilter || undefined,
  })
  const promoteMut = usePromoteLeadToContact(tenantId)

  async function handlePromote(leadId: string) {
    try {
      await promoteMut.mutateAsync(leadId)
      toast({ title: t('public_portal.success.promote_lead', 'Lead convertit a contacte.') })
    } catch {
      toast({ title: t('public_portal.errors.promote_lead', 'Error convertint el lead a contacte.'), variant: 'destructive' })
    }
  }

  const statusLabel: Record<string, string> = {
    new: t('public_portal.leads.status_new', 'Nou'),
    contacted: t('public_portal.leads.status_contacted', 'Contactat'),
    converted: t('public_portal.leads.status_converted', 'Convertit'),
    discarded: t('public_portal.leads.status_discarded', 'Descartat'),
  }

  return (
    <section className="rounded-2xl border bg-card p-6 space-y-4">
      <div className="flex items-start justify-between gap-4 flex-wrap">
        <div>
          <h2 className="text-base font-semibold">
            {t('public_portal.leads.section_title', 'Leads')}
          </h2>
          <p className="text-sm text-muted-foreground mt-0.5">
            {t(
              'public_portal.leads.section_description',
              'Llistat de contactes captats a través dels formularis del portal.',
            )}
          </p>
        </div>
        {/* Site filter */}
        {sites.length > 1 && (
          <select
            value={siteFilter}
            onChange={(e) => setSiteFilter(e.target.value)}
            className="text-sm rounded-md border border-input bg-background px-3 py-1.5"
            aria-label={t('public_portal.leads.site_filter_label', 'Portal')}
          >
            <option value="">{t('public_portal.leads.all_sites', 'Tots els portals')}</option>
            {sites.map((s) => (
              <option key={s.id} value={s.id ?? ''}>
                {s.name}
              </option>
            ))}
          </select>
        )}
      </div>

      {isLoading ? (
        <div className="space-y-2">
          {[1, 2, 3, 4].map((i) => <div key={i} className="h-12 rounded-xl bg-muted animate-pulse" />)}
        </div>
      ) : isError ? (
        <p className="text-sm text-destructive">{t('public_portal.leads.error', 'Error carregant els leads.')}</p>
      ) : leads.length === 0 ? (
        <p className="text-sm text-muted-foreground italic">
          {t('public_portal.leads.no_leads', 'Cap lead rebut encara.')}
        </p>
      ) : (
        <div className="overflow-x-auto rounded-xl border">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b bg-muted/40">
                <th className="text-left px-4 py-2.5 font-medium text-muted-foreground">
                  {t('public_portal.leads.col_name', 'Nom')}
                </th>
                <th className="text-left px-4 py-2.5 font-medium text-muted-foreground">
                  {t('public_portal.leads.col_email', 'Email')}
                </th>
                <th className="text-left px-4 py-2.5 font-medium text-muted-foreground">
                  {t('public_portal.leads.col_page', 'Pàgina origen')}
                </th>
                <th className="text-left px-4 py-2.5 font-medium text-muted-foreground">
                  {t('public_portal.leads.col_status', 'Estat')}
                </th>
                <th className="text-left px-4 py-2.5 font-medium text-muted-foreground">
                  {t('public_portal.leads.col_date', 'Data')}
                </th>
                {canManage && <th className="px-4 py-2.5" />}
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {leads.map((lead) => (
                <tr key={lead.id} className="hover:bg-muted/20 transition">
                  <td className="px-4 py-3">
                    <div className="flex items-center gap-2">
                      <p className="font-medium truncate max-w-[140px]">{lead.name ?? '—'}</p>
                    </div>
                    {lead.phone && (
                      <div className="flex items-center gap-1 text-xs text-muted-foreground mt-0.5">
                        <Phone className="h-3 w-3" />
                        {lead.phone}
                      </div>
                    )}
                  </td>
                  <td className="px-4 py-3">
                    {lead.email ? (
                      <div className="flex items-center gap-1.5 text-xs text-muted-foreground">
                        <Mail className="h-3 w-3 shrink-0" />
                        <span className="truncate max-w-[160px]">{lead.email}</span>
                      </div>
                    ) : (
                      <span className="text-muted-foreground">—</span>
                    )}
                    {lead.message && (
                      <div className="flex items-start gap-1 text-xs text-muted-foreground mt-0.5">
                        <MessageSquare className="h-3 w-3 mt-0.5 shrink-0" />
                        <span className="truncate max-w-[200px]">{lead.message}</span>
                      </div>
                    )}
                  </td>
                  <td className="px-4 py-3 text-xs text-muted-foreground">
                    {lead.source_page_slug ? (
                      <div className="flex items-center gap-1">
                        <Globe className="h-3 w-3" />
                        /{lead.source_page_slug}
                      </div>
                    ) : (
                      <span className="italic">{(lead as any).public_site_slug ?? '—'}</span>
                    )}
                  </td>
                  <td className="px-4 py-3">
                    <span
                      className={`px-2 py-0.5 text-xs font-medium rounded-full ${STATUS_STYLES[lead.status ?? 'new'] ?? STATUS_STYLES.new}`}
                    >
                      {statusLabel[lead.status ?? 'new'] ?? lead.status}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-xs text-muted-foreground whitespace-nowrap">
                    {lead.created_at
                      ? new Date(lead.created_at).toLocaleDateString('ca-ES', { day: '2-digit', month: 'short', year: 'numeric' })
                      : '—'}
                  </td>
                  {canManage && (
                    <td className="px-4 py-3 text-right">
                      {lead.status !== 'converted' && !lead.contact_id && (
                        <Button
                          size="sm"
                          variant="ghost"
                          className="h-7 text-xs"
                          onClick={() => handlePromote(lead.id!)}
                          disabled={promoteMut.isPending}
                          title={t('public_portal.leads.promote_to_contact', 'Convertir a contacte')}
                        >
                          <UserPlus className="h-3.5 w-3.5 mr-1" />
                          {t('public_portal.leads.promote_to_contact', 'Convertir a contacte')}
                        </Button>
                      )}
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  )
}
