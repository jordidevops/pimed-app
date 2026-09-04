import { useCallback, useEffect, useMemo, useRef, useState, Fragment } from 'react'
import { Link, Navigate, useSearchParams } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import {
  DndContext,
  DragOverlay,
  PointerSensor,
  closestCorners,
  useDraggable,
  useDroppable,
  useSensor,
  useSensors,
  type DragEndEvent,
  type DragOverEvent,
  type DragStartEvent,
} from '@dnd-kit/core'
import {
  SortableContext,
  arrayMove,
  useSortable,
  verticalListSortingStrategy,
} from '@dnd-kit/sortable'
import { CSS } from '@dnd-kit/utilities'
import { AlertTriangle, Eye, EyeOff, GripVertical, Highlighter, Plus, Trash2, ArrowLeft, Eraser } from 'lucide-react'
import { useToast } from '@/hooks/use-toast'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { cn } from '@/lib/utils'
import {
  buildDefaultNavLayout,
  countNavItems,
  listAvailableCatalogEntries,
  NAV_CATALOG_BY_ID,
  PINNED_SECTION_ID,
  resolveItemLabel,
  sanitizeLayoutAgainstCatalog,
  sidebarNavSchema,
  SidebarMenuPreview,
  isNavItemAllowed,
  useSidebarNav,
  type NavCatalogEntry,
  type NavItemId,
  type SidebarNavGroupV1,
  type SidebarNavItemV1,
  type SidebarNavScope,
  type SidebarNavV1,
} from '@/features/sidebar-nav'

type DragData =
  | { type: 'group'; groupId: string }
  | { type: 'item'; groupId: string; itemId: string }
  | { type: 'available'; itemId: string }
  | { type: 'group-drop'; groupId: string }

function newGroupId() {
  return `custom_${crypto.randomUUID().slice(0, 8)}`
}

function layoutForScope(
  scope: SidebarNavScope,
  userLayout: SidebarNavV1 | null,
  tenantLayout: SidebarNavV1 | null,
): SidebarNavV1 {
  if (scope === 'user') return userLayout ?? tenantLayout ?? buildDefaultNavLayout()
  return tenantLayout ?? buildDefaultNavLayout()
}

function getItemsBucket(
  layout: SidebarNavV1,
  groupId: string,
): SidebarNavItemV1[] | null {
  if (groupId === PINNED_SECTION_ID) return layout.pinned.items
  return layout.groups.find((g) => g.id === groupId)?.items ?? null
}

function mapItemsInBucket(
  layout: SidebarNavV1,
  groupId: string,
  nextItems: SidebarNavItemV1[],
): SidebarNavV1 {
  if (groupId === PINNED_SECTION_ID) {
    return { ...layout, pinned: { ...layout.pinned, items: nextItems } }
  }
  return {
    ...layout,
    groups: layout.groups.map((g) => (g.id === groupId ? { ...g, items: nextItems } : g)),
  }
}

function SortableGroupHeader({
  groupId,
  children,
}: {
  groupId: string
  children: React.ReactNode
}) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({
    id: `group:${groupId}`,
    data: { type: 'group', groupId } satisfies DragData,
  })
  return (
    <div
      ref={setNodeRef}
      style={{ transform: CSS.Transform.toString(transform), transition }}
      className={cn('flex items-center gap-2', isDragging && 'opacity-60')}
    >
      <button
        type="button"
        className="shrink-0 cursor-grab touch-none text-muted-foreground hover:text-foreground"
        aria-label="Reorder section"
        {...attributes}
        {...listeners}
      >
        <GripVertical className="h-4 w-4" />
      </button>
      {children}
    </div>
  )
}

function SortableItemRow({
  groupId,
  itemId,
  children,
  lockTransform,
}: {
  groupId: string
  itemId: string
  children: React.ReactNode
  /** When true, ignore dnd-kit layout transforms (custom drop preview owns spacing). */
  lockTransform?: boolean
}) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({
    id: `item:${groupId}:${itemId}`,
    data: { type: 'item', groupId, itemId } satisfies DragData,
    animateLayoutChanges: lockTransform ? () => false : undefined,
  })
  return (
    <div
      ref={setNodeRef}
      style={{
        transform: lockTransform ? undefined : CSS.Transform.toString(transform),
        transition: lockTransform ? undefined : transition,
      }}
      className={cn(
        'flex items-start gap-2 rounded-lg border border-border bg-background p-2',
        isDragging && 'opacity-40',
      )}
    >
      <button
        type="button"
        className="mt-1.5 shrink-0 cursor-grab touch-none text-muted-foreground hover:text-foreground"
        aria-label="Reorder item"
        {...attributes}
        {...listeners}
      >
        <GripVertical className="h-4 w-4" />
      </button>
      <div className="min-w-0 flex-1">{children}</div>
    </div>
  )
}

