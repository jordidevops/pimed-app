import { useState, useMemo } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { Plus, Search, Users } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { useIsFieldService, useSectorContactListLabel } from '@/hooks/useSectorLabel'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { ScrollableTabBar } from '@/components/ui/scrollable-tab-bar'
import {
  getActiveContactSitesForTenant,
  getContacts,
  googleMapsUrlForSite,
} from '../api/contactsService'
import type { Contact } from '../api/contactsService'
import { ContactCard, type ContactCardSiteInfo } from './ContactCard'
import { ContactForm } from './ContactForm'
import { ContactsPortalHubTab } from './ContactsPortalHubTab'

type KindFilter = 'all' | 'person' | 'company'
type ContactsPageTab = 'list' | 'portal_hub'

export function ContactsPage() {
  const { t } = useTranslation('contacts')
  const contactListLabel = useSectorContactListLabel()
  const isFieldService = useIsFieldService()
  const { activeTenant, tenants, tenantsLoading } = useTenant()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [searchParams, setSearchParams] = useSearchParams()

  const [search, setSearch] = useState('')
  const [kindFilter, setKindFilter] = useState<KindFilter>('all')
  const [formOpen, setFormOpen] = useState(false)

  const activeTab: ContactsPageTab =
    searchParams.get('tab') === 'portal_hub' ? 'portal_hub' : 'list'

  function selectTab(tab: ContactsPageTab) {
    const next = new URLSearchParams(searchParams)
    if (tab === 'list') next.delete('tab')
    else next.set('tab', tab)
    setSearchParams(next, { replace: true })
  }

  const {
    data: contacts = [],
    isLoading,
    error,
  } = useQuery<Contact[]>({
    queryKey: ['contacts', activeTenant?.id],
    queryFn: () => getContacts(),
    enabled: !!activeTenant,
  })

  const { data: contactSites = [] } = useQuery({
    queryKey: ['contact_sites', 'tenant', activeTenant?.id],
    queryFn: () => getActiveContactSitesForTenant(),
    enabled: !!activeTenant && activeTab === 'list',
  })

  const sitesByContact = useMemo(() => {
    const map = new Map<string, ContactCardSiteInfo>()
    for (const site of contactSites) {
      if (!site.contact_id) continue
      const mapsUrl = googleMapsUrlForSite(site)
      const existing = map.get(site.contact_id)
      if (!existing) {
        map.set(site.contact_id, { count: 1, mapsUrl })
      } else {
        map.set(site.contact_id, {
          count: existing.count + 1,
          mapsUrl: existing.mapsUrl ?? mapsUrl,
        })
      }
    }
    return map
  }, [contactSites])

  const filtered = useMemo(() => {
    let result = contacts
    if (kindFilter !== 'all') {
      result = result.filter((c) => c.kind === kindFilter)
    }
    if (search.trim()) {
      const q = search.trim().toLowerCase()
      result = result.filter(
        (c) =>
          c.display_name?.toLowerCase().includes(q) ||
          c.email?.toLowerCase().includes(q) ||
          c.phone?.includes(q),
      )
    }
    return result
  }, [contacts, kindFilter, search])

  if (tenantsLoading) {
    return (
      <div className="flex items-center justify-center h-full">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-indigo-600" />
      </div>
    )
  }

  if (!activeTenant && tenants.length > 1) {
    return (
      <div className="max-w-3xl mx-auto px-4 py-10">
        <div className="bg-amber-50 border border-amber-200 rounded-2xl p-6 text-center">
          <p className="text-sm text-amber-800 font-medium">
            {t('contacts.errors.load_failed', 'Error en carregar els contactes')}
          </p>
        </div>
      </div>
    )
  }

  if (!activeTenant) return null

  return (
    <div className="max-w-6xl mx-auto px-4 py-6 space-y-5">
      <div className="flex items-center justify-between gap-3">
        <h1 className="text-2xl font-bold text-foreground">
          {isFieldService
            ? contactListLabel
            : t('contacts.title', 'Contactes')}
        </h1>
        {activeTab === 'list' && (
          <Button onClick={() => setFormOpen(true)}>
            <Plus className="h-4 w-4 mr-1.5" />
            {t('contacts.new_contact', 'Nou contacte')}
          </Button>
        )}
      </div>

      <ScrollableTabBar
        activeKey={activeTab}
        aria-label={t('contacts.tabs_label', 'Seccions de contactes')}
        className="border-b"
      >
        <button
          type="button"
          data-tab-key="list"
          onClick={() => selectTab('list')}
          className={`px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors whitespace-nowrap ${
            activeTab === 'list'
              ? 'border-primary text-primary'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          {t('contacts.tabs.list', 'Contactes')}
        </button>
        <button
          type="button"
          data-tab-key="portal_hub"
          onClick={() => selectTab('portal_hub')}
          className={`px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors whitespace-nowrap ${
            activeTab === 'portal_hub'
              ? 'border-primary text-primary'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          {t('contacts.tabs.portal_hub', 'Portal clients')}
        </button>
      </ScrollableTabBar>

      {activeTab === 'portal_hub' ? (
        <ContactsPortalHubTab />
      ) : (
        <>
          <div className="flex flex-col sm:flex-row gap-3">
            <div className="relative flex-1">
              <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground pointer-events-none" />
              <Input
                className="pl-9"
                placeholder={t('contacts.search_placeholder', 'Cerca per nom, email o telèfon...')}
                value={search}
                onChange={(e) => setSearch(e.target.value)}
              />
            </div>

            <div className="flex gap-1 rounded-lg border border-border p-0.5 bg-background shrink-0">
              {(['all', 'person', 'company'] as KindFilter[]).map((k) => (
                <button
                  key={k}
                  type="button"
                  onClick={() => setKindFilter(k)}
                  className={`px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${
                    kindFilter === k
                      ? 'bg-indigo-600 text-white shadow-sm'
                      : 'text-muted-foreground hover:bg-accent'
                  }`}
                >
                  {k === 'all'
                    ? t('contacts.filter_all', 'Tots')
                    : k === 'person'
                    ? t('contacts.filter_person', 'Persones')
                    : t('contacts.filter_company', 'Empreses')}
                </button>
              ))}
            </div>
          </div>

          {error && (
            <div className="rounded-xl border border-destructive/30 bg-destructive/10 p-4">
              <p className="text-sm text-destructive">
                {t('contacts.errors.load_failed', 'Error en carregar els contactes')}
              </p>
            </div>
          )}

          {isLoading && (
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
              {[1, 2, 3, 4, 5, 6].map((i) => (
                <div key={i} className="h-40 rounded-2xl bg-accent/40 animate-pulse" />
              ))}
            </div>
          )}

          {!isLoading && !error && filtered.length === 0 && (
            <div className="flex flex-col items-center justify-center py-20 gap-4 text-center">
              <div className="h-14 w-14 rounded-full bg-indigo-100 dark:bg-indigo-900/30 flex items-center justify-center">
                <Users className="h-7 w-7 text-indigo-500" />
              </div>
              <div>
                <p className="text-base font-semibold text-foreground">
                  {t('contacts.empty_title', 'Encara no hi ha contactes')}
                </p>
              </div>
              {contacts.length === 0 && (
                <Button variant="outline" onClick={() => setFormOpen(true)}>
                  <Plus className="h-4 w-4 mr-1.5" />
                  {t('contacts.empty_cta', 'Crea el primer contacte')}
                </Button>
              )}
            </div>
          )}

          {!isLoading && filtered.length > 0 && (
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
              {filtered.map((contact) => (
                <ContactCard
                  key={contact.id}
                  contact={contact}
                  siteInfo={contact.id ? sitesByContact.get(contact.id) : undefined}
                />
              ))}
            </div>
          )}
        </>
      )}

      <ContactForm
        open={formOpen}
        onClose={() => setFormOpen(false)}
        onCreated={(id) => {
          setFormOpen(false)
          queryClient.invalidateQueries({ queryKey: ['contacts'] })
          navigate(`/contacts/${id}`)
        }}
      />
    </div>
  )
}
