import { useEffect, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Plus, Trash2, Users, MapPin, Globe, Save } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useAuth } from '@/contexts/AuthContext'
import { useEmployees } from '@/features/employees/api/useEmployees'
import { useContacts } from '@/features/contacts/api/useContacts'
import { useUserProfiles } from '@/features/documents/api/useUserProfiles'
import { useSites } from '@/hooks/useSites'
import { useCatalogItems } from '@/features/catalog/api/useCatalogItems'
import { supabase } from '@/lib/supabase'
import {
  useTenantRoleDefaults,
  useUpsertRoleDefault,
  useDeleteRoleDefault,
  type TenantRoleDefault,
} from '../../features/signing/api/useTenantRoleDefaults'
import { ROLE_CATALOG, CONTEXT_AUTO_ROLE_KEYS } from '../../features/signing/constants/roleCatalog'

// Entity types que suporten selector de llista
const LIST_ENTITY_TYPES = ['employee', 'contact', 'user', 'person', 'site', 'asset', 'tenant', 'catalog_item'] as const
const ALL_ENTITY_TYPES  = ['employee', 'contact', 'user', 'person', 'site', 'asset', 'tenant', 'catalog_item'] as const

interface EntityOption {
  id:    string
  label: string
  email: string
}

// ─── EntityPicker ──────────────────────────────────────────────────────────

interface EntityPickerProps {
  entityType:     string
  selectedId:     string
  onSelect:       (opt: EntityOption) => void
  employees:      { id: string; full_name?: string | null; email?: string | null }[]
  contacts:       { id: string; display_name?: string | null; email?: string | null }[]
  users:          { id: string; full_name?: string | null; email?: string | null }[]
  sites:          { id: string; name?: string | null }[]
  assets:         { id: string; name?: string | null; asset_tag?: string | null; serial_number?: string | null }[]
  tenants:        { id: string; name?: string | null }[]
  catalogItems:   { id: string; name?: string | null; sku?: string | null }[]
  /** Mode text lliure (entity_types sense llista) */
  freeName:       string
  freeEmail:      string
  onFreeChange:   (field: 'name' | 'email', val: string) => void
}