function GroupDropZone({
  groupId,
  children,
  highlighted,
}: {
  groupId: string
  children: React.ReactNode
  /** Section is a valid drop target right now. */
  highlighted?: boolean
}) {
  const { setNodeRef, isOver } = useDroppable({
    id: `drop:${groupId}`,
    data: { type: 'group-drop', groupId } satisfies DragData,
  })
  const active = highlighted || isOver
  return (
    <div
      ref={setNodeRef}
      className={cn(
        'relative min-h-[2.75rem] min-w-0 space-y-1.5 rounded-xl p-1.5 transition-colors',
        active && 'bg-indigo-600/10 dark:bg-indigo-500/15',
      )}
    >
      {children}
    </div>
  )
}

/** Insertion preview — same footprint as a selected sidebar nav item. */
function DropItemPreview({
  label,
  icon: Icon,
}: {
  label: string
  icon: NavCatalogEntry['icon']
}) {
  return (
    <div
      className="pointer-events-none flex items-center gap-3 rounded-xl bg-indigo-600 px-3 py-2.5 text-sm font-medium text-white shadow-sm"
      aria-hidden
    >
      <Icon className="h-5 w-5 shrink-0" />
      <span className="truncate">{label}</span>
    </div>
  )
}

function AvailableChip({ entry, label }: { entry: NavCatalogEntry; label: string }) {
  const { attributes, listeners, setNodeRef, isDragging } = useDraggable({
    id: `avail:${entry.id}`,
    data: { type: 'available', itemId: entry.id } satisfies DragData,
  })
  const Icon = entry.icon
  return (
    <button
      type="button"
      ref={setNodeRef}
      className={cn(
        'flex w-full cursor-grab touch-none items-center gap-2 rounded-lg border border-dashed border-border bg-card px-2.5 py-2 text-left text-xs font-medium text-foreground transition-colors hover:border-indigo-300 hover:bg-indigo-50/40 dark:hover:bg-indigo-950/30',
        isDragging && 'opacity-40',
      )}
      {...attributes}
      {...listeners}
    >
      <GripVertical className="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
      <Icon className="h-4 w-4 shrink-0 text-muted-foreground" />
      <span className="truncate">{label}</span>
    </button>
  )
}

/** Cursor follower — same look as a selected sidebar nav row. */
function DragSidebarGhost({
  label,
  icon: Icon,
}: {
  label: string
  icon: NavCatalogEntry['icon']
}) {
  return (
    <div className="pointer-events-none flex cursor-grabbing items-center gap-3 rounded-xl bg-indigo-600 px-3 py-2.5 text-sm font-medium text-white shadow-lg">
      <Icon className="h-5 w-5 shrink-0" />
      <span className="truncate">{label}</span>
    </div>
  )
}

function pointerInsertPlacement(
  overRect: { top: number; height: number } | null | undefined,
  activeRect: { top: number; height: number } | null | undefined,
): 'before' | 'after' {
  if (!overRect || !activeRect) return 'before'
  const activeMid = activeRect.top + activeRect.height / 2
  const overMid = overRect.top + overRect.height / 2
  return activeMid > overMid ? 'after' : 'before'
}

/** Index where `item` should land in `bucket` relative to the hovered item. */
function insertIndexInBucket(
  bucket: SidebarNavItemV1[],
  overData: DragData | undefined,
  placement: 'before' | 'after',
): number {
  if (overData?.type !== 'item') return bucket.length
  const overIndex = bucket.findIndex((i) => i.id === overData.itemId)
  if (overIndex < 0) return bucket.length
  return placement === 'after' ? overIndex + 1 : overIndex
}

type ActiveDrag =
  | { kind: 'item'; itemId: NavItemId; label: string; fromAvailable: boolean }
  | { kind: 'group'; label: string }

function ItemEditorFields({
  item,
  baseLabel,
  onRename,
  onToggleIcon,
  onToggleEmphasis,
  onRemove,
  t,
}: {
  item: SidebarNavItemV1
  baseLabel: string
  onRename: (label: string) => void
  onToggleIcon: () => void
  onToggleEmphasis: () => void
  onRemove: () => void
  t: (key: string, fallback: string) => string
}) {
  const showIcon = item.showIcon !== false
  const accent = item.emphasis === 'accent'
  return (
    <div className="space-y-2">
      <div className="flex flex-wrap items-center gap-2">
        <span className="w-28 shrink-0 truncate text-xs text-muted-foreground" title={baseLabel}>
          {baseLabel}
        </span>
        <Input
          value={item.label ?? ''}
          placeholder={t('sidebar_editor.rename_placeholder', 'Nom personalitzat')}
          onChange={(e) => onRename(e.target.value)}
          className="h-8 min-w-[8rem] flex-1 text-sm"
        />
        <Button
          type="button"
          size="icon"
          variant="ghost"
          onClick={onRemove}
          aria-label={t('sidebar_editor.remove_item', 'Treure del menú')}
        >
          <Trash2 className="h-4 w-4" />
        </Button>
      </div>
      <div className="flex flex-wrap gap-1.5">
        <Button
          type="button"
          size="sm"
          variant={showIcon ? 'secondary' : 'outline'}
          className="h-7 gap-1 text-xs"
          onClick={onToggleIcon}
        >
          {showIcon ? <Eye className="h-3.5 w-3.5" /> : <EyeOff className="h-3.5 w-3.5" />}
          {t('sidebar_editor.show_icon', 'Icona')}
        </Button>
        <Button
          type="button"
          size="sm"
          variant={accent ? 'secondary' : 'outline'}
          className="h-7 gap-1 text-xs"
          onClick={onToggleEmphasis}
        >
          <Highlighter className="h-3.5 w-3.5" />
          {t('sidebar_editor.emphasis', 'Ressaltar')}
        </Button>
      </div>
    </div>
  )
}

