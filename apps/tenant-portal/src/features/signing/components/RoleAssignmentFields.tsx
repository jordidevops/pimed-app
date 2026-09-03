import { useTranslation } from 'react-i18next'
import { useMemo } from 'react'
import { Building2, User, X as XIcon } from 'lucide-react'
import { Input } from '@/components/ui/input'
import { useJobPositions } from '@/features/employees/api/useJobPositions'
import { jobPlaceName } from '@/features/employees/utils/jobPlaceName'
import type { SigningRoleDef } from '../api/signingService'
import {
  type RoleAssignment,
  canToggleInputMode,
  cyclePickerType,
  clearedAssignmentFields,
  getEffectivePickerType,
  isFixedContextType,
} from '../utils/roleAssignmentUtils'

type EmployeeRow = {
  id: string | null
  full_name?: string | null
  email?: string | null
  job_position_id?: string | null
  document_id?: string | null
  phone?: string | null
}
type ContactRow = { id: string | null; display_name?: string | null; email?: string | null }
type CatalogRow = { id: string | null; name?: string | null; sku?: string | null; kind?: string | null; unit?: string | null }

export interface RoleAssignmentFieldsProps {
  assignment:     RoleAssignment
  roleDef?:         SigningRoleDef
  search:           string
  onSearchChange:   (value: string) => void
  onUpdate:         (patch: Partial<RoleAssignment>) => void
  onSelectEntity:   (data: { name: string; email: string; entityId?: string; entityType: string; extra?: Record<string, string> }) => void
  onClear:          () => void
  employees:        EmployeeRow[]
  contacts:         ContactRow[]
  catalogItems:     CatalogRow[]
  activeTenant?:    { id?: string; name?: string } | null
  linkedVarKeys?:   string[]
  layout?:          'card' | 'inline'
}

