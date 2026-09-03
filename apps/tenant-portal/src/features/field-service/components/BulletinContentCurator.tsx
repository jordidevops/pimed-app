import { useTranslation } from 'react-i18next'
import { Label } from '@/components/ui/label'
import type {
  BulletinChecklistCandidate,
  BulletinContentCandidates,
  BulletinContentSelection,
  BulletinMaterialCandidate,
  BulletinTaskCandidate,
} from '../api/customerInterventionReportsService'

type ShowMode = 'inherit' | 'on' | 'off'

type Props = {
  candidates: BulletinContentCandidates | undefined
  loading?: boolean
  disabled?: boolean
  selection: BulletinContentSelection
  showChecklistsMode: ShowMode
  showTasksMode: ShowMode
  showMaterialsMode: ShowMode
  effectiveShowChecklists: boolean
  effectiveShowTasks: boolean
  effectiveShowMaterials: boolean
  onShowChecklistsMode: (mode: ShowMode) => void
  onShowTasksMode: (mode: ShowMode) => void
  onShowMaterialsMode: (mode: ShowMode) => void
  onToggleChecklistItem: (id: string) => void
  onToggleTask: (id: string) => void
  onToggleMaterial: (id: string) => void
}

function ShowModeSelect({
  id,
  label,
  value,
  tenantDefault,
  disabled,
  onChange,
}: {
  id: string
  label: string
  value: ShowMode
  tenantDefault: boolean
  disabled?: boolean
  onChange: (m: ShowMode) => void
}) {
  const { t } = useTranslation('field-service')
  return (
    <div className="space-y-1">
      <Label htmlFor={id}>{label}</Label>
      <select
        id={id}
        className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
        value={value}
        disabled={disabled}
        onChange={(e) => onChange(e.target.value as ShowMode)}
      >
        <option value="inherit">
          {t('bulletin.content_inherit', 'Segons configuració del portal')} (
          {tenantDefault
            ? t('bulletin.content_on', 'sí')
            : t('bulletin.content_off', 'no')}
          )
        </option>
        <option value="on">{t('bulletin.content_force_on', 'Mostrar sempre')}</option>
        <option value="off">{t('bulletin.content_force_off', 'Amagar sempre')}</option>
      </select>
    </div>
  )
}

function checklistStatusMessage(params: {
  t: (key: string, fallback: string, opts?: Record<string, unknown>) => string
  effectiveShow: boolean
  items: BulletinChecklistCandidate[]
  selectedCount: number
}): string {
  if (!params.effectiveShow) {
    return params.t(
      'bulletin.checklist_status_hidden',
      'No es mostraran checklists: la secció està desactivada per a aquest butlletí (o per la configuració del portal).',
    )
  }
  if (params.items.length === 0) {
    return params.t(
      'bulletin.checklist_status_none',
      'No hi ha ítems de checklist en aquest projecte. Completa o afegeix checklists a la visita.',
    )
  }
  if (params.selectedCount === 0) {
    return params.t(
      'bulletin.checklist_status_none_selected',
      'Hi ha {{total}} ítems, però cap està marcat per al butlletí. Marca’n com a mínim un (per defecte només els amb «incloure al report» de la plantilla).',
      { total: params.items.length },
    )
  }
  return params.t(
    'bulletin.checklist_status_ok',
    'Es mostraran {{selected}} de {{total}} ítems de checklist.',
    { selected: params.selectedCount, total: params.items.length },
  )
}

function tasksStatusMessage(params: {
  t: (key: string, fallback: string, opts?: Record<string, unknown>) => string
  effectiveShow: boolean
  items: BulletinTaskCandidate[]
  selectedCount: number
}): string {
  if (!params.effectiveShow) {
    return params.t(
      'bulletin.tasks_status_hidden',
      'No es mostraran tasques: la secció està desactivada per a aquest butlletí (o per la configuració del portal).',
    )
  }
  if (params.items.length === 0) {
    return params.t(
      'bulletin.tasks_status_none',
      'No hi ha tasques en aquest projecte.',
    )
  }
  if (params.selectedCount === 0) {
    return params.t(
      'bulletin.tasks_status_none_selected',
      'Hi ha {{total}} tasques, però cap està marcada per al butlletí.',
      { total: params.items.length },
    )
  }
  return params.t(
    'bulletin.tasks_status_ok',
    'Es mostraran {{selected}} de {{total}} tasques.',
    { selected: params.selectedCount, total: params.items.length },
  )
}