export function SidebarEditorPage() {
  const { t } = useTranslation('common')
  const { toast } = useToast()
  const [params, setParams] = useSearchParams()
  const scopeParam = params.get('scope') === 'tenant' ? 'tenant' : 'user'
  const {
    tenantId,
    canEditTenant,
    ctx,
    labels,
    userLayout,
    tenantLayout,
    hasUserOverride,
    hasTenantOverride,
    saveUser,
    saveTenant,
    resetUser,
    resetTenant,
    settingsLoading,
  } = useSidebarNav()

  const scope: SidebarNavScope = scopeParam === 'tenant' && canEditTenant ? 'tenant' : 'user'
  const hasOverride = scope === 'user' ? hasUserOverride : hasTenantOverride

  useEffect(() => {
    if (scopeParam === 'tenant' && !canEditTenant) {
      setParams({}, { replace: true })
    }
  }, [scopeParam, canEditTenant, setParams])

  const [draft, setDraft] = useState<SidebarNavV1>(() =>
    layoutForScope(scope, userLayout, tenantLayout),
  )
  const [dirty, setDirty] = useState(false)
  const dirtyRef = useRef(false)
  dirtyRef.current = dirty
  const [resetOpen, setResetOpen] = useState(false)
  const [discardOpen, setDiscardOpen] = useState(false)
  const [pendingScope, setPendingScope] = useState<SidebarNavScope | null>(null)
  const [activeDrag, setActiveDrag] = useState<ActiveDrag | null>(null)
  const activeDragRef = useRef<ActiveDrag | null>(null)
  const [dragOverGroupId, setDragOverGroupId] = useState<string | null>(null)
  /** Insertion index for available-item drop preview within a group. */
  const [dropInsert, setDropInsert] = useState<{ groupId: string; index: number } | null>(null)
  const [previewPinned, setPreviewPinned] = useState(false)
  const [previewHover, setPreviewHover] = useState(false)
  const showPreview = previewPinned || previewHover

  const overlayDrag = activeDrag ?? activeDragRef.current

  function setActiveDragBoth(next: ActiveDrag | null) {
    activeDragRef.current = next
    setActiveDrag(next)
  }

  useEffect(() => {
    // Never clobber in-progress edits when settings/gates refetch.
    if (dirtyRef.current || settingsLoading) return
    setDraft(sanitizeLayoutAgainstCatalog(layoutForScope(scope, userLayout, tenantLayout), ctx))
  }, [scope, userLayout, tenantLayout, settingsLoading, dirty, ctx])

  const sensors = useSensors(useSensor(PointerSensor, { activationConstraint: { distance: 8 } }))

  const updateDraft = useCallback(
    (next: SidebarNavV1 | ((prev: SidebarNavV1) => SidebarNavV1)) => {
      dirtyRef.current = true
      setDirty(true)
      setDraft((prev) => {
        const raw = typeof next === 'function' ? next(prev) : next
        return sanitizeLayoutAgainstCatalog(raw, ctx)
      })
    },
    [ctx],
  )

  /** Items shown in the editor = same gates as the live sidebar. */
  const visiblePinnedItems = useMemo(
    () => draft.pinned.items.filter((i) => isNavItemAllowed(i.id, ctx)),
    [draft.pinned.items, ctx],
  )

  const visibleGroups = useMemo(
    () =>
      draft.groups.map((g) => ({
        ...g,
        items: g.items.filter((i) => isNavItemAllowed(i.id, ctx)),
      })),
    [draft.groups, ctx],
  )

  const assignedIds = useMemo(() => {
    const ids = new Set<string>()
    for (const item of visiblePinnedItems) ids.add(item.id)
    for (const g of visibleGroups) {
      for (const item of g.items) ids.add(item.id)
    }
    return ids
  }, [visiblePinnedItems, visibleGroups])

  const available = useMemo(
    () => listAvailableCatalogEntries(ctx).filter((e) => !assignedIds.has(e.id)),
    [ctx, assignedIds],
  )

  function clearDragHighlights() {
    setActiveDragBoth(null)
    setDragOverGroupId(null)
    setDropInsert(null)
  }

  function requestScopeChange(next: SidebarNavScope) {
    if (next === scope) return
    if (dirty) {
      setPendingScope(next)
      setDiscardOpen(true)
      return
    }
    setParams(next === 'tenant' ? { scope: 'tenant' } : {}, { replace: true })
  }

  function confirmDiscard() {
    if (pendingScope) {
      dirtyRef.current = false
      setDirty(false)
      setParams(pendingScope === 'tenant' ? { scope: 'tenant' } : {}, { replace: true })
      setPendingScope(null)
    }
    setDiscardOpen(false)
  }

  function onDragStart(event: DragStartEvent) {
    const data = event.active.data.current as DragData | undefined
    if (!data) return
    if (data.type === 'available' || data.type === 'item') {
      const itemId = data.itemId as NavItemId
      const entry = NAV_CATALOG_BY_ID[itemId]
      const label = entry ? resolveItemLabel(entry, undefined, labels, ctx) : itemId
      setActiveDragBoth({
        kind: 'item',
        itemId,
        label,
        fromAvailable: data.type === 'available',
      })
    } else if (data.type === 'group') {
      const g = draft.groups.find((x) => x.id === data.groupId)
      setActiveDragBoth({
        kind: 'group',
        label: g?.label || t('sidebar_editor.untitled', 'Sense títol'),
      })
    }
  }

  function resolveDropGroupId(overId: string, overData: DragData | undefined): string | null {
    if (overData?.type === 'group-drop') return overData.groupId
    if (overData?.type === 'item') return overData.groupId
    if (overData?.type === 'group') return overData.groupId
    if (overId.startsWith('drop:')) return overId.slice('drop:'.length)
    if (overId.startsWith('item:')) {
      const rest = overId.slice('item:'.length)
      const idx = rest.lastIndexOf(':')
      if (idx > 0) return rest.slice(0, idx)
    }
    if (overId.startsWith('group:')) return overId.slice('group:'.length)
    return null
  }

  function onDragOver(event: DragOverEvent) {
    const { active, over } = event
    if (!over) {
      setDragOverGroupId(null)
      setDropInsert(null)
      return
    }
    const activeData = active.data.current as DragData | undefined
    const overData = over.data.current as DragData | undefined
    const groupId = resolveDropGroupId(String(over.id), overData)
    setDragOverGroupId(groupId)

    // Custom placeholder only when dragging from Disponibles (sortable transforms handle in-menu moves).
    if (activeData?.type !== 'available' || !groupId) {
      setDropInsert(null)
      return
    }

    const items =
      groupId === PINNED_SECTION_ID
        ? visiblePinnedItems
        : (visibleGroups.find((g) => g.id === groupId)?.items ?? [])

    if (overData?.type === 'item') {
      const idx = items.findIndex((i) => i.id === overData.itemId)
      if (idx < 0) {
        setDropInsert({ groupId, index: items.length })
        return
      }
      const activeRect = active.rect.current.translated ?? active.rect.current.initial
      const placement = pointerInsertPlacement(over.rect, activeRect)
      setDropInsert({ groupId, index: placement === 'after' ? idx + 1 : idx })
    } else {
      setDropInsert({ groupId, index: items.length })
    }
  }

  function onDragEnd(event: DragEndEvent) {
    const { active, over } = event
    const activeData = active.data.current as DragData | undefined
    const overData = over?.data.current as DragData | undefined
    const activeRect = active.rect.current.translated ?? active.rect.current.initial
    const placement = over
      ? pointerInsertPlacement(over.rect, activeRect)
      : ('before' as const)
    clearDragHighlights()
    if (!over || !activeData) return

    if (activeData.type === 'group' && overData?.type === 'group') {
      if (activeData.groupId === PINNED_SECTION_ID || overData.groupId === PINNED_SECTION_ID) return
      updateDraft((prev) => {
        const from = prev.groups.findIndex((g) => g.id === activeData.groupId)
        const to = prev.groups.findIndex((g) => g.id === overData.groupId)
        if (from < 0 || to < 0 || from === to) return prev
        return { ...prev, groups: arrayMove(prev.groups, from, to) }
      })
      return
    }

    if (activeData.type === 'available') {
      const targetGroupId = resolveDropGroupId(String(over.id), overData)
      if (!targetGroupId) return
      updateDraft((prev) => {
        const bucket = getItemsBucket(prev, targetGroupId)
        if (!bucket) return prev
        if (bucket.some((i) => i.id === activeData.itemId)) return prev
        const at = insertIndexInBucket(bucket, overData, placement)
        const nextItems = [...bucket]
        nextItems.splice(at, 0, { id: activeData.itemId as NavItemId })
        return mapItemsInBucket(prev, targetGroupId, nextItems)
      })
      return
    }

    if (activeData.type === 'item') {
      const targetGroupId = resolveDropGroupId(String(over.id), overData)
      if (!targetGroupId) return

      updateDraft((prev) => {
        let next: SidebarNavV1 = {
          ...prev,
          pinned: { ...prev.pinned, items: [...prev.pinned.items] },
          groups: prev.groups.map((g) => ({ ...g, items: [...g.items] })),
        }

        const fromBucket = getItemsBucket(next, activeData.groupId)
        const toBucket = getItemsBucket(next, targetGroupId)
        if (!fromBucket || !toBucket) return prev

        const fromIndex = fromBucket.findIndex((i) => i.id === activeData.itemId)
        if (fromIndex < 0) return prev

        let toIndex = insertIndexInBucket(toBucket, overData, placement)

        if (activeData.groupId === targetGroupId) {
          if (fromIndex < toIndex) toIndex -= 1
          if (fromIndex === toIndex) return prev
          return mapItemsInBucket(next, activeData.groupId, arrayMove(fromBucket, fromIndex, toIndex))
        }

        const [moved] = fromBucket.splice(fromIndex, 1)
        toBucket.splice(Math.min(toIndex, toBucket.length), 0, moved)
        return mapItemsInBucket(
          mapItemsInBucket(next, activeData.groupId, fromBucket),
          targetGroupId,
          toBucket,
        )
      })
    }
  }

  function patchPinnedItem(itemId: string, patch: Partial<SidebarNavItemV1>) {
    updateDraft((prev) => ({
      ...prev,
      pinned: {
        ...prev.pinned,
        items: prev.pinned.items.map((i) => (i.id === itemId ? { ...i, ...patch } : i)),
      },
    }))
  }

  function patchGroupItem(groupId: string, itemId: string, patch: Partial<SidebarNavItemV1>) {
    updateDraft((prev) => ({
      ...prev,
      groups: prev.groups.map((g) =>
        g.id === groupId
          ? { ...g, items: g.items.map((i) => (i.id === itemId ? { ...i, ...patch } : i)) }
          : g,
      ),
    }))
  }

  function addGroup() {
    const group: SidebarNavGroupV1 = {
      id: newGroupId(),
      label: t('sidebar_editor.new_section', 'Nova secció'),
      items: [],
    }
    updateDraft((prev) => ({ ...prev, groups: [...prev.groups, group] }))
  }

  function clearAll() {
    updateDraft({
      version: 2,
      pinned: { visible: true, items: [] },
      groups: [],
    })
  }

  async function applyReset() {
    if (scope === 'tenant') {
      await resetTenant.mutateAsync()
      setDraft(buildDefaultNavLayout())
    } else {
      await resetUser.mutateAsync()
      setDraft(tenantLayout ?? buildDefaultNavLayout())
    }
    dirtyRef.current = false
    setDirty(false)
  }

  async function handleSave() {
    const sanitized = sanitizeLayoutAgainstCatalog(draft, ctx)
    if (countNavItems(sanitized) === 0) {
      try {
        await applyReset()
        toast({
          description: t(
            'sidebar_editor.saved_empty_fallback',
            'Menú buit: s\'aplica el fallback (organització o plataforma).',
          ),
        })
      } catch (e) {
        toast({
          variant: 'destructive',
          description: e instanceof Error ? e.message : t('sidebar_editor.save_error', 'No s\'ha pogut desar'),
        })
      }
      return
    }

    const parsed = sidebarNavSchema.safeParse(sanitized)
    if (!parsed.success) {
      toast({
        variant: 'destructive',
        description: t('sidebar_editor.invalid', 'La configuració no és vàlida'),
      })
      return
    }
    try {
      if (scope === 'tenant') await saveTenant.mutateAsync(parsed.data)
      else await saveUser.mutateAsync(parsed.data)
      setDirty(false)
      dirtyRef.current = false
      toast({ description: t('sidebar_editor.saved', 'Menú desat') })
    } catch (e) {
      toast({
        variant: 'destructive',
        description: e instanceof Error ? e.message : t('sidebar_editor.save_error', 'No s\'ha pogut desar'),
      })
    }
  }

  async function handleResetConfirm() {
    try {
      await applyReset()
      setResetOpen(false)
      toast({ description: t('sidebar_editor.reset_done', 'Menú restablert') })
    } catch (e) {
      toast({
        variant: 'destructive',
        description: e instanceof Error ? e.message : t('sidebar_editor.reset_error', 'No s\'ha pogut restablir'),
      })
    }
  }

  if (!tenantId) return <Navigate to="/app" replace />

  const saving = saveUser.isPending || saveTenant.isPending
  const resetting = resetUser.isPending || resetTenant.isPending
  const groupIds = visibleGroups.map((g) => `group:${g.id}`)
  const pinnedItemIds = visiblePinnedItems.map((i) => `item:${PINNED_SECTION_ID}:${i.id}`)

  const dropPreview =
    overlayDrag?.kind === 'item' && overlayDrag.fromAvailable
      ? {
          label: overlayDrag.label,
          icon: NAV_CATALOG_BY_ID[overlayDrag.itemId]?.icon ?? NAV_CATALOG_BY_ID.home.icon,
        }
      : null
  const lockItemTransforms = Boolean(dropPreview)

  function renderItemEditor(
    groupId: string,
    item: SidebarNavItemV1,
    patch: (p: Partial<SidebarNavItemV1>) => void,
    remove: () => void,
  ) {
    const entry = NAV_CATALOG_BY_ID[item.id as NavItemId]
    const baseLabel = entry ? resolveItemLabel(entry, undefined, labels, ctx) : item.id
    return (
      <SortableItemRow
        key={`${groupId}:${item.id}`}
        groupId={groupId}
        itemId={item.id}
        lockTransform={lockItemTransforms}
      >
        <ItemEditorFields
          item={item}
          baseLabel={baseLabel}
          t={t}
          onRename={(label) =>
            patch(label.trim() ? { label: label.trim() } : { label: undefined })
          }
          onToggleIcon={() => patch({ showIcon: item.showIcon === false ? true : false })}
          onToggleEmphasis={() =>
            patch({ emphasis: item.emphasis === 'accent' ? 'default' : 'accent' })
          }
          onRemove={remove}
        />
      </SortableItemRow>
    )
  }

  function renderDropPreviewAt(groupId: string, index: number) {
    if (!dropPreview || dropInsert?.groupId !== groupId || dropInsert.index !== index) return null
    return <DropItemPreview label={dropPreview.label} icon={dropPreview.icon} />
  }

  return (
    <div className="mx-auto max-w-6xl space-y-6 px-4 py-6 sm:px-6">
      <Button asChild variant="ghost" size="sm">
        <Link to="/app">
          <ArrowLeft className="h-4 w-4" />
          {t('sidebar_editor.back', 'Índex')}
        </Link>
      </Button>

      <header className="space-y-2">
        <h1 className="text-2xl font-bold tracking-tight">
          {t('sidebar_editor.title', 'Personalitzar menú')}
        </h1>
        <p className="text-sm text-muted-foreground">
          {scope === 'tenant'
            ? t('sidebar_editor.tenant_hint', 'Aquest menú l\'hereten els membres sense personalització pròpia.')
            : t('sidebar_editor.user_hint', 'Només afecta el teu menú en aquesta organització.')}
        </p>
        {hasOverride && (
          <p className="text-xs font-medium text-indigo-600">
            {t('sidebar_editor.has_override', 'Hi ha una configuració desada en aquest nivell.')}
          </p>
        )}
      </header>

      {dirty && (
        <div
          role="status"
          className="flex items-start gap-3 rounded-xl border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-950 dark:border-amber-700 dark:bg-amber-950/40 dark:text-amber-100"
        >
          <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
          <div className="min-w-0 flex-1">
            <p className="font-medium">{t('sidebar_editor.unsaved_title', 'Canvis sense desar')}</p>
            <p className="text-amber-900/80 dark:text-amber-100/80">
              {t(
                'sidebar_editor.unsaved_body',
                'Prem Desar per aplicar-los al menú, o Restablir per descartar la configuració desada.',
              )}
            </p>
          </div>
          <Button type="button" size="sm" onClick={() => void handleSave()} disabled={saving}>
            {t('sidebar_editor.save', 'Desar')}
          </Button>
        </div>
      )}

      <div className="flex flex-wrap gap-2">
        <Button type="button" size="sm" variant={scope === 'user' ? 'default' : 'outline'} onClick={() => requestScopeChange('user')}>
          {t('sidebar_editor.scope_user', 'El meu menú')}
        </Button>
        {canEditTenant && (
          <Button type="button" size="sm" variant={scope === 'tenant' ? 'default' : 'outline'} onClick={() => requestScopeChange('tenant')}>
            {t('sidebar_editor.scope_tenant', 'Organització')}
          </Button>
        )}
      </div>

      <div className="flex flex-wrap gap-2">
        <Button type="button" size="sm" onClick={() => void handleSave()} disabled={!dirty || saving}>
          {t('sidebar_editor.save', 'Desar')}
        </Button>
        <Button type="button" size="sm" variant="outline" onClick={() => setResetOpen(true)} disabled={resetting || (!hasOverride && !dirty)}>
          {t('sidebar_editor.reset', 'Restablir per defecte')}
        </Button>
        <Button type="button" size="sm" variant="secondary" onClick={addGroup}>
          <Plus className="h-4 w-4" />
          {t('sidebar_editor.add_section', 'Afegir secció')}
        </Button>
        <Button type="button" size="sm" variant="ghost" onClick={clearAll}>
          <Eraser className="h-4 w-4" />
          {t('sidebar_editor.clear_all', 'Treure-ho tot')}
        </Button>
        <div
          className="relative"
          onMouseEnter={() => setPreviewHover(true)}
          onMouseLeave={() => setPreviewHover(false)}
        >
          <Button
            type="button"
            size="sm"
            variant={previewPinned ? 'default' : 'outline'}
            aria-pressed={previewPinned}
            onClick={() => setPreviewPinned((v) => !v)}
          >
            <Eye className="h-4 w-4" />
            {t('sidebar_editor.preview_toggle', 'Previsualitzar')}
          </Button>
          {showPreview && (
            <div className="absolute right-0 top-full z-40 mt-2">
              <SidebarMenuPreview layout={sanitizeLayoutAgainstCatalog(draft, ctx)} ctx={ctx} labels={labels} />
            </div>
          )}
        </div>
      </div>

      {settingsLoading ? (
        <div className="h-40 animate-pulse rounded-xl bg-muted" aria-busy="true" />
      ) : (
        <DndContext
          sensors={sensors}
          collisionDetection={closestCorners}
          onDragStart={onDragStart}
          onDragOver={onDragOver}
          onDragEnd={onDragEnd}
          onDragCancel={clearDragHighlights}
        >
          <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_16rem]">
            <div className="min-w-0 space-y-4">
              {/* Pinned fixed section */}
              <div
                className={cn(
                  'rounded-xl border border-indigo-200 bg-indigo-50/30 px-3 py-3 space-y-3 dark:border-indigo-900 dark:bg-indigo-950/20 transition-colors',
                  dragOverGroupId === PINNED_SECTION_ID && 'bg-indigo-50/80 dark:bg-indigo-950/35',
                )}
              >
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <div>
                    <h2 className="text-sm font-semibold text-foreground">
                      {t('sidebar_editor.pinned_title', 'Secció superior (fixa)')}
                    </h2>
                    <p className="text-[11px] text-muted-foreground">
                      {t(
                        'sidebar_editor.pinned_hint',
                        'Sense títol. Si és visible, queda fixa damunt el menú amb scroll; el menú inferior conserva espai.',
                      )}
                    </p>
                  </div>
                  <label className="flex items-center gap-2 text-xs font-medium">
                    <input
                      type="checkbox"
                      className="h-4 w-4 rounded border-input"
                      checked={draft.pinned.visible}
                      onChange={(e) =>
                        updateDraft((prev) => ({
                          ...prev,
                          pinned: { ...prev.pinned, visible: e.target.checked },
                        }))
                      }
                    />
                    {t('sidebar_editor.pinned_visible', 'Visible')}
                  </label>
                </div>

                <GroupDropZone
                  groupId={PINNED_SECTION_ID}
                  highlighted={dragOverGroupId === PINNED_SECTION_ID}
                >
                  <SortableContext items={pinnedItemIds} strategy={verticalListSortingStrategy}>
                    {visiblePinnedItems.length === 0 ? (
                      dropPreview && dropInsert?.groupId === PINNED_SECTION_ID ? (
                        <DropItemPreview label={dropPreview.label} icon={dropPreview.icon} />
                      ) : (
                        <p className="px-2 py-3 text-center text-xs text-muted-foreground">
                          {t('sidebar_editor.drop_here', 'Arrossega elements aquí des de Disponibles')}
                        </p>
                      )
                    ) : (
                      <div className="space-y-1.5">
                        {visiblePinnedItems.map((item, index) => (
                          <Fragment key={item.id}>
                            {renderDropPreviewAt(PINNED_SECTION_ID, index)}
                            {renderItemEditor(
                              PINNED_SECTION_ID,
                              item,
                              (patch) => {
                                patchPinnedItem(item.id, patch)
                              },
                              () =>
                                updateDraft((prev) => ({
                                  ...prev,
                                  pinned: {
                                    ...prev.pinned,
                                    items: prev.pinned.items.filter((i) => i.id !== item.id),
                                  },
                                })),
                            )}
                          </Fragment>
                        ))}
                        {renderDropPreviewAt(PINNED_SECTION_ID, visiblePinnedItems.length)}
                      </div>
                    )}
                  </SortableContext>
                </GroupDropZone>
              </div>

              <SortableContext items={groupIds} strategy={verticalListSortingStrategy}>
                {visibleGroups.length === 0 ? (
                  <div className="rounded-xl border border-dashed border-border p-8 text-center text-sm text-muted-foreground">
                    {t(
                      'sidebar_editor.empty_scroll',
                      'Cap secció amb scroll. Afegeix-ne o deixa només la superior.',
                    )}
                  </div>
                ) : (
                  visibleGroups.map((group) => {
                    const itemSortIds = group.items.map((i) => `item:${group.id}:${i.id}`)
                    return (
                      <div
                        key={group.id}
                        className={cn(
                          'rounded-xl border border-border bg-card px-3 py-3 space-y-3 transition-colors',
                          dragOverGroupId === group.id && 'bg-indigo-50/50 dark:bg-indigo-950/30',
                        )}
                      >
                        <SortableGroupHeader groupId={group.id}>
                          <Input
                            value={group.label ?? ''}
                            placeholder={t('sidebar_editor.untitled', 'Sense títol')}
                            onChange={(e) =>
                              updateDraft((prev) => ({
                                ...prev,
                                groups: prev.groups.map((g) =>
                                  g.id === group.id
                                    ? { ...g, label: e.target.value.trim() === '' ? null : e.target.value }
                                    : g,
                                ),
                              }))
                            }
                            className="h-8 text-sm font-semibold"
                          />
                          <Button
                            type="button"
                            size="icon"
                            variant="ghost"
                            className="shrink-0 text-destructive"
                            onClick={() =>
                              updateDraft((prev) => ({
                                ...prev,
                                groups: prev.groups.filter((g) => g.id !== group.id),
                              }))
                            }
                            aria-label={t('sidebar_editor.remove_section', 'Eliminar secció')}
                          >
                            <Trash2 className="h-4 w-4" />
                          </Button>
                        </SortableGroupHeader>

                        <GroupDropZone
                          groupId={group.id}
                          highlighted={dragOverGroupId === group.id}
                        >
                          <SortableContext items={itemSortIds} strategy={verticalListSortingStrategy}>
                            {group.items.length === 0 ? (
                              dropPreview && dropInsert?.groupId === group.id ? (
                                <DropItemPreview label={dropPreview.label} icon={dropPreview.icon} />
                              ) : (
                                <p className="px-2 py-3 text-center text-xs text-muted-foreground">
                                  {t('sidebar_editor.drop_here', 'Arrossega elements aquí des de Disponibles')}
                                </p>
                              )
                            ) : (
                              <div className="space-y-1.5">
                                {group.items.map((item, index) => (
                                  <Fragment key={item.id}>
                                    {renderDropPreviewAt(group.id, index)}
                                    {renderItemEditor(
                                      group.id,
                                      item,
                                      (patch) => patchGroupItem(group.id, item.id, patch),
                                      () =>
                                        updateDraft((prev) => ({
                                          ...prev,
                                          groups: prev.groups.map((g) =>
                                            g.id === group.id
                                              ? { ...g, items: g.items.filter((i) => i.id !== item.id) }
                                              : g,
                                          ),
                                        })),
                                    )}
                                  </Fragment>
                                ))}
                                {renderDropPreviewAt(group.id, group.items.length)}
                              </div>
                            )}
                          </SortableContext>
                        </GroupDropZone>
                      </div>
                    )
                  })
                )}
              </SortableContext>
            </div>

            <aside className="lg:sticky lg:top-4 h-fit space-y-3 rounded-xl border border-border bg-muted/30 p-3">
              <div>
                <h2 className="text-xs font-semibold uppercase tracking-widest text-muted-foreground">
                  {t('sidebar_editor.available', 'Disponibles')}
                </h2>
                <p className="mt-1 text-[11px] text-muted-foreground">
                  {t(
                    'sidebar_editor.available_drag_hint',
                    'Arrossega cap a la secció superior o a una secció amb scroll.',
                  )}
                </p>
              </div>
              {available.length === 0 ? (
                <p className="text-xs text-muted-foreground">
                  {t('sidebar_editor.available_empty', 'Tots els elements són al menú.')}
                </p>
              ) : (
                <ul className="space-y-1.5 max-h-[70vh] overflow-y-auto">
                  {available.map((e) => (
                    <li key={e.id}>
                      <AvailableChip entry={e} label={resolveItemLabel(e, undefined, labels, ctx)} />
                    </li>
                  ))}
                </ul>
              )}
            </aside>
          </div>

          <DragOverlay dropAnimation={null}>
            {overlayDrag?.kind === 'item' ? (
              <DragSidebarGhost
                label={overlayDrag.label}
                icon={NAV_CATALOG_BY_ID[overlayDrag.itemId]?.icon ?? NAV_CATALOG_BY_ID.home.icon}
              />
            ) : overlayDrag?.kind === 'group' ? (
              <div className="cursor-grabbing rounded-lg border border-indigo-200 bg-white px-3 py-2 text-sm font-semibold shadow-lg dark:border-indigo-800 dark:bg-zinc-900">
                {overlayDrag.label}
              </div>
            ) : null}
          </DragOverlay>
        </DndContext>
      )}

      <Dialog open={resetOpen} onOpenChange={setResetOpen}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>{t('sidebar_editor.reset', 'Restablir per defecte')}</DialogTitle>
            <DialogDescription>
              {scope === 'tenant'
                ? t(
                    'sidebar_editor.reset_tenant_confirm',
                    'Restablir el menú de l\'organització al de la plataforma? Els usuaris amb menú personal no canvien.',
                  )
                : t(
                    'sidebar_editor.reset_user_confirm',
                    'Restablir el teu menú? S\'heretarà el de l\'organització o el de la plataforma.',
                  )}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => setResetOpen(false)}>
              {t('common.cancel', 'Cancel·lar')}
            </Button>
            <Button type="button" onClick={() => void handleResetConfirm()} disabled={resetting}>
              {t('sidebar_editor.reset_confirm_btn', 'Restablir')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={discardOpen} onOpenChange={setDiscardOpen}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>{t('sidebar_editor.unsaved_title', 'Canvis sense desar')}</DialogTitle>
            <DialogDescription>
              {t('sidebar_editor.discard_confirm', 'Tens canvis sense desar. Continuar?')}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={() => {
                setPendingScope(null)
                setDiscardOpen(false)
              }}
            >
              {t('common.cancel', 'Cancel·lar')}
            </Button>
            <Button type="button" onClick={confirmDiscard}>
              {t('sidebar_editor.discard_continue', 'Continuar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
