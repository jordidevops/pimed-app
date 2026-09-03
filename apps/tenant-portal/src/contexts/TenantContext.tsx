import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useAuth } from './AuthContext'
import { useTenants } from '../hooks/useTenants'
import { useSites } from '../hooks/useSites'
import type { TenantInfo } from '../hooks/useTenants'
import type { SiteInfo } from '../hooks/useSites'
import { setActiveTenantId } from '../lib/supabase'
import { supabase } from '../lib/supabase'

const ALL_TENANTS_SENTINEL = '__ALL_TENANTS__'

interface TenantContextType {
  /** All tenants the user belongs to */
  tenants: TenantInfo[]
  tenantsLoading: boolean
  /** The currently-selected tenant. null = "all tenants" (multi-tenant users only) */
  selectedTenantId: string | null
  setSelectedTenantId: (id: string | null) => void
  /** Resolved tenant object for selectedTenantId (or first tenant for single-tenant users) */
  activeTenant: TenantInfo | null
  /** Role in the active tenant (global role, from tenant_members where site_id IS NULL) */
  activeRole: TenantInfo['role'] | null
  /** Active sites within the selected tenant */
  sites: SiteInfo[]
  sitesLoading: boolean
  /** true quan es pot usar la vista agregada "Tots els locals" (formulari / multi-site) */
  canUseAllSites: boolean
  /** true quan l'usuari només veu un local: selector en badge, sense "Tots els locals" */
  isSingleSiteContext: boolean
  /** The currently-selected site. null = "Vista Global" (only when multi-site + canUseAllSites) */
  selectedSiteId: string | null
  setSelectedSiteId: (id: string | null) => void
  /** Resolved site object for selectedSiteId */
  activeSite: SiteInfo | null
  /** Role for selectedSiteId from tenant_members (null when global view or no membership) */
  activeSiteRole: string | null
  /** true quan el header x-tenant-id ja està sincronitzat amb el tenant actiu */
  tenantScopeReady: boolean
}

const TenantContext = createContext<TenantContextType | undefined>(undefined)

/**
 * TenantProvider — makes the selected tenant and site available to any page.
 *
 * Tenant model: 1 Tenant (Franquícia) → N Sites (Restaurants)
 *
 * Tenant selection:
 *   - Single-tenant users: activeTenant is always tenants[0], selector not shown.
 *   - Multi-tenant users: activeTenant follows selectedTenantId (null = "all").
 *
 * Site selection:
 *   - Users with global_role and >1 visible site: can select any site or "Vista Global" (null).
 *   - Exactly one visible site (solo / single site): always pinned; no "Tots els locals" UX.
 *   - Users with site-only access: auto-selected to their single site if only one exists.
 *   - selectedSiteId persists in sessionStorage (separate key per tenant).
 */
