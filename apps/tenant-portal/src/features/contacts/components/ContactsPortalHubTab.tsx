import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Search, Shield } from 'lucide-react'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { getContacts } from '../api/contactsService'
import {
  listCustomerAccessGrants,
  listCustomerAccessInvitations,
} from '@/features/field-service/api/customerAccessGrantsService'

export function ContactsPortalHubTab() {
  const { t, i18n } = useTranslation('contacts')
  const [search, setSearch] = useState('')

  const { data: grants = [], isLoading: grantsLoading } = useQuery({
    queryKey: ['customer-access-grants', 'hub'],
    queryFn: () => listCustomerAccessGrants({ onlyActive: false }),
  })

  const { data: invitations = [] } = useQuery({
    queryKey: ['customer-access-invitations', 'hub'],
    queryFn: () => listCustomerAccessInvitations({ onlyPending: true }),
  })

  const { data: contacts = [] } = useQuery({
    queryKey: ['contacts', 'portal-hub-names'],
    queryFn: () => getContacts({ limit: 500 }),
  })

  const nameById = useMemo(() => {
    const map = new Map<string, string>()
    for (const c of contacts) {
      if (c.id && c.display_name) map.set(c.id, c.display_name)
    }
    return map
  }, [contacts])

  const pendingByAccount = useMemo(() => {
    const map = new Map<string, number>()
    for (const inv of invitations) {
      if (!inv.is_pending) continue
      map.set(
        inv.client_account_contact_id,
        (map.get(inv.client_account_contact_id) ?? 0) + 1,
      )
    }
    return map
  }, [invitations])

  const locale =
    i18n.language?.startsWith('es')
      ? 'es-ES'
      : i18n.language?.startsWith('en')
        ? 'en-GB'
        : 'ca-ES'

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    type HubRow =
      | { kind: 'grant'; grant: (typeof grants)[number] }
      | { kind: 'invite_only'; accountId: string; pending: number }

    const grantAccountIds = new Set(grants.map((g) => g.client_account_contact_id))
    const rows: HubRow[] = grants.map((g) => ({ kind: 'grant', grant: g }))
    for (const [accountId, pending] of pendingByAccount) {
      if (!grantAccountIds.has(accountId) && pending > 0) {
        rows.push({ kind: 'invite_only', accountId, pending })
      }
    }

    if (!q) return rows
    return rows.filter((row) => {
      if (row.kind === 'grant') {
        const g = row.grant
        const accountName = nameById.get(g.client_account_contact_id) ?? ''
        return (
          g.email_normalized.includes(q) ||
          accountName.toLowerCase().includes(q) ||
          g.client_account_contact_id.includes(q)
        )
      }
      const accountName = nameById.get(row.accountId) ?? ''
      return accountName.toLowerCase().includes(q) || row.accountId.includes(q)
    })
  }, [grants, search, nameById, pendingByAccount])

  const pendingTotal = invitations.filter((i) => i.is_pending).length

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-base font-semibold flex items-center gap-2">
            <Shield className="h-4 w-4" />
            {t('contacts.portal_hub.title', 'Hub d\'accés al portal')}
          </h2>
          <p className="text-sm text-muted-foreground mt-1">
            {t(
              'contacts.portal_hub.subtitle',
              '{{grants}} accessos · {{pending}} invitacions pendents',
              { grants: grants.filter((g) => g.is_active).length, pending: pendingTotal },
            )}
          </p>
        </div>
      </div>

      <div className="relative max-w-md">
        <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground pointer-events-none" />
        <Input
          className="pl-9"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder={t(
            'contacts.portal_hub.search',
            'Cerca per email o compte…',
          )}
        />
      </div>

      {grantsLoading ? (
        <p className="text-sm text-muted-foreground">
          {t('contacts.detail.projects_loading', 'Carregant…')}
        </p>
      ) : filtered.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('contacts.portal_hub.empty', 'Cap accés registrat.')}
        </p>
      ) : (
        <div className="overflow-x-auto rounded-xl border border-border">
          <table className="w-full text-sm">
            <thead className="bg-muted/40 text-left text-xs text-muted-foreground">
              <tr>
                <th className="px-4 py-2 font-medium">
                  {t('contacts.portal_hub.col_account', 'Compte')}
                </th>
                <th className="px-4 py-2 font-medium">
                  {t('contacts.portal_hub.col_email', 'Email')}
                </th>
                <th className="px-4 py-2 font-medium">
                  {t('contacts.portal_hub.col_kind', 'Tipus')}
                </th>
                <th className="px-4 py-2 font-medium">
                  {t('contacts.portal_hub.col_status', 'Estat')}
                </th>
                <th className="px-4 py-2 font-medium">
                  {t('contacts.portal_hub.col_pending', 'Pendents')}
                </th>
                <th className="px-4 py-2 font-medium" />
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {filtered.map((row) => {
                if (row.kind === 'invite_only') {
                  const accountName =
                    nameById.get(row.accountId) ?? row.accountId.slice(0, 8)
                  return (
                    <tr key={`invite-${row.accountId}`} className="hover:bg-accent/30">
                      <td className="px-4 py-2.5 font-medium">{accountName}</td>
                      <td className="px-4 py-2.5 text-muted-foreground">—</td>
                      <td className="px-4 py-2.5 text-muted-foreground">—</td>
                      <td className="px-4 py-2.5">
                        <Badge variant="secondary">
                          {t('contacts.portal_hub.pending_only', 'Només invitacions')}
                        </Badge>
                      </td>
                      <td className="px-4 py-2.5">{row.pending}</td>
                      <td className="px-4 py-2.5 text-right">
                        <Link
                          to={`/contacts/${row.accountId}?tab=portal_access`}
                          className="text-indigo-600 hover:underline text-xs font-medium"
                        >
                          {t('contacts.portal_hub.open', 'Gestionar')}
                        </Link>
                      </td>
                    </tr>
                  )
                }
                const g = row.grant
                const accountName =
                  nameById.get(g.client_account_contact_id) ??
                  g.client_account_contact_id.slice(0, 8)
                const pending = pendingByAccount.get(g.client_account_contact_id) ?? 0
                return (
                  <tr key={g.id} className="hover:bg-accent/30">
                    <td className="px-4 py-2.5 font-medium">{accountName}</td>
                    <td className="px-4 py-2.5">{g.email_normalized}</td>
                    <td className="px-4 py-2.5 text-muted-foreground">{g.principal_kind}</td>
                    <td className="px-4 py-2.5">
                      {g.is_active ? (
                        <Badge variant="default">
                          {t('contacts.portal_hub.active', 'Actiu')}
                        </Badge>
                      ) : (
                        <Badge variant="secondary">
                          {t('contacts.portal_hub.revoked', 'Revocat')}
                        </Badge>
                      )}
                      {g.last_seen_at && (
                        <span className="ml-2 text-xs text-muted-foreground">
                          {new Date(g.last_seen_at).toLocaleDateString(locale)}
                        </span>
                      )}
                    </td>
                    <td className="px-4 py-2.5">{pending > 0 ? pending : '—'}</td>
                    <td className="px-4 py-2.5 text-right">
                      <Link
                        to={`/contacts/${g.client_account_contact_id}?tab=portal_access`}
                        className="text-indigo-600 hover:underline text-xs font-medium"
                      >
                        {t('contacts.portal_hub.open', 'Gestionar')}
                      </Link>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