function EntityPicker({ entityType, selectedId, onSelect, employees, contacts, users, sites, assets, tenants, catalogItems, freeName, freeEmail, onFreeChange }: EntityPickerProps) {
  const { t } = useTranslation('settings')
  const [search, setSearch] = useState('')

  if (!LIST_ENTITY_TYPES.includes(entityType as (typeof LIST_ENTITY_TYPES)[number])) {
    // Mode text lliure per a user/person/etc.
    return (
      <div className="flex gap-2 flex-1">
        <Input
          value={freeName}
          onChange={e => onFreeChange('name', e.target.value)}
          placeholder={t('signing.roleDefaults.namePlaceholder', 'Nom complet')}
          className="flex-1 h-8 text-sm"
        />
        <Input
          type="email"
          value={freeEmail}
          onChange={e => onFreeChange('email', e.target.value)}
          placeholder={t('signing.roleDefaults.emailPlaceholder', 'Email')}
          className="flex-1 h-8 text-sm"
        />
      </div>
    )
  }

  const options: EntityOption[] =
    entityType === 'employee'
      ? employees.filter(e => e.id != null).map(e => ({ id: e.id, label: e.full_name ?? e.id, email: e.email ?? '' }))
      : entityType === 'contact'
      ? contacts.filter(c => c.id != null).map(c => ({ id: c.id, label: c.display_name ?? c.id, email: c.email ?? '' }))
      : entityType === 'user'
      ? users.filter(u => u.id != null).map(u => ({ id: u.id, label: u.full_name ?? u.email ?? u.id, email: u.email ?? '' }))
      : entityType === 'site'
      ? sites.filter(s => s.id != null).map(s => ({ id: s.id, label: s.name ?? s.id, email: '' }))
      : entityType === 'asset'
      ? assets.filter(a => a.id != null).map(a => ({ id: a.id, label: a.name ?? a.asset_tag ?? a.serial_number ?? a.id, email: '' }))
      : entityType === 'tenant'
      ? tenants.filter(tn => tn.id != null).map(tn => ({ id: tn.id, label: tn.name ?? tn.id, email: '' }))
      : entityType === 'catalog_item'
      ? catalogItems.filter(ci => ci.id != null).map(ci => ({ id: ci.id!, label: ci.name ?? ci.id!, email: ci.sku ?? '' }))
      : entityType === 'person'
      ? [
          ...employees.filter(e => e.id != null).map(e => ({ id: e.id, label: e.full_name ?? e.id, email: e.email ?? '' })),
          ...contacts.filter(c => c.id != null).map(c => ({ id: c.id, label: c.display_name ?? c.id, email: c.email ?? '' })),
          ...users.filter(u => u.id != null).map(u => ({ id: u.id, label: u.full_name ?? u.email ?? u.id, email: u.email ?? '' })),
        ]
      : []

  const filtered = options.filter(o =>
    !search || o.label.toLowerCase().includes(search.toLowerCase()) || o.email.toLowerCase().includes(search.toLowerCase())
  )
  const selected = options.find(o => o.id === selectedId)
  const selectedText = selected ? (selected.email ? `${selected.label} <${selected.email}>` : selected.label) : ''

  return (
    <div className="flex gap-2 flex-1 items-center">
      <div className="relative flex-1">
        <Input
          value={search || selectedText}
          onChange={e => { setSearch(e.target.value) }}
          onFocus={e => { e.target.select(); setSearch('') }}
          placeholder={t('signing.roleDefaults.searchEntity', 'Cerca...')}
          className="h-8 text-sm"
        />
        {search && filtered.length > 0 && (
          <div className="absolute z-80 top-full left-0 right-0 mt-1 bg-popover border rounded-md shadow-md max-h-48 overflow-y-auto">
            {filtered.slice(0, 20).map(o => (
              <button
                key={o.id}
                type="button"
                className="w-full text-left px-3 py-1.5 text-sm hover:bg-accent"
                onClick={() => { onSelect(o); setSearch('') }}
              >
                <span className="font-medium">{o.label}</span>
                {o.email && <span className="ml-2 text-xs text-muted-foreground">{o.email}</span>}
              </button>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}

// ─── DefaultRow: fila de la taula ─────────────────────────────────────────

function DefaultRow({ item, canManage, onDelete }: { item: TenantRoleDefault; canManage: boolean; onDelete: () => void }) {
  const { t } = useTranslation('settings')
  const catalogEntry = item.role_key ? ROLE_CATALOG.find(r => r.key === item.role_key) : null
  const label = catalogEntry?.labels.ca ?? item.role_key

  return (
    <div className="flex items-center gap-3 px-3 py-2.5 border-b last:border-0 group">
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2">
          <span className="text-sm font-medium truncate">{label}</span>
          <span className="text-[10px] font-mono bg-muted px-1.5 py-0.5 rounded text-muted-foreground">{item.role_key}</span>
        </div>
        <div className="flex items-center gap-1.5 mt-0.5">
          <span className="text-[10px] uppercase bg-indigo-100 text-indigo-700 px-1.5 py-0.5 rounded font-semibold">{item.entity_type}</span>
          {item.entity_label && (
            <span className="text-xs text-muted-foreground truncate">{item.entity_label}</span>
          )}
          {item.entity_email && (
            <span className="text-xs text-muted-foreground truncate">&lt;{item.entity_email}&gt;</span>
          )}
          {!item.entity_id && (
            <span className="text-xs italic text-muted-foreground">{t('signing.roleDefaults.intentOnly', 'Intenció sense entitat')}</span>
          )}
        </div>
      </div>
      {canManage && (
        <button
          type="button"
          onClick={onDelete}
          className="opacity-0 group-hover:opacity-100 text-destructive hover:text-destructive/80 transition-opacity p-1 rounded"
          title={t('signing.roleDefaults.delete', 'Eliminar')}
        >
          <Trash2 className="h-3.5 w-3.5" />
        </button>
      )}
    </div>
  )
}

// ─── AddDefaultForm ────────────────────────────────────────────────────────

interface AddFormState {
  roleKey:     string
  entityType:  string
  entityId:    string
  entityLabel: string
  entityEmail: string
}

const EMPTY_FORM: AddFormState = { roleKey: '', entityType: 'employee', entityId: '', entityLabel: '', entityEmail: '' }

interface AddDefaultFormProps {
  tenantId:     string
  tenantName:   string
  canManage:    boolean
  existingKeys: string[]
  siteId?:      string | null
  employees:    { id: string; full_name?: string | null; email?: string | null }[]
  contacts:     { id: string; display_name?: string | null; email?: string | null }[]
  users:        { id: string; full_name?: string | null; email?: string | null }[]
  sites:        { id: string; name?: string | null }[]
  assets:       { id: string; name?: string | null; asset_tag?: string | null; serial_number?: string | null }[]
  catalogItems: { id: string; name?: string | null; sku?: string | null }[]
  onDone:       () => void
}

function AddDefaultForm({ tenantId, tenantName, canManage, existingKeys, siteId, employees, contacts, users, sites, assets, catalogItems, onDone }: AddDefaultFormProps) {
  const { t } = useTranslation('settings')
  const { toast } = useToast()
  const upsert = useUpsertRoleDefault()
  const [form, setForm] = useState<AddFormState>(EMPTY_FORM)

  const availableCatalogRoles = ROLE_CATALOG.filter(r => !existingKeys.includes(r.key))

  function handleEntitySelect(opt: { id: string; label: string; email: string }) {
    setForm(f => ({ ...f, entityId: opt.id, entityLabel: opt.label, entityEmail: opt.email }))
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!form.roleKey.trim()) {
      toast({ variant: 'destructive', description: t('signing.roleDefaults.errorRoleKeyRequired', 'La clau del rol és obligatòria') })
      return
    }
    try {
      await upsert.mutateAsync({
        tenantId,
        roleKey:     form.roleKey.trim(),
        entityType:  form.entityType,
        entityId:    form.entityId   || null,
        entityLabel: form.entityLabel || null,
        entityEmail: form.entityEmail || null,
        siteId:      siteId ?? null,
      })
      toast({ description: t('signing.roleDefaults.saved', 'Default de rol desat') })
      setForm(EMPTY_FORM)
      onDone()
    } catch {
      toast({
        variant: 'destructive',
        description: t('signing.roleDefaults.errorSave', 'No s\'ha pogut desar el default de rol'),
      })
    }
  }

  if (!canManage) return null

  return (
    <form onSubmit={handleSubmit} className="p-3 border-t bg-muted/20 space-y-3">
      {/* Pills ràpids del catàleg */}
      {availableCatalogRoles.length > 0 && (
        <div className="flex flex-wrap gap-1.5 items-center">
          <span className="text-xs text-muted-foreground">{t('signing.roleDefaults.quickAdd', 'Ràpid:')}</span>
          {availableCatalogRoles.slice(0, 8).map(r => (
            <button
              key={r.key}
              type="button"
              className="text-[11px] px-2 py-0.5 rounded-full border hover:bg-accent transition"
              onClick={() => setForm(f => ({ ...f, roleKey: r.key, entityType: r.entity_type }))}
            >
              {r.labels.ca}
            </button>
          ))}
        </div>
      )}

      <div className="flex flex-wrap gap-2 items-end">
        {/* role_key */}
        <div className="space-y-1">
          <label className="text-xs font-medium text-muted-foreground">{t('signing.roleDefaults.roleKey', 'Clau rol')}</label>
          <Input
            value={form.roleKey}
            onChange={e => setForm(f => ({ ...f, roleKey: e.target.value }))}
            placeholder={t('signing.roleDefaults.roleKeyPlaceholder', 'worker')}
            list="role-defaults-datalist"
            className="h-8 text-sm w-40"
            required
          />
          <datalist id="role-defaults-datalist">
            {ROLE_CATALOG.map(r => <option key={r.key} value={r.key} />)}
          </datalist>
        </div>

        {/* entity_type */}
        <div className="space-y-1">
          <label className="text-xs font-medium text-muted-foreground">{t('signing.roleDefaults.entityType', "Tipus d'entitat")}</label>
          <select
            value={form.entityType}
            onChange={e => setForm(f => ({ ...f, entityType: e.target.value, entityId: '', entityLabel: '', entityEmail: '' }))}
            className="h-8 text-sm border rounded-md px-2 bg-background"
          >
            {ALL_ENTITY_TYPES.map(et => (
              <option key={et} value={et}>{et}</option>
            ))}
          </select>
        </div>

        {/* Entity picker */}
        <div className="space-y-1 flex-1 min-w-50">
          <label className="text-xs font-medium text-muted-foreground">{t('signing.roleDefaults.entity', 'Entitat per defecte')}</label>
          <EntityPicker
            entityType={form.entityType}
            selectedId={form.entityId}
            onSelect={handleEntitySelect}
            employees={employees}
            contacts={contacts}
            users={users}
            sites={sites}
            assets={assets}
            tenants={[{ id: tenantId, name: tenantName }]}
            catalogItems={catalogItems}
            freeName={form.entityLabel}
            freeEmail={form.entityEmail}
            onFreeChange={(field, val) => setForm(f => ({
              ...f,
              entityLabel: field === 'name'  ? val : f.entityLabel,
              entityEmail: field === 'email' ? val : f.entityEmail,
            }))}
          />
        </div>

        <Button type="submit" size="sm" className="h-8" disabled={upsert.isPending}>
          <Save className="h-3.5 w-3.5 mr-1" />
          {t('signing.roleDefaults.saveBtn', 'Guardar')}
        </Button>
      </div>
    </form>
  )
}

// ─── SigningRoleDefaultsSection (component principal) ─────────────────────

export function SigningRoleDefaultsSection() {
  const { t }                                       = useTranslation('settings')
  const { activeTenant, activeRole, selectedSiteId } = useTenant()
  const { user }                                    = useAuth()
  const tenantId                                    = activeTenant?.id ?? ''
  const tenantName                                  = activeTenant?.name ?? ''
  const canManage                                   = activeRole === 'owner' || activeRole === 'manager'
  const { toast }                                   = useToast()
  const [showForm, setShowForm]                     = useState(false)
  // Site filter: null = global (tenant-wide), siteId = site-specific
  const [filterSiteId, setFilterSiteId]             = useState<string | null>(selectedSiteId ?? null)

  const { data: defaults = [], isLoading }  = useTenantRoleDefaults(tenantId || undefined)
  const deleteDefault                       = useDeleteRoleDefault()
  const { data: employees = [] }            = useEmployees()
  const { data: contacts  = [] }            = useContacts()
  const { data: users = [] }                = useUserProfiles()
  const { data: sites = [] }                = useSites(tenantId || null, user?.id, 'active')
  const { data: catalogItems = [] }         = useCatalogItems()
  const { data: assets = [] }               = useQuery<Array<{ id: string | null; name: string | null; asset_tag: string | null; serial_number: string | null }>>({
    queryKey: ['signing', 'role-default-assets', tenantId],
    enabled: !!tenantId,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('assets')
        .select('id, name, asset_tag, serial_number')
        .eq('tenant_id', tenantId)
        .order('name')
      if (error) throw error
      return data ?? []
    },
    staleTime: 5 * 60 * 1000,
  })

  if (!tenantId) return null

  async function handleDelete(item: TenantRoleDefault) {
    if (!item.id || !item.tenant_id) return
    try {
      await deleteDefault.mutateAsync({ id: item.id, tenantId: item.tenant_id })
      toast({ description: t('signing.roleDefaults.deleted', 'Default de rol eliminat') })
    } catch {
      toast({
        variant: 'destructive',
        description: t('signing.roleDefaults.errorDelete', 'No s\'ha pogut eliminar el default de rol'),
      })
    }
  }

  // Filtered defaults per site context
  const filteredDefaults = defaults.filter(d => {
    return filterSiteId ? (d.site_id === filterSiteId) : (!d.site_id)
  })

  const existingKeys = filteredDefaults.map(d => d.role_key ?? '').filter(Boolean)

  // Build unified list: all catalog roles + configured extras
  const catalogRoleKeys = new Set(ROLE_CATALOG.map(r => r.key))
  // Extra configured roles not in catalog (rare)
  const extraDefaults = filteredDefaults.filter(d => d.role_key && !catalogRoleKeys.has(d.role_key))

  useEffect(() => {
    setFilterSiteId(selectedSiteId ?? null)
  }, [selectedSiteId, tenantId])

  return (
    <section className="rounded-2xl border bg-card">
      {/* Header */}
      <div className="flex items-center justify-between px-5 py-4 border-b">
        <div className="flex items-center gap-2">
          <Users className="h-4 w-4 text-indigo-500" />
          <h3 className="text-base font-semibold text-foreground">
            {t('signing.roleDefaults.title', 'Rols per defecte')}
          </h3>
        </div>
        {canManage && !showForm && (
          <Button variant="outline" size="sm" className="h-7 gap-1" onClick={() => setShowForm(true)}>
            <Plus className="h-3.5 w-3.5" />
            {t('signing.roleDefaults.addBtn', 'Afegir')}
          </Button>
        )}
      </div>

      {/* Descripció */}
      <p className="text-sm text-muted-foreground px-5 py-3 border-b">
        {t('signing.roleDefaults.description', 'Define quina persona ocupa cada rol per defecte en generar un document. L\'assignació manual durant el procés sempre té prioritat.')}
      </p>

      {/* Site context selector */}
      {sites.length > 0 && (
        <div className="flex items-center gap-2 px-5 py-2.5 border-b bg-muted/20">
          <span className="text-xs text-muted-foreground shrink-0">{t('signing.roleDefaults.context', 'Context:')}</span>
          <div className="flex flex-wrap gap-1.5">
            <button
              type="button"
              onClick={() => setFilterSiteId(null)}
              className={`flex items-center gap-1 text-xs px-2.5 py-1 rounded-full border transition ${!filterSiteId ? 'bg-indigo-600 text-white border-indigo-600' : 'hover:bg-accent'}`}
            >
              <Globe className="h-3 w-3" />
              {t('signing.roleDefaults.globalContext', 'Tenant global')}
            </button>
            {sites.map(s => (
              <button
                key={s.id}
                type="button"
                onClick={() => setFilterSiteId(s.id)}
                className={`flex items-center gap-1 text-xs px-2.5 py-1 rounded-full border transition ${filterSiteId === s.id ? 'bg-indigo-600 text-white border-indigo-600' : 'hover:bg-accent'}`}
              >
                <MapPin className="h-3 w-3" />
                {s.name ?? s.id}
              </button>
            ))}
          </div>
        </div>
      )}

      {/* Formulari d'alta — damunt de la llista per visibilitat immediata */}
      {showForm && (
        <AddDefaultForm
          tenantId={tenantId}
          tenantName={tenantName}
          canManage={canManage}
          existingKeys={existingKeys}
          siteId={filterSiteId}
          employees={employees.filter(e => e.id != null) as { id: string; full_name?: string | null; email?: string | null }[]}
          contacts={contacts.filter(c => c.id != null) as { id: string; display_name?: string | null; email?: string | null }[]}
          users={users.filter(u => u.id != null) as { id: string; full_name?: string | null; email?: string | null }[]}
          sites={sites.map(s => ({ id: s.id, name: s.name }))}
          assets={assets.filter(a => a.id != null).map(a => ({ id: a.id as string, name: a.name, asset_tag: a.asset_tag, serial_number: a.serial_number }))}
          catalogItems={catalogItems.filter(ci => ci.id != null).map(ci => ({ id: ci.id!, name: ci.name, sku: ci.sku }))}
          onDone={() => setShowForm(false)}
        />
      )}

      {/* Llista de rols del catàleg (tots, configurats i no) */}
      {isLoading ? (
        <div className="px-5 py-4 space-y-2">
          {[1, 2, 3].map(i => <div key={i} className="h-10 bg-muted rounded animate-pulse" />)}
        </div>
      ) : (
        <div>
          {ROLE_CATALOG.map(catalogRole => {
            const configured = filteredDefaults.find(d => d.role_key === catalogRole.key)
            const isContextResolved = CONTEXT_AUTO_ROLE_KEYS.has(catalogRole.key)

            return (
              <div key={catalogRole.key} className="flex items-center gap-3 px-4 py-2.5 border-b last:border-0 group">
                {/* Info rol */}
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2 flex-wrap">
                    <span className="text-sm font-medium">{catalogRole.labels.ca}</span>
                    <span className="text-[10px] font-mono bg-muted px-1.5 py-0.5 rounded text-muted-foreground">{catalogRole.key}</span>
                    <span className="text-[10px] uppercase bg-violet-100 text-violet-700 px-1.5 py-0.5 rounded font-semibold">{catalogRole.entity_type}</span>
                  </div>
                  {configured ? (
                    <div className="flex items-center gap-1.5 mt-0.5">
                      {configured.site_id ? (
                        <span className="text-[10px] bg-orange-100 text-orange-700 px-1.5 py-0.5 rounded font-semibold flex items-center gap-0.5">
                          <MapPin className="h-2.5 w-2.5" />
                          {t('signing.roleDefaults.siteSpecific', 'Site')}
                        </span>
                      ) : (
                        <span className="text-[10px] bg-blue-100 text-blue-700 px-1.5 py-0.5 rounded font-semibold flex items-center gap-0.5">
                          <Globe className="h-2.5 w-2.5" />
                          {t('signing.roleDefaults.global', 'Global')}
                        </span>
                      )}
                      {configured.entity_label && (
                        <span className="text-xs text-foreground truncate">{configured.entity_label}</span>
                      )}
                      {configured.entity_email && (
                        <span className="text-xs text-muted-foreground">&lt;{configured.entity_email}&gt;</span>
                      )}
                    </div>
                  ) : isContextResolved ? (
                    <div className="mt-0.5">
                      <span className="text-[10px] bg-emerald-100 text-emerald-700 px-1.5 py-0.5 rounded font-semibold italic">
                        {t('signing.roleDefaults.contextResolved', 'Es resoldrà del context')}
                      </span>
                    </div>
                  ) : (
                    <div className="mt-0.5">
                      <span className="text-[10px] text-muted-foreground italic">
                        {t('signing.roleDefaults.notConfigured', 'Sense default')}
                      </span>
                    </div>
                  )}
                </div>

                {/* Acció: eliminar si configurat */}
                {canManage && configured && (
                  <button
                    type="button"
                    onClick={() => handleDelete(configured)}
                    className="opacity-0 group-hover:opacity-100 text-destructive hover:text-destructive/80 transition-opacity p-1 rounded"
                    title={t('signing.roleDefaults.delete', 'Eliminar')}
                  >
                    <Trash2 className="h-3.5 w-3.5" />
                  </button>
                )}
              </div>
            )
          })}

          {/* Rols configurats fora del catàleg */}
          {extraDefaults.map(item => (
            <DefaultRow
              key={item.id}
              item={item}
              canManage={canManage}
              onDelete={() => handleDelete(item)}
            />
          ))}
        </div>
      )}

    </section>
  )
}