export function TenantProvider({ children }: { children: ReactNode }) {
  const { user } = useAuth()
  const { data: tenants = [], isLoading: tenantsLoading } = useTenants(user?.id)

  const [selectedTenantId, setSelectedTenantIdState] = useState<string | null>(() => {
    const stored = sessionStorage.getItem('selectedTenantId')
    if (!stored || stored === ALL_TENANTS_SENTINEL) return null
    return stored
  })

  // Distingeix "cap seleccio guardada" de "Totes les organitzacions" triat explicitament.
  const [hasStoredTenantSelection, setHasStoredTenantSelection] = useState<boolean>(() => {
    return sessionStorage.getItem('selectedTenantId') !== null
  })

  const [selectedSiteId, setSelectedSiteIdState] = useState<string | null>(() => {
    const tenantId = sessionStorage.getItem('selectedTenantId')
    if (!tenantId || tenantId === ALL_TENANTS_SENTINEL) return null
    return tenantId ? (sessionStorage.getItem(`selectedSiteId_${tenantId}`) ?? null) : null
  })

  const [tenantScopeReady, setTenantScopeReady] = useState(false)

  const { data: sites = [], isLoading: sitesLoading } = useSites(selectedTenantId, user?.id)

  const { data: myMemberships = [] } = useQuery<
    { site_id: string | null; role: string }[]
  >({
    queryKey: ['my-memberships', selectedTenantId, user?.id],
    enabled: !!selectedTenantId && !!user?.id,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('tenant_members')
        .select('site_id, role')
        .eq('tenant_id', selectedTenantId!)
        .eq('user_id', user!.id)
        .eq('is_active', true)

      if (error) throw error
      return data as { site_id: string | null; role: string }[]
    },
  })

  const hasGlobalMembership = myMemberships.some((m) => m.site_id === null)
  const siteRoleIds = myMemberships
    .filter((m) => !!m.site_id)
    .map((m) => m.site_id as string)

  // Limita els sites visibles per a usuaris site-only.
  const visibleSites = hasGlobalMembership
    ? sites
    : sites.filter((s) => siteRoleIds.includes(s.id))

  // Vista "Tots els locals": capacitat (globals o >1 site). La UX d'1 local la pina igualment.
  const canUseAllSites = hasGlobalMembership || visibleSites.length > 1
  const isSingleSiteContext = visibleSites.length === 1

  // Normalitza seleccio de tenant:
  // - neteja IDs obsolets (despres de db reset)
  // - tria un tenant valid per defecte en primer login
  // - respecta l'opcio explicita de "Totes les organitzacions"
  // Important: no tocar sessionStorage mentre l'usuari encara no està resolt
  // (useTenants disabled → tenants=[] + isLoading=false) o esborra el tenant
  // pinat per e2e / reload i cau al fallback tenants[0].
  useEffect(() => {
    if (!user?.id) return
    if (tenantsLoading) return

    if (tenants.length === 0) {
      setSelectedTenantIdState(null)
      setSelectedSiteIdState(null)
      setHasStoredTenantSelection(false)
      sessionStorage.removeItem('selectedTenantId')
      setActiveTenantId(null)
      return
    }

    // Prefer field_service (Volt) over alphabetical/unstable order when picking a default.
    const preferredFallbackId =
      tenants.find((t) => t.archetype === 'field_service')?.id
      ?? tenants.find((t) => t.slug === 'volt-serveis')?.id
      ?? tenants[0].id

    // ID guardat pero no valid (p. ex. despres d'un reset local)
    if (selectedTenantId && !tenants.some((t) => t.id === selectedTenantId)) {
      const fallbackTenantId = preferredFallbackId
      setSelectedTenantIdState(fallbackTenantId)
      setSelectedSiteIdState(sessionStorage.getItem(`selectedSiteId_${fallbackTenantId}`) ?? null)
      setHasStoredTenantSelection(true)
      sessionStorage.setItem('selectedTenantId', fallbackTenantId)
      setActiveTenantId(fallbackTenantId)
      return
    }

    // Si no hi ha seleccio guardada, fixem tenant actiu per evitar pantalles en blanc
    // en moduls que assumeixen activeTenant no null.
    if (!selectedTenantId && !hasStoredTenantSelection) {
      const fallbackTenantId = preferredFallbackId
      setSelectedTenantIdState(fallbackTenantId)
      setSelectedSiteIdState(sessionStorage.getItem(`selectedSiteId_${fallbackTenantId}`) ?? null)
      setHasStoredTenantSelection(true)
      sessionStorage.setItem('selectedTenantId', fallbackTenantId)
      setActiveTenantId(fallbackTenantId)
      return
    }

    // Cas de tenant unic: forcem coherentment aquest tenant.
    if (tenants.length === 1 && selectedTenantId !== tenants[0].id) {
      setSelectedTenantIdState(tenants[0].id)
      setSelectedSiteIdState(sessionStorage.getItem(`selectedSiteId_${tenants[0].id}`) ?? null)
      setHasStoredTenantSelection(true)
      sessionStorage.setItem('selectedTenantId', tenants[0].id)
      setActiveTenantId(tenants[0].id)
    }
  }, [user?.id, tenants, tenantsLoading, selectedTenantId, hasStoredTenantSelection])

  // Auto-select/sanitize site when tenant changes or sites load
  useEffect(() => {
    if (sitesLoading || !selectedTenantId) return

    if (visibleSites.length === 0) {
      setSelectedSiteIdState(null)
      sessionStorage.removeItem(`selectedSiteId_${selectedTenantId}`)
      return
    }

    // Un sol local visible: sempre pinat (també owners globals / solo).
    if (visibleSites.length === 1) {
      if (selectedSiteId !== visibleSites[0].id) {
        setSelectedSiteIdState(visibleSites[0].id)
        sessionStorage.setItem(`selectedSiteId_${selectedTenantId}`, visibleSites[0].id)
      }
      return
    }

    if (selectedSiteId && !visibleSites.some((s) => s.id === selectedSiteId)) {
      const fallback = canUseAllSites ? null : visibleSites[0].id
      setSelectedSiteIdState(fallback)
      if (fallback) sessionStorage.setItem(`selectedSiteId_${selectedTenantId}`, fallback)
      else sessionStorage.removeItem(`selectedSiteId_${selectedTenantId}`)
    }
  }, [canUseAllSites, selectedSiteId, selectedTenantId, sitesLoading, visibleSites])

  // Reset site selection when tenant changes
  const setSelectedTenantId = (id: string | null) => {
    setSelectedTenantIdState(id)
    setHasStoredTenantSelection(true)
    setActiveTenantId(id)
    if (id) {
      sessionStorage.setItem('selectedTenantId', id)
      // Restore last site selection for this tenant (or null = Vista Global)
      const savedSite = sessionStorage.getItem(`selectedSiteId_${id}`)
      setSelectedSiteIdState(savedSite)
    } else {
      // Guardem sentinel per diferenciar "all tenants" d'"encara no seleccionat".
      sessionStorage.setItem('selectedTenantId', ALL_TENANTS_SENTINEL)
      setSelectedSiteIdState(null)
    }
  }

  const setSelectedSiteId = (id: string | null) => {
    setSelectedSiteIdState(id)
    if (selectedTenantId) {
      if (id) sessionStorage.setItem(`selectedSiteId_${selectedTenantId}`, id)
      else sessionStorage.removeItem(`selectedSiteId_${selectedTenantId}`)
    }
  }

  const activeTenant =
    (selectedTenantId ? tenants.find((t) => t.id === selectedTenantId) : null) ??
    (tenants.length === 1 ? tenants[0] : null)

  const activeRole = activeTenant?.role ?? null

  const activeSite = selectedSiteId
    ? (visibleSites.find((s: SiteInfo) => s.id === selectedSiteId) ?? null)
    : null

  const activeSiteRole = selectedSiteId
    ? (myMemberships.find((m) => m.site_id === selectedSiteId)?.role ?? null)
    : null

  // Manté el header x-tenant-id sincronitzat en tots els casos:
  // - selecció guardada a sessionStorage en carregar la pàgina
  // - fallback de single-tenant (sense selector manual)
  // - mode multi-tenant amb "Totes les organitzacions" (header fora)
  useEffect(() => {
    setTenantScopeReady(false)

    if (selectedTenantId) {
      setActiveTenantId(selectedTenantId)
      setTenantScopeReady(true)
      return
    }

    if (!tenantsLoading && tenants.length === 1) {
      setActiveTenantId(tenants[0].id)
      setTenantScopeReady(true)
      return
    }

    setActiveTenantId(null)
    if (!tenantsLoading) {
      setTenantScopeReady(true)
    }
  }, [selectedTenantId, tenants, tenantsLoading])

  return (
    <TenantContext.Provider
      value={{
        tenants,
        tenantsLoading,
        selectedTenantId,
        setSelectedTenantId,
        activeTenant,
        activeRole,
        sites: visibleSites,
        sitesLoading,
        canUseAllSites,
        isSingleSiteContext,
        selectedSiteId,
        setSelectedSiteId,
        activeSite,
        activeSiteRole,
        tenantScopeReady,
      }}
    >
      {children}
    </TenantContext.Provider>
  )
}

export function useTenant() {
  const ctx = useContext(TenantContext)
  if (!ctx) throw new Error('useTenant must be used within a TenantProvider')
  return ctx
}