function materialsStatusMessage(params: {
  t: (key: string, fallback: string, opts?: Record<string, unknown>) => string
  effectiveShow: boolean
  items: BulletinMaterialCandidate[]
  selectedCount: number
}): string {
  if (!params.effectiveShow) {
    return params.t(
      'bulletin.materials_status_hidden',
      'No es mostraran materials: la secció està desactivada per a aquest butlletí (o per la configuració del portal).',
    )
  }
  if (params.items.length === 0) {
    return params.t(
      'bulletin.materials_status_none',
      'No hi ha materials en aquest projecte.',
    )
  }
  if (params.selectedCount === 0) {
    return params.t(
      'bulletin.materials_status_none_selected',
      'Hi ha {{total}} materials, però cap està marcat per al butlletí.',
      { total: params.items.length },
    )
  }
  return params.t(
    'bulletin.materials_status_ok',
    'Es mostraran {{selected}} de {{total}} materials.',
    { selected: params.selectedCount, total: params.items.length },
  )
}

function formatMaterialQty(m: BulletinMaterialCandidate): string {
  const qty = m.quantity
  const unit = typeof m.unit === 'string' ? m.unit.trim() : ''
  if (qty == null) return unit
  return unit ? `${qty} ${unit}` : String(qty)
}

export function BulletinContentCurator({
  candidates,
  loading,
  disabled,
  selection,
  showChecklistsMode,
  showTasksMode,
  showMaterialsMode,
  effectiveShowChecklists,
  effectiveShowTasks,
  effectiveShowMaterials,
  onShowChecklistsMode,
  onShowTasksMode,
  onShowMaterialsMode,
  onToggleChecklistItem,
  onToggleTask,
  onToggleMaterial,
}: Props) {
  const { t } = useTranslation('field-service')
  const items = candidates?.checklist_items ?? []
  const tasks = candidates?.tasks ?? []
  const materials = candidates?.materials ?? []
  const selectedChecklist = new Set(selection.checklist_run_item_ids)
  const selectedTasks = new Set(selection.task_ids)
  const selectedMaterials = new Set(selection.material_ids)

  return (
    <div className="space-y-4 rounded-xl border border-border p-4">
      <div>
        <h4 className="text-sm font-semibold">
          {t('bulletin.content_title', 'Contingut del butlletí')}
        </h4>
        <p className="mt-1 text-xs text-muted-foreground">
          {t(
            'bulletin.content_hint',
            'Tria si es mostren checklists, tasques i materials, i quins ítems. La decisió es conserva a l’esborrany.',
          )}
        </p>
      </div>

      <div className="grid gap-3 sm:grid-cols-3">
        <ShowModeSelect
          id="bulletin-show-checklists"
          label={t('bulletin.show_checklists', 'Mostrar checklists')}
          value={showChecklistsMode}
          tenantDefault={candidates?.tenant_show_checklists !== false}
          disabled={disabled || loading}
          onChange={onShowChecklistsMode}
        />
        <ShowModeSelect
          id="bulletin-show-tasks"
          label={t('bulletin.show_tasks', 'Mostrar tasques')}
          value={showTasksMode}
          tenantDefault={candidates?.tenant_show_tasks !== false}
          disabled={disabled || loading}
          onChange={onShowTasksMode}
        />
        <ShowModeSelect
          id="bulletin-show-materials"
          label={t('bulletin.show_materials', 'Mostrar materials')}
          value={showMaterialsMode}
          tenantDefault={candidates?.tenant_show_materials !== false}
          disabled={disabled || loading}
          onChange={onShowMaterialsMode}
        />
      </div>

      <div className="space-y-2">
        <Label>{t('bulletin.checklist_items', 'Ítems de checklist')}</Label>
        <p className="text-xs text-muted-foreground">
          {checklistStatusMessage({
            t: t as never,
            effectiveShow: effectiveShowChecklists,
            items,
            selectedCount: selection.checklist_run_item_ids.length,
          })}
        </p>
        {loading ? (
          <p className="text-xs text-muted-foreground">{t('bulletin.content_loading', 'Carregant…')}</p>
        ) : items.length === 0 ? null : (
          <ul className="max-h-48 space-y-1.5 overflow-y-auto rounded-lg border border-border p-2">
            {items.map((item) => {
              const id = String(item.id)
              return (
                <li key={id}>
                  <label
                    className={`flex cursor-pointer items-start gap-2 text-sm ${
                      !effectiveShowChecklists ? 'opacity-50' : ''
                    }`}
                  >
                    <input
                      type="checkbox"
                      className="mt-1"
                      checked={selectedChecklist.has(id)}
                      disabled={disabled || !effectiveShowChecklists}
                      onChange={() => onToggleChecklistItem(id)}
                    />
                    <span className="min-w-0 flex-1">
                      <span className="font-medium">{item.title || id.slice(0, 8)}</span>
                      {item.include_in_report !== true && (
                        <span className="ml-2 text-xs text-muted-foreground">
                          (
                          {t(
                            'bulletin.checklist_template_off',
                            'plantilla: no al report',
                          )}
                          )
                        </span>
                      )}
                      {item.run_name ? (
                        <span className="mt-0.5 block text-xs text-muted-foreground">
                          {item.run_name}
                        </span>
                      ) : null}
                    </span>
                  </label>
                </li>
              )
            })}
          </ul>
        )}
      </div>

      <div className="space-y-2">
        <Label>{t('bulletin.task_items', 'Tasques')}</Label>
        <p className="text-xs text-muted-foreground">
          {tasksStatusMessage({
            t: t as never,
            effectiveShow: effectiveShowTasks,
            items: tasks,
            selectedCount: selection.task_ids.length,
          })}
        </p>
        {loading ? null : tasks.length === 0 ? null : (
          <ul className="max-h-48 space-y-1.5 overflow-y-auto rounded-lg border border-border p-2">
            {tasks.map((task) => {
              const id = String(task.id)
              return (
                <li key={id}>
                  <label
                    className={`flex cursor-pointer items-start gap-2 text-sm ${
                      !effectiveShowTasks ? 'opacity-50' : ''
                    }`}
                  >
                    <input
                      type="checkbox"
                      className="mt-1"
                      checked={selectedTasks.has(id)}
                      disabled={disabled || !effectiveShowTasks}
                      onChange={() => onToggleTask(id)}
                    />
                    <span className="min-w-0 flex-1">
                      <span className="font-medium">{task.title || id.slice(0, 8)}</span>
                      {task.status ? (
                        <span className="ml-2 text-xs text-muted-foreground">{task.status}</span>
                      ) : null}
                    </span>
                  </label>
                </li>
              )
            })}
          </ul>
        )}
      </div>

      <div className="space-y-2">
        <Label>{t('bulletin.material_items', 'Materials')}</Label>
        <p className="text-xs text-muted-foreground">
          {materialsStatusMessage({
            t: t as never,
            effectiveShow: effectiveShowMaterials,
            items: materials,
            selectedCount: selection.material_ids.length,
          })}
        </p>
        {loading ? null : materials.length === 0 ? null : (
          <ul className="max-h-48 space-y-1.5 overflow-y-auto rounded-lg border border-border p-2">
            {materials.map((material) => {
              const id = String(material.id)
              const qty = formatMaterialQty(material)
              return (
                <li key={id}>
                  <label
                    className={`flex cursor-pointer items-start gap-2 text-sm ${
                      !effectiveShowMaterials ? 'opacity-50' : ''
                    }`}
                  >
                    <input
                      type="checkbox"
                      className="mt-1"
                      checked={selectedMaterials.has(id)}
                      disabled={disabled || !effectiveShowMaterials}
                      onChange={() => onToggleMaterial(id)}
                    />
                    <span className="min-w-0 flex-1">
                      <span className="font-medium">{material.name || id.slice(0, 8)}</span>
                      {qty ? (
                        <span className="ml-2 text-xs text-muted-foreground">{qty}</span>
                      ) : null}
                    </span>
                  </label>
                </li>
              )
            })}
          </ul>
        )}
      </div>
    </div>
  )
}

export type { ShowMode }
