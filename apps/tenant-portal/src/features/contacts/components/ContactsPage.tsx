import { useMemo, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { Plus, Search, Users } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { useIsFieldService, useSectorContactListLabel } from '@/hooks/useSectorLabel'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { ScrollableTabBar } from '@/components/ui/scrollable-tab-bar'
import { PageShell } from '@/components/layout/PageShell'
import { ListViewToggle } from '@/components/layout/ListViewToggle'
import { FilterChips } from '@/components/layout/FilterChips'
import { SiteScopeFilter } from '@/components/layout/SiteScopeFilter'
import { useListViewMode } from '@/hooks/useListViewMode'
import { useListDensity } from '@/hooks/useListDensity'
import { useSiteScope } from '@/hooks/useSiteScope'
import { SalesDataTable, type SalesDataTableColumn } from '@/features/commercial/components/SalesDataTable'
import {
  getActiveContactSitesForTenant,
  getContactLifecycleSignalRows,
  getContacts,
  googleMapsUrlForSite,
} from '../api/contactsService'
import type { Contact } from '../api/contactsService'
import {
  buildLifecycleByContactId,
  type ContactCommercialLifecycle,
} from '../utils/contactCommercialLifecycle'
import { ContactCard, type ContactCardSiteInfo } from './ContactCard'
import { ContactLifecycleBadge } from './ContactLifecycleBadge'
import { ContactForm } from './ContactForm'
import { ContactsPortalHubTab } from './ContactsPortalHubTab'

type KindFilter = 'all' | 'person' | 'company'
type LifecycleFilter = 'all' | ContactCommercialLifecycle
type ContactsPageTab = 'list' | 'portal_hub'

function lifecycleLabel(
  lifecycle: ContactCommercialLifecycle,
  t: (key: string, fallback: string) => string,
): string {
  if (lifecycle === 'effective') return t('contacts.lifecycle.effective', 'Efectiu')
  if (lifecycle === 'potential') return t('contacts.lifecycle.potential', 'Potencial')
  return t('contacts.lifecycle.agenda', 'Agenda')
}

export function ContactsPage() {
  const { t } = useTranslation(['contacts', 'common'])
  const contactListLabel = useSectorContactListLabel()
  const isFieldService = useIsFieldService()
  const { activeTenant, tenants, tenantsLoading } = useTenant()
  const {
    sites: tenantSites,
    selectedSiteId,
    setSelectedSiteId,
    showSiteFilter,
    canUseAllSites,
  } = useSiteScope()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [searchParams, setSearchParams] = useSearchParams()

  const [search, setSearch] = useState('')
  const [kindFilter, setKindFilter] = useState<KindFilter>('all')
  const [lifecycleFilter, setLifecycleFilter] = useState<LifecycleFilter>('all')
  const [formOpen, setFormOpen] = useState(false)
  const { mode, setMode, effectiveMode } = useListViewMode('contacts.list', 'cards')
  const { density, setDensity } = useListDensity('contacts.list', 'comfortable')

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

  const { data: lifecycleSignals } = useQuery({
    queryKey: ['contacts', 'lifecycle_signals', activeTenant?.id],
    queryFn: () => getContactLifecycleSignalRows(),
    enabled: !!activeTenant && activeTab === 'list',
  })

  const lifecycleByContact = useMemo(() => {
    if (!lifecycleSignals) return new Map<string, ContactCommercialLifecycle>()
    return buildLifecycleByContactId(
      contacts.map((c) => ({ id: c.id, source: c.source })),
      lifecycleSignals.docs,
      lifecycleSignals.projects,
    )
  }, [contacts, lifecycleSignals])

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
    // Sidebar / table site scope: show global contacts + contacts of that local.
    if (selectedSiteId) {
      result = result.filter((c) => !c.site_id || c.site_id === selectedSiteId)
    }
    if (kindFilter !== 'all') {
      result = result.filter((c) => c.kind === kindFilter)
    }
    if (lifecycleFilter !== 'all') {
      result = result.filter((c) => {
        if (!c.id) return false
        return (lifecycleByContact.get(c.id) ?? 'agenda') === lifecycleFilter
      })
    }
    if (search.trim()) {
      const q = search.trim().toLowerCase()
      result = result.filter(
        (c) =>
          c.display_name?.toLowerCase().includes(q) ||
          c.email?.toLowerCase().includes(q) ||
          c.phone?.includes(q) ||
          c.legal_name?.toLowerCase().includes(q) ||
          c.tax_id?.toLowerCase().includes(q),
      )
    }
    return result
  }, [contacts, kindFilter, lifecycleByContact, lifecycleFilter, search, selectedSiteId])

  const filterChips = [
    ...(search.trim()
      ? [{ key: 'q', label: search.trim(), onRemove: () => setSearch('') }]
      : []),
    ...(kindFilter !== 'all'
      ? [
          {
            key: 'kind',
            label:
              kindFilter === 'person'
                ? t('contacts.filter_person', 'Persones')
                : t('contacts.filter_company', 'Empreses'),
            onRemove: () => setKindFilter('all'),
          },
        ]
      : []),
    ...(lifecycleFilter !== 'all'
      ? [
          {
            key: 'lifecycle',
            label: lifecycleLabel(lifecycleFilter, t),
            onRemove: () => setLifecycleFilter('all'),
          },
        ]
      : []),
  ]

  const columns = useMemo<SalesDataTableColumn<Contact>[]>(
    () => [
      {
        id: 'name',
        header: t('contacts.fields.display_name', 'Nom'),
        cell: (contact) => (
          <button
            type="button"
            className="text-left font-semibold hover:underline"
            onClick={() => contact.id && navigate(`/contacts/${contact.id}`)}
          >
            {contact.display_name || '—'}
          </button>
        ),
      },
      {
        id: 'kind',
        header: t('contacts.fields.kind', 'Tipus'),
        cell: (contact) =>
          contact.kind === 'company'
            ? t('contacts.kind.company', 'Empresa')
            : t('contacts.kind.person', 'Persona'),
      },
      {
        id: 'lifecycle',
        header: t('contacts.lifecycle.column', 'Estat'),
        cell: (contact) => {
          const lifecycle = contact.id ? lifecycleByContact.get(contact.id) : undefined
          return lifecycle ? <ContactLifecycleBadge lifecycle={lifecycle} /> : '—'
        },
      },
      {
        id: 'email',
        header: t('contacts.fields.email', 'Correu electrònic'),
        cell: (contact) => (
          <span className="text-muted-foreground">{contact.email || '—'}</span>
        ),
      },
      {
        id: 'phone',
        header: t('contacts.fields.phone', 'Telèfon'),
        cell: (contact) => (
          <span className="text-muted-foreground">{contact.phone || '—'}</span>
        ),
      },
    ],
    [lifecycleByContact, navigate, t],
  )

  if (tenantsLoading) {
    return (
      <div className="flex h-full items-center justify-center">
        <div className="h-8 w-8 animate-spin rounded-full border-b-2 border-indigo-600" />
      </div>
    )
  }

  if (!activeTenant && tenants.length > 1) {
    return (
      <div className="mx-auto max-w-3xl px-4 py-10">
        <div className="rounded-2xl border border-amber-200 bg-amber-50 p-6 text-center">
          <p className="text-sm font-medium text-amber-800">
            {t('contacts.errors.load_failed', 'Error en carregar els contactes')}
          </p>
        </div>
      </div>
    )
  }

  if (!activeTenant) return null

  const kindFilters: Array<{ id: KindFilter; label: string }> = [
    { id: 'all', label: t('contacts.filter_all', 'Tots') },
    { id: 'person', label: t('contacts.filter_person', 'Persones') },
    { id: 'company', label: t('contacts.filter_company', 'Empreses') },
  ]

  const lifecycleFilters: Array<{ id: LifecycleFilter; label: string }> = [
    { id: 'all', label: t('contacts.lifecycle.filter_all', 'Tots els estats') },
    { id: 'effective', label: lifecycleLabel('effective', t) },
    { id: 'potential', label: lifecycleLabel('potential', t) },
    { id: 'agenda', label: lifecycleLabel('agenda', t) },
  ]

  return (
    <>
      <PageShell
        title={isFieldService ? contactListLabel : t('contacts.title', 'Contactes')}
        icon={<Users className="h-5 w-5" aria-hidden />}
        actions={
          activeTab === 'list' ? (
            <Button onClick={() => setFormOpen(true)}>
              <Plus className="mr-1.5 h-4 w-4" />
              {t('contacts.new_contact', 'Nou contacte')}
            </Button>
          ) : null
        }
        tabs={
          <ScrollableTabBar
            activeKey={activeTab}
            aria-label={t('contacts.tabs_label', 'Seccions de contactes')}
            className="border-b"
          >
            <button
              type="button"
              data-tab-key="list"
              onClick={() => selectTab('list')}
              className={`-mb-px whitespace-nowrap border-b-2 px-4 py-2 text-sm font-medium transition-colors ${
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
              className={`-mb-px whitespace-nowrap border-b-2 px-4 py-2 text-sm font-medium transition-colors ${
                activeTab === 'portal_hub'
                  ? 'border-primary text-primary'
                  : 'border-transparent text-muted-foreground hover:text-foreground'
              }`}
            >
              {t('contacts.tabs.portal_hub', 'Portal clients')}
            </button>
          </ScrollableTabBar>
        }
        toolbar={
          activeTab === 'list' ? (
            <div className="space-y-3">
              <div className="flex flex-wrap items-center gap-2">
                <label className="relative block min-w-[12rem] flex-1">
                  <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
                  <Input
                    className="pl-9"
                    placeholder={t(
                      'contacts.search_placeholder',
                      'Cerca per nom, email, telèfon o NIF…',
                    )}
                    value={search}
                    onChange={(e) => setSearch(e.target.value)}
                    aria-label={t('contacts.search_aria', 'Cerca contactes')}
                  />
                </label>
                <ListViewToggle
                  mode={mode}
                  onModeChange={setMode}
                  density={density}
                  onDensityChange={setDensity}
                  showDensity={effectiveMode === 'table'}
                />
              </div>

              <div className="flex flex-wrap gap-1.5">
                {kindFilters.map((filter) => (
                  <Button
                    key={filter.id}
                    type="button"
                    size="sm"
                    variant={kindFilter === filter.id ? 'default' : 'outline'}
                    className="h-7 rounded-full px-2.5 text-xs"
                    onClick={() => setKindFilter(filter.id)}
                  >
                    {filter.label}
                  </Button>
                ))}
              </div>

              <div className="flex flex-wrap gap-1.5">
                {lifecycleFilters.map((filter) => (
                  <Button
                    key={filter.id}
                    type="button"
                    size="sm"
                    variant={lifecycleFilter === filter.id ? 'default' : 'outline'}
                    className="h-7 rounded-full px-2.5 text-xs"
                    onClick={() => setLifecycleFilter(filter.id)}
                  >
                    {filter.label}
                  </Button>
                ))}
              </div>

              {showSiteFilter ? (
                <SiteScopeFilter
                  sites={tenantSites}
                  value={selectedSiteId}
                  onChange={setSelectedSiteId}
                  canSelectAll={canUseAllSites}
                />
              ) : null}

              <FilterChips
                chips={filterChips}
                clearAllLabel={t('common:list.clear_filters', 'Netejar filtres')}
                onClearAll={() => {
                  setSearch('')
                  setKindFilter('all')
                  setLifecycleFilter('all')
                }}
              />
            </div>
          ) : undefined
        }
      >
        {activeTab === 'portal_hub' ? (
          <ContactsPortalHubTab />
        ) : (
          <>
            {error && (
              <div className="rounded-xl border border-destructive/30 bg-destructive/10 p-4">
                <p className="text-sm text-destructive">
                  {t('contacts.errors.load_failed', 'Error en carregar els contactes')}
                </p>
              </div>
            )}

            {isLoading && (
              <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
                {[1, 2, 3, 4, 5, 6].map((i) => (
                  <div key={i} className="h-40 animate-pulse rounded-2xl bg-accent/40" />
                ))}
              </div>
            )}

            {!isLoading && !error && filtered.length === 0 && (
              <div className="flex flex-col items-center justify-center gap-4 py-20 text-center">
                <div className="flex h-14 w-14 items-center justify-center rounded-full bg-primary/10">
                  <Users className="h-7 w-7 text-primary" />
                </div>
                <p className="text-base font-semibold text-foreground">
                  {contacts.length === 0
                    ? t('contacts.empty_title', 'Encara no hi ha contactes')
                    : t('contacts.empty_filtered', 'Cap contacte no coincideix amb la cerca.')}
                </p>
                {contacts.length === 0 ? (
                  <Button variant="outline" onClick={() => setFormOpen(true)}>
                    <Plus className="mr-1.5 h-4 w-4" />
                    {t('contacts.empty_cta', 'Crea el primer contacte')}
                  </Button>
                ) : null}
              </div>
            )}

            {!isLoading && filtered.length > 0 && effectiveMode === 'cards' ? (
              <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
                {filtered.map((contact) => (
                  <ContactCard
                    key={contact.id}
                    contact={contact}
                    siteInfo={contact.id ? sitesByContact.get(contact.id) : undefined}
                    lifecycle={
                      contact.id ? lifecycleByContact.get(contact.id) ?? null : null
                    }
                  />
                ))}
              </div>
            ) : null}

            {!isLoading && filtered.length > 0 && effectiveMode === 'table' ? (
              <SalesDataTable
                columns={columns}
                rows={filtered}
                getRowId={(contact) => contact.id!}
                density={density}
                onRowActivate={(contact) => {
                  if (contact.id) navigate(`/contacts/${contact.id}`)
                }}
                countLabel={t('common:list.showing_count', 'Mostrant {{shown}} de {{total}}', {
                  shown: filtered.length,
                  total: contacts.length,
                })}
                rowActions={(contact) => [
                  {
                    key: 'open',
                    label: t('contacts.actions.view', 'Veure detall'),
                    onSelect: () => {
                      if (contact.id) navigate(`/contacts/${contact.id}`)
                    },
                  },
                ]}
              />
            ) : null}
          </>
        )}
      </PageShell>

      <ContactForm
        open={formOpen}
        onClose={() => setFormOpen(false)}
        onCreated={(id) => {
          setFormOpen(false)
          queryClient.invalidateQueries({ queryKey: ['contacts'] })
          navigate(`/contacts/${id}`)
        }}
      />
    </>
  )
}