export function RoleAssignmentFields({
  assignment: ra,
  roleDef,
  search,
  onSearchChange,
  onUpdate,
  onSelectEntity,
  onClear,
  employees,
  contacts,
  catalogItems,
  activeTenant,
  linkedVarKeys = [],
  layout = 'card',
}: RoleAssignmentFieldsProps) {
  const { t } = useTranslation('signing')
  const { data: jobPositions = [] } = useJobPositions(true)
  const positionsById = useMemo(
    () => Object.fromEntries(jobPositions.filter((p) => p.id).map((p) => [p.id!, p])),
    [jobPositions],
  )
  const templateEntityType = roleDef?.entity_type ?? 'person'
  const toggleable = canToggleInputMode(roleDef)
  const isManual = toggleable && ra.inputMode === 'manual'
  const effectiveType = toggleable
    ? getEffectivePickerType(ra, roleDef)
    : templateEntityType

  const filteredEmployees = employees.filter(e =>
    !search || (e.full_name ?? '').toLowerCase().includes(search.toLowerCase()) || (e.email ?? '').toLowerCase().includes(search.toLowerCase())
  ).slice(0, 6)

  const filteredContacts = contacts.filter(c =>
    !search || (c.display_name ?? '').toLowerCase().includes(search.toLowerCase()) || (c.email ?? '').toLowerCase().includes(search.toLowerCase())
  ).slice(0, 6)

  const filteredCatalog = catalogItems.filter(ci =>
    !search || (ci.name ?? '').toLowerCase().includes(search.toLowerCase()) || (ci.sku ?? '').toLowerCase().includes(search.toLowerCase())
  ).slice(0, 6)

  function handleBadgeClick() {
    if (!toggleable) return
    const current = isManual ? 'user' : effectiveType
    const next = cyclePickerType(current)
    const keepValues = next.inputMode === 'manual' && (ra.name.trim() || (ra.email.trim() && ra.email !== '__tenant__'))
    onUpdate(keepValues
      ? { ...next, entity_id: undefined, entity_type: undefined, extra: undefined }
      : { ...next, ...clearedAssignmentFields() })
    onSearchChange('')
  }

  function handleToggleMode() {
    if (!toggleable) return
    if (isManual) {
      onUpdate({
        inputMode: 'entity',
        pickerEntityType: ra.pickerEntityType ?? 'employee',
        ...clearedAssignmentFields(),
      })
    } else {
      // Mantenir nom i correu de l'entitat seleccionada per poder editar-los
      onUpdate({
        inputMode: 'manual',
        entity_id: undefined,
        entity_type: undefined,
        extra: undefined,
      })
    }
    onSearchChange('')
  }

  function badgeLabel(): string {
    if (isManual) return t('orchestrator.entity_manual', 'Manual')
    return t(`orchestrator.entity_${effectiveType}`, effectiveType)
  }

  function clearSelection() {
    onClear()
    onSearchChange('')
  }

  const hasSelection = !!(ra.email && ra.email !== '__tenant__')

  const header = (
    <div className="flex items-center gap-2 flex-wrap">
      {layout === 'card' && <User className="h-4 w-4 text-indigo-600 shrink-0" />}
      <span className={`font-medium text-sm ${layout === 'inline' ? 'truncate' : ''}`}>
        {roleDef?.label ?? ra.roleName}
      </span>
      {roleDef?.for_signing !== false && (
        <span className="text-[9px] uppercase bg-green-100 text-green-700 px-1 py-0.5 rounded font-semibold">
          {t('orchestrator.roleSigns', 'Signa')}
        </span>
      )}
      {toggleable ? (
        <button
          type="button"
          onClick={handleBadgeClick}
          title={t('orchestrator.cycleEntityType', 'Canviar tipus d\'entitat')}
          className="ml-auto text-[10px] uppercase bg-indigo-100 text-indigo-700 hover:bg-indigo-200 px-1.5 py-0.5 rounded font-semibold transition-colors cursor-pointer"
        >
          {badgeLabel()}
        </button>
      ) : (
        <span className="ml-auto text-[10px] uppercase bg-indigo-100 text-indigo-700 px-1.5 py-0.5 rounded font-semibold">
          {t(`orchestrator.entity_${templateEntityType}`, templateEntityType)}
        </span>
      )}
      {layout === 'inline' && hasSelection && (
        <button type="button" onClick={clearSelection} className="text-muted-foreground hover:text-destructive" title={t('orchestrator.clearSelection', 'Netejar')}>
          <XIcon className="h-3 w-3" />
        </button>
      )}
    </div>
  )

  const modeToggle = toggleable && (
    <button
      type="button"
      onClick={handleToggleMode}
      className="text-[11px] text-indigo-600 hover:text-indigo-800 hover:underline text-left"
    >
      {isManual
        ? t('orchestrator.switchToEntity', 'Cercar a la base de dades')
        : t('orchestrator.switchToManual', 'Introduir correu i nom manualment')}
    </button>
  )

  // ── Fixed context types ────────────────────────────────────────────────────
  if (isFixedContextType(templateEntityType)) {
    if (templateEntityType === 'tenant') {
      return (
        <div className={layout === 'card' ? 'rounded-lg border p-3 space-y-2 bg-muted/10' : 'space-y-1'}>
          {header}
          <div className="flex items-center gap-2 px-2 py-1.5 rounded bg-muted/30 text-xs text-muted-foreground">
            <Building2 className="h-3.5 w-3.5 shrink-0 text-indigo-500" />
            <span>{t('orchestrator.tenantAutoResolved', 'Resolt automàticament: empresa actual')}</span>
            {activeTenant?.name && <span className="ml-1 font-medium text-foreground">{activeTenant.name}</span>}
          </div>
        </div>
      )
    }

    if (templateEntityType === 'catalog_item') {
      return (
        <div className={layout === 'card' ? 'rounded-lg border p-3 space-y-2 bg-muted/10' : 'space-y-1'}>
          {header}
          {ra.entity_id ? (
            <div className="flex items-center gap-1.5 text-xs bg-indigo-50 border border-indigo-200 rounded px-2 py-1">
              <Building2 className="h-3 w-3 text-indigo-600 shrink-0" />
              <span className="font-medium truncate">{ra.name}</span>
              {ra.extra?.sku && <span className="text-muted-foreground font-mono">{ra.extra.sku}</span>}
            </div>
          ) : (
            <>
              <Input
                placeholder={t('orchestrator.searchCatalogItem', 'Cercar producte/servei...')}
                value={search}
                onChange={e => onSearchChange(e.target.value)}
                className="h-7 text-xs"
              />
              {search && (
                filteredCatalog.length === 0
                  ? <p className="text-xs text-muted-foreground px-2 py-1">{t('orchestrator.noResults', 'Sense resultats')}</p>
                  : (
                    <div className="border rounded bg-background shadow-sm max-h-28 overflow-y-auto">
                      {filteredCatalog.map(ci => (
                        <button key={ci.id ?? ci.sku ?? ci.name} type="button"
                          onClick={() => ci.id && onSelectEntity({ name: ci.name ?? '', email: '', entityId: ci.id, entityType: 'catalog_item', extra: { sku: ci.sku ?? '', kind: ci.kind ?? '', unit: ci.unit ?? '' } })}
                          className="w-full text-left text-xs px-2 py-1.5 hover:bg-accent/50 flex items-center gap-2">
                          <span className={`text-[9px] px-1 py-0.5 rounded font-bold shrink-0 ${ci.kind === 'service' ? 'bg-purple-100 text-purple-700' : 'bg-orange-100 text-orange-700'}`}>
                            {ci.kind === 'service' ? 'S' : 'P'}
                          </span>
                          <span className="font-medium truncate">{ci.name}</span>
                          {ci.sku && <span className="text-muted-foreground font-mono shrink-0">{ci.sku}</span>}
                        </button>
                      ))}
                    </div>
                  )
              )}
            </>
          )}
        </div>
      )
    }

    // site / asset
    return (
      <div className={layout === 'card' ? 'rounded-lg border p-3 space-y-2 bg-muted/10' : 'space-y-1'}>
        {header}
        <p className="text-[10px] text-muted-foreground">
          {t('orchestrator.contextEntityIdLabel', 'ID d\'entitat (UUID) — necessari per resoldre variables path-based')}
        </p>
        <Input
          placeholder="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
          value={ra.entity_id ?? ''}
          onChange={e => onUpdate({ entity_id: e.target.value.trim() || undefined, entity_type: templateEntityType })}
          className="h-7 text-xs font-mono"
        />
      </div>
    )
  }

  // ── Manual mode ────────────────────────────────────────────────────────────
  if (isManual) {
    return (
      <div className={layout === 'card' ? 'rounded-lg border p-3 space-y-2 bg-muted/10' : 'space-y-1'}>
        {header}
        {modeToggle}
        <Input
          placeholder={t('orchestrator.signers_name', 'Nom')}
          value={ra.name}
          onChange={e => onUpdate({ name: e.target.value })}
          className="h-7 text-xs"
        />
        <Input
          type="email"
          placeholder={t('orchestrator.signers_email', 'Email del signant')}
          value={ra.email}
          onChange={e => onUpdate({ email: e.target.value })}
          className="h-7 text-xs"
        />
        {linkedVarKeys.length > 0 && (
          <p className="text-[10px] text-muted-foreground">
            {t('orchestrator.autoFillVars', 'Variables auto-omplides: {{keys}}', { keys: linkedVarKeys.join(', ') })}
          </p>
        )}
      </div>
    )
  }

  // ── Entity picker mode ─────────────────────────────────────────────────────
  const pickerInput = (
    <Input
      placeholder={
        effectiveType === 'employee' ? t('orchestrator.searchEmployee', 'Cercar empleat...')
          : effectiveType === 'contact' ? t('orchestrator.searchContact', 'Cercar contacte...')
          : t('orchestrator.searchPerson', 'Cercar persona (empleat o contacte)...')
      }
      value={hasSelection ? `${ra.name} <${ra.email}>` : search}
      onChange={e => {
        if (hasSelection) clearSelection()
        onSearchChange(e.target.value)
      }}
      className="h-7 text-xs"
    />
  )

  const renderResults = () => {
    if (hasSelection || !search) return null

    const combined = effectiveType === 'employee'
      ? filteredEmployees.map(e => ({
          id: e.id, name: e.full_name ?? '', email: e.email ?? '', kind: 'employee' as const,
          extra: {
            job_title: jobPlaceName(e.job_position_id, positionsById) ?? '',
            document_id: e.document_id ?? '',
            phone: e.phone ?? '',
          },
        }))
      : effectiveType === 'contact'
        ? filteredContacts.map(c => ({
            id: c.id, name: c.display_name ?? '', email: c.email ?? '', kind: 'contact' as const, extra: {},
          }))
        : [
            ...filteredEmployees.map(e => ({
              id: e.id, name: e.full_name ?? '', email: e.email ?? '', kind: 'employee' as const,
              extra: {
                job_title: jobPlaceName(e.job_position_id, positionsById) ?? '',
                document_id: e.document_id ?? '',
                phone: e.phone ?? '',
              },
            })),
            ...filteredContacts.map(c => ({
              id: c.id, name: c.display_name ?? '', email: c.email ?? '', kind: 'contact' as const, extra: {},
            })),
          ].slice(0, 8)

    return (
      <div className="border rounded bg-background shadow-sm max-h-32 overflow-y-auto">
        {combined.length === 0
          ? <p className="text-xs text-muted-foreground px-2 py-1.5">{t('orchestrator.noResults', 'Sense resultats')}</p>
          : combined.map(p => (
            <button key={`${p.kind}-${p.id ?? p.email}`} type="button"
              onClick={() => p.id && onSelectEntity({ name: p.name, email: p.email, entityId: p.id, entityType: p.kind, extra: p.extra })}
              className="w-full text-left text-xs px-2 py-1.5 hover:bg-accent/50 flex items-center gap-2">
              {effectiveType === 'person' && (
                <span className={`text-[9px] px-1 py-0.5 rounded font-bold shrink-0 ${p.kind === 'employee' ? 'bg-blue-100 text-blue-700' : 'bg-green-100 text-green-700'}`}>
                  {p.kind === 'employee' ? t('orchestrator.badgeEmployee', 'E') : t('orchestrator.badgeContact', 'C')}
                </span>
              )}
              <span className="flex flex-col min-w-0">
                <span className="font-medium truncate">{p.name}</span>
                <span className="text-muted-foreground truncate">{p.email}</span>
              </span>
            </button>
          ))}
      </div>
    )
  }

  if (layout === 'inline' && hasSelection) {
    return (
      <div className="space-y-1">
        {header}
        {modeToggle}
        <div className="flex items-center gap-1.5 text-xs bg-indigo-50 border border-indigo-200 rounded px-2 py-1">
          <User className="h-3 w-3 text-indigo-600 shrink-0" />
          <span className="font-medium truncate">{ra.name}</span>
          <span className="text-muted-foreground truncate">{ra.email}</span>
        </div>
      </div>
    )
  }

  return (
    <div className={layout === 'card' ? 'rounded-lg border p-3 space-y-2 bg-muted/10' : 'space-y-1'}>
      {header}
      {modeToggle}
      <div className="space-y-1.5">
        {pickerInput}
        {renderResults()}
      </div>
      {linkedVarKeys.length > 0 && (
        <p className="text-[10px] text-muted-foreground">
          {t('orchestrator.autoFillVars', 'Variables auto-omplides: {{keys}}', { keys: linkedVarKeys.join(', ') })}
        </p>
      )}
    </div>
  )
}
