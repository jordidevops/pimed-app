import { useEffect, useMemo, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router-dom'
import {
  ArrowDown,
  ArrowUp,
  Copy,
  Eye,
  ListChecks,
  Pencil,
  Plus,
  RefreshCw,
  Star,
  Trash2,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { Badge } from '@/components/ui/badge'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { ChecklistKindIcon } from './ChecklistKindIcon'
import {
  ChecklistTemplatePreview,
  draftItemsToPreview,
  templateItemsToPreview,
} from './ChecklistTemplatePreview'
import {
  CHECKLIST_LOCALES,
  POINTS_PAGE_SIZE,
  listTenantPoints,
  type ChecklistLocale,
  type ChecklistReviewPoint,
} from '../api/checklistPointsService'
import {
  CHECKLIST_KINDS,
  TEMPLATES_PAGE_SIZE,
  VISIT_INTENTS,
  archiveTemplate,
  cloneTemplate,
  createDraftFromPublished,
  createTemplate,
  getPlatformTemplatePreview,
  getTemplateDetail,
  listChecklistTemplates,
  listPlatformTemplates,
  listResponseSets,
  listPlatformResponseSets,
  listTemplateCategories,
  listTemplateForkStatus,
  publishVersion,
  saveDraftItems,
  setTemplateDefault,
  setVersionDefaultResponseSet,
  syncDraftItemsFromPoints,
  updateTemplate,
  type ChecklistKind,
  type ChecklistTemplate,
  type DraftItemInput,
  type VisitIntent,
} from '../api/checklistTemplatesService'

const ALL = '__all__'
const NONE = '__none__'

type DraftItem = DraftItemInput & { key: string }

function newKey(): string {
  return crypto.randomUUID()
}

function emptyTodoItem(): DraftItem {
  return {
    key: newKey(),
    title: '',
    description_internal: null,
    description_public: null,
    include_in_report: false,
    is_required: false,
    evidence_required: false,
    response_type: 'checkbox',
    review_point_id: null,
    response_set_id: null,
  }
}

function itemFromPoint(point: ChecklistReviewPoint): DraftItem {
  return {
    key: newKey(),
    title: point.title,
    description_internal: point.description,
    description_public: point.client_text ?? point.description,
    locale: point.locale,
    category: point.category,
    include_in_report: true,
    is_required: true,
    evidence_required: false,
    response_type: 'single_choice',
    review_point_id: point.id,
    response_set_id: null,
  }
}

function localeLabel(locale: string): string {
  return locale.toUpperCase()
}

function PointPickerDialog({
  open,
  tenantId,
  selectedIds,
  templateLocale,
  onOpenChange,
  onAdd,
}: {
  open: boolean
  tenantId: string
  selectedIds: string[]
  templateLocale: ChecklistLocale
  onOpenChange: (open: boolean) => void
  onAdd: (points: ChecklistReviewPoint[]) => void
}) {
  const { t } = useTranslation('field-service')
  const [q, setQ] = useState('')
  const [page, setPage] = useState(0)
  const [picked, setPicked] = useState<Record<string, ChecklistReviewPoint>>({})

  useEffect(() => {
    if (!open) return
    setQ('')
    setPage(0)
    setPicked({})
  }, [open, templateLocale])

  const { data, isLoading } = useQuery({
    queryKey: ['checklist_points', 'picker', tenantId, templateLocale, q, page],
    queryFn: () =>
      listTenantPoints(tenantId, {
        q: q.trim() || undefined,
        locale: templateLocale,
        limit: POINTS_PAGE_SIZE,
        offset: page * POINTS_PAGE_SIZE,
      }),
    enabled: open,
  })

  const rows = data?.rows ?? []
  const total = data?.total ?? 0
  const pageCount = Math.max(1, Math.ceil(total / POINTS_PAGE_SIZE))

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90dvh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{t('editor.pick_points', 'Afegir punts de revisió')}</DialogTitle>
          <DialogDescription>
            {t(
              'editor.pick_points_locale_hint',
              'Només punts del catàleg en l\'idioma de la plantilla ({{locale}}). Clona els de plataforma abans.',
              { locale: localeLabel(templateLocale) },
            )}
          </DialogDescription>
        </DialogHeader>

        <Input
          value={q}
          placeholder={t('points.search', 'Cerca per títol o descripció')}
          onChange={(e) => {
            setQ(e.target.value)
            setPage(0)
          }}
        />

        {isLoading ? (
          <p className="text-sm text-muted-foreground">{t('templates.loading', 'Carregant…')}</p>
        ) : rows.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            {t('editor.no_points', 'No hi ha punts al teu catàleg.')}{' '}
            <Link to="/field/checklist-points" className="underline">
              {t('points.title', 'Punts de revisió')}
            </Link>
          </p>
        ) : (
          <ul className="divide-y divide-border rounded-lg border border-border">
            {rows.map((point) => {
              const already = selectedIds.includes(point.id)
              return (
                <li key={point.id} className="flex items-start gap-2 px-3 py-2">
                  <input
                    type="checkbox"
                    className="mt-1"
                    disabled={already}
                    checked={already || !!picked[point.id]}
                    onChange={(e) =>
                      setPicked((prev) => {
                        const next = { ...prev }
                        if (e.target.checked) next[point.id] = point
                        else delete next[point.id]
                        return next
                      })
                    }
                  />
                  <div className="min-w-0 flex-1">
                    <p className="text-sm font-medium truncate">{point.title}</p>
                    <p className="text-xs text-muted-foreground">
                      {point.category} · {localeLabel(point.locale)}
                      {already && ` · ${t('editor.already_added', 'ja afegit')}`}
                    </p>
                  </div>
                </li>
              )
            })}
          </ul>
        )}

        {total > POINTS_PAGE_SIZE && (
          <div className="flex items-center justify-between gap-2 text-sm">
            <Button size="sm" variant="outline" disabled={page === 0} onClick={() => setPage(page - 1)}>
              {t('points.prev', 'Anterior')}
            </Button>
            <span className="text-muted-foreground">
              {t('points.page_of', 'Pàgina {{page}} de {{pages}}', { page: page + 1, pages: pageCount })}
            </span>
            <Button
              size="sm"
              variant="outline"
              disabled={page + 1 >= pageCount}
              onClick={() => setPage(page + 1)}
            >
              {t('points.next', 'Següent')}
            </Button>
          </div>
        )}

        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            {t('templates.cancel', 'Cancel·lar')}
          </Button>
          <Button
            disabled={Object.keys(picked).length === 0}
            onClick={() => {
              onAdd(Object.values(picked))
              onOpenChange(false)
            }}
          >
            {t('editor.add_selected', 'Afegir seleccionats')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function TemplateEditor({
  templateId,
  tenantId,
  onClose,
}: {
  templateId: string
  tenantId: string
  onClose: () => void
}) {
  const { t } = useTranslation('field-service')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  const { data: detail, isLoading } = useQuery({
    queryKey: ['checklist_template_detail', templateId],
    queryFn: () => getTemplateDetail(templateId),
  })

  const { data: responseSets = [] } = useQuery({
    queryKey: ['checklist_response_sets', tenantId],
    queryFn: () => listResponseSets(tenantId),
  })

  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [kind, setKind] = useState<ChecklistKind>('todo')
  const [intent, setIntent] = useState<VisitIntent>('generic')
  const [locale, setLocale] = useState<ChecklistLocale>('ca')
  const [category, setCategory] = useState('general')
  const [isDefault, setIsDefault] = useState(false)
  const [defaultResponseSetId, setDefaultResponseSetId] = useState<string>(NONE)
  const [items, setItems] = useState<DraftItem[]>([])
  const [pickerOpen, setPickerOpen] = useState(false)
  const [saving, setSaving] = useState(false)
  const [publishing, setPublishing] = useState(false)
  const [editorTab, setEditorTab] = useState<'edit' | 'preview'>('edit')

  useEffect(() => {
    if (!detail) return
    setName(detail.template.name)
    setDescription(detail.template.description ?? '')
    setKind(detail.template.kind)
    setIntent(detail.template.intent ?? 'generic')
    setLocale(detail.template.locale)
    setCategory(detail.template.category)
    setIsDefault(detail.template.is_default)
    setDefaultResponseSetId(detail.editingVersion?.default_response_set_id ?? NONE)
    setEditorTab('edit')
    setItems(
      detail.items.map((i) => ({
        key: i.id,
        position: i.position,
        review_point_id: i.review_point_id,
        title: i.title,
        description_internal: i.description_internal,
        description_public: i.description_public,
        locale: i.locale,
        category: i.category,
        include_in_report: i.include_in_report,
        is_required: i.is_required,
        response_type: i.response_type,
        response_set_id: i.response_set_id,
        evidence_required: i.evidence_required,
      })),
    )
  }, [detail])

  const editingVersion = detail?.editingVersion
  const isDraft = editingVersion?.status === 'draft'
  const hasPublished = detail?.versions.some((v) => v.status === 'published') ?? false
  const selectedPointIds = useMemo(
    () => items.map((i) => i.review_point_id).filter((id): id is string => !!id),
    [items],
  )

  function patchItem(key: string, patch: Partial<DraftItem>) {
    setItems((prev) => prev.map((it) => (it.key === key ? { ...it, ...patch } : it)))
  }

  function moveItem(index: number, delta: number) {
    setItems((prev) => {
      const next = [...prev]
      const target = index + delta
      if (target < 0 || target >= next.length) return prev
      const [moved] = next.splice(index, 1)
      next.splice(target, 0, moved)
      return next
    })
  }

  function handleKindChange(nextKind: ChecklistKind) {
    if (nextKind === kind) return
    if (items.some((i) => i.title.trim())) {
      const confirmed = window.confirm(
        t('editor.kind_change_confirm', 'Canviar el tipus buidarà els ítems actuals. Continuar?'),
      )
      if (!confirmed) return
    }
    setKind(nextKind)
    setItems(nextKind === 'todo' ? [emptyTodoItem()] : [])
  }

  async function handleSave(): Promise<boolean> {
    if (!detail || !editingVersion) return false
    if (!name.trim()) {
      toast({ variant: 'destructive', description: t('templates.validation', 'Cal un nom i almenys un ítem') })
      return false
    }
    setSaving(true)
    try {
      await updateTemplate(templateId, {
        name,
        description,
        kind,
        locale,
        category,
        intent,
      })
      await setVersionDefaultResponseSet(
        editingVersion.id,
        defaultResponseSetId === NONE ? null : defaultResponseSetId,
      )
      await saveDraftItems(editingVersion.id, kind, items)
      if (isDefault !== detail.template.is_default) {
        await setTemplateDefault(templateId, isDefault)
      }
      await queryClient.invalidateQueries({ queryKey: ['checklist_template_detail', templateId] })
      await queryClient.invalidateQueries({ queryKey: ['checklist_templates'] })
      toast({ description: t('templates.saved', 'Plantilla desada') })
      return true
    } catch (err) {
      const code = err instanceof Error ? err.message : 'save_failed'
      toast({
        variant: 'destructive',
        description: t(`editor.error_${code}`, t('templates.save_failed', 'Error en desar')),
      })
      return false
    } finally {
      setSaving(false)
    }
  }

  async function handlePublish() {
    if (!editingVersion) return
    setPublishing(true)
    try {
      const saved = await handleSave()
      if (!saved) return
      await publishVersion(editingVersion.id)
      await queryClient.invalidateQueries({ queryKey: ['checklist_template_detail', templateId] })
      await queryClient.invalidateQueries({ queryKey: ['checklist_templates'] })
      toast({ description: t('editor.publish_success', 'Versió publicada') })
    } catch (err) {
      const code = err instanceof Error ? err.message : 'publish_failed'
      toast({
        variant: 'destructive',
        description: t(`editor.error_${code}`, t('editor.publish_failed', 'No s\'ha pogut publicar')),
      })
    } finally {
      setPublishing(false)
    }
  }

  async function handleNewDraft() {
    setPublishing(true)
    try {
      await createDraftFromPublished(templateId)
      await queryClient.invalidateQueries({ queryKey: ['checklist_template_detail', templateId] })
      toast({ description: t('editor.draft_created', 'Esborrany creat') })
    } catch {
      toast({
        variant: 'destructive',
        description: t('editor.draft_failed', 'No s\'ha pogut crear l\'esborrany'),
      })
    } finally {
      setPublishing(false)
    }
  }

  async function handleSyncPoints() {
    if (!editingVersion) return
    try {
      await saveDraftItems(editingVersion.id, kind, items)
      const count = await syncDraftItemsFromPoints(editingVersion.id)
      await queryClient.invalidateQueries({ queryKey: ['checklist_template_detail', templateId] })
      toast({ description: t('editor.sync_done', '{{n}} ítems actualitzats des del catàleg', { n: count }) })
    } catch {
      toast({ variant: 'destructive', description: t('editor.sync_failed', 'No s\'ha pogut sincronitzar') })
    }
  }

  if (isLoading || !detail) {
    return <p className="text-sm text-muted-foreground">{t('templates.loading', 'Carregant…')}</p>
  }

  const previewItems = draftItemsToPreview(items)
  const previewDefaultSetId = defaultResponseSetId === NONE ? null : defaultResponseSetId

  return (
    <div className="space-y-4 rounded-xl border border-border p-4">
      <div className="flex items-center justify-between gap-2">
        <h2 className="font-semibold">{name || t('templates.new', 'Nova')}</h2>
        <div className="flex gap-2">
          {hasPublished && !isDraft && (
            <Button size="sm" variant="outline" onClick={() => void handleNewDraft()} disabled={publishing}>
              {t('editor.new_draft', 'Nou esborrany')}
            </Button>
          )}
          {isDraft && (
            <Button size="sm" onClick={() => void handlePublish()} disabled={publishing || saving}>
              {t('editor.publish', 'Publicar')}
            </Button>
          )}
        </div>
      </div>

      {editingVersion && (
        <p className="text-xs text-muted-foreground">
          {t('editor.version', 'Versió {{n}} · {{status}}', {
            n: editingVersion.version_number,
            status: t(`editor.status_${editingVersion.status}`, editingVersion.status),
          })}
        </p>
      )}

      {detail.updateAvailable && (
        <p className="rounded-lg bg-muted px-3 py-2 text-xs">
          {t('editor.source_updated', 'La plantilla de plataforma d\'origen té una versió més nova.')}
        </p>
      )}

      <Tabs value={editorTab} onValueChange={(v) => setEditorTab(v as 'edit' | 'preview')}>
        <TabsList>
          <TabsTrigger value="edit">{t('editor.tab_edit', 'Editar')}</TabsTrigger>
          <TabsTrigger value="preview">{t('editor.tab_preview', 'Vista prèvia')}</TabsTrigger>
        </TabsList>

        <TabsContent value="preview" className="mt-4">
          <ChecklistTemplatePreview
            kind={kind}
            items={previewItems}
            responseSets={responseSets}
            defaultResponseSetId={previewDefaultSetId}
            emptyHint={
              kind === 'review'
                ? t('editor.empty_review_items', 'Afegeix punts del teu catàleg per començar.')
                : t('editor.empty_todo_items', 'Afegeix les tasques de la visita.')
            }
          />
        </TabsContent>

        <TabsContent value="edit" className="mt-4 space-y-4">
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1.5 sm:col-span-2">
          <label className="text-sm font-medium">{t('templates.name', 'Nom de la plantilla')}</label>
          <Input value={name} onChange={(e) => setName(e.target.value)} disabled={!isDraft} />
        </div>
        <div className="space-y-1.5 sm:col-span-2">
          <label className="text-sm font-medium">{t('editor.description', 'Descripció')}</label>
          <Textarea
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            rows={2}
            disabled={!isDraft}
          />
        </div>
        <div className="space-y-1.5">
          <label className="text-sm font-medium">{t('editor.kind', 'Tipus')}</label>
          <Select
            value={kind}
            onValueChange={(v) => handleKindChange(v as ChecklistKind)}
            disabled={!isDraft}
          >
            <SelectTrigger><SelectValue /></SelectTrigger>
            <SelectContent>
              {CHECKLIST_KINDS.map((k) => (
                <SelectItem key={k} value={k}>{t(`editor.kind_${k}`, k)}</SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-1.5">
          <label className="text-sm font-medium">{t('editor.intent', 'Intenció de visita')}</label>
          <Select
            value={intent}
            onValueChange={(v) => setIntent(v as VisitIntent)}
            disabled={!isDraft}
          >
            <SelectTrigger><SelectValue /></SelectTrigger>
            <SelectContent>
              {VISIT_INTENTS.map((i) => (
                <SelectItem key={i} value={i}>
                  {t(`intent.${i}`, i)}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          <p className="text-[11px] text-muted-foreground">
            {t(
              'editor.intent_hint',
              'Inspecció vs correctiva: canvia el copy del tancament i de l\'informe.',
            )}
          </p>
        </div>
        <div className="space-y-1.5">
          <label className="text-sm font-medium">{t('points.locale', 'Idioma')}</label>
          <Select
            value={locale}
            onValueChange={(v) => setLocale(v as ChecklistLocale)}
            disabled={!isDraft}
          >
            <SelectTrigger><SelectValue /></SelectTrigger>
            <SelectContent>
              {CHECKLIST_LOCALES.map((l) => (
                <SelectItem key={l} value={l}>{localeLabel(l)}</SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-1.5">
          <label className="text-sm font-medium">{t('points.category', 'Categoria')}</label>
          <Input value={category} onChange={(e) => setCategory(e.target.value)} disabled={!isDraft} />
        </div>
        <label className="flex items-center gap-2 text-sm sm:mt-6">
          <input
            type="checkbox"
            checked={isDefault}
            disabled={!isDraft}
            onChange={(e) => setIsDefault(e.target.checked)}
          />
          {t('editor.is_default', 'Per defecte per a aquest tipus')}
        </label>
      </div>

      {kind === 'review' && (
        <div className="space-y-1.5">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <label className="text-sm font-medium">
              {t('editor.default_response_set', 'Conjunt de respostes per defecte')}
            </label>
            <Link
              to="/field/response-sets"
              className="text-xs text-primary underline-offset-2 hover:underline"
            >
              {t('editor.manage_response_sets', 'Gestionar conjunts')}
            </Link>
          </div>
          <Select
            value={defaultResponseSetId}
            onValueChange={setDefaultResponseSetId}
            disabled={!isDraft}
          >
            <SelectTrigger><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value={NONE}>{t('editor.no_response_set', 'Cap')}</SelectItem>
              {responseSets.map((set) => (
                <SelectItem key={set.id} value={set.id}>{set.name}</SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      )}

      <div className="space-y-2">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <p className="text-sm font-medium">{t('editor.items', 'Ítems')}</p>
          {isDraft && (
            <div className="flex flex-wrap gap-2">
              {kind === 'review' && (
                <Button size="sm" variant="outline" className="gap-1" onClick={() => setPickerOpen(true)}>
                  <Plus className="h-4 w-4" />
                  {t('editor.add_points', 'Afegir punts')}
                </Button>
              )}
              {kind === 'todo' && (
                <Button
                  size="sm"
                  variant="outline"
                  className="gap-1"
                  onClick={() => setItems((prev) => [...prev, emptyTodoItem()])}
                >
                  <Plus className="h-4 w-4" />
                  {t('editor.add_item', 'Afegir')}
                </Button>
              )}
            </div>
          )}
        </div>

        {isDraft && items.length > 0 && (
          <div className="flex flex-wrap gap-2 text-xs">
            <Button
              size="sm"
              variant="ghost"
              onClick={() => setItems((prev) => prev.map((i) => ({ ...i, is_required: true })))}
            >
              {t('editor.bulk_required', 'Tots obligatoris')}
            </Button>
            <Button
              size="sm"
              variant="ghost"
              onClick={() => setItems((prev) => prev.map((i) => ({ ...i, include_in_report: true })))}
            >
              {t('editor.bulk_in_report', 'Tots al part del client')}
            </Button>
            {kind === 'review' && (
              <Button size="sm" variant="ghost" className="gap-1" onClick={() => void handleSyncPoints()}>
                <RefreshCw className="h-4 w-4" />
                {t('editor.sync_points', 'Actualitzar des del catàleg')}
              </Button>
            )}
          </div>
        )}

        {items.length === 0 && (
          <p className="text-sm text-muted-foreground">
            {kind === 'review'
              ? t('editor.empty_review_items', 'Afegeix punts del teu catàleg per començar.')
              : t('editor.empty_todo_items', 'Afegeix les tasques de la visita.')}
          </p>
        )}

        {items.map((item, index) => (
          <div key={item.key} className="space-y-2 rounded-lg border border-border p-3">
            <div className="flex items-start gap-2">
              {kind === 'review' ? (
                <p className="min-w-0 flex-1 text-sm font-medium">{item.title}</p>
              ) : (
                <Input
                  value={item.title}
                  disabled={!isDraft}
                  placeholder={t('editor.item_title', 'Títol')}
                  onChange={(e) => patchItem(item.key, { title: e.target.value })}
                />
              )}
              {isDraft && (
                <div className="flex shrink-0 gap-1">
                  <Button
                    size="icon"
                    variant="ghost"
                    aria-label={t('editor.move_up', 'Pujar')}
                    disabled={index === 0}
                    onClick={() => moveItem(index, -1)}
                  >
                    <ArrowUp className="h-4 w-4" />
                  </Button>
                  <Button
                    size="icon"
                    variant="ghost"
                    aria-label={t('editor.move_down', 'Baixar')}
                    disabled={index === items.length - 1}
                    onClick={() => moveItem(index, 1)}
                  >
                    <ArrowDown className="h-4 w-4" />
                  </Button>
                  <Button
                    size="icon"
                    variant="ghost"
                    aria-label={t('templates.delete', 'Eliminar')}
                    onClick={() => setItems((prev) => prev.filter((i) => i.key !== item.key))}
                  >
                    <Trash2 className="h-4 w-4" />
                  </Button>
                </div>
              )}
            </div>

            {kind === 'todo' && (
              <div className="grid gap-2 sm:grid-cols-2">
                <Textarea
                  placeholder={t('editor.description_internal', 'Descripció interna')}
                  value={item.description_internal ?? ''}
                  disabled={!isDraft}
                  rows={2}
                  onChange={(e) =>
                    patchItem(item.key, { description_internal: e.target.value || null })
                  }
                />
                <Textarea
                  placeholder={t('editor.description_public', 'Text per al part del client')}
                  value={item.description_public ?? ''}
                  disabled={!isDraft}
                  rows={2}
                  onChange={(e) => patchItem(item.key, { description_public: e.target.value || null })}
                />
              </div>
            )}

            {kind === 'review' && (
              <>
                <p className="text-xs text-muted-foreground">
                  {item.category} · {localeLabel(item.locale ?? locale)}
                </p>
                <div className="space-y-1.5">
                  <label className="text-xs font-medium">
                    {t('editor.item_response_set', 'Respostes (opcional, sobreescriu la per defecte)')}
                  </label>
                  <Select
                    value={item.response_set_id ?? NONE}
                    disabled={!isDraft}
                    onValueChange={(v) =>
                      patchItem(item.key, { response_set_id: v === NONE ? null : v })
                    }
                  >
                    <SelectTrigger><SelectValue /></SelectTrigger>
                    <SelectContent>
                      <SelectItem value={NONE}>
                        {t('editor.inherit_response_set', 'Heretar de la plantilla')}
                      </SelectItem>
                      {responseSets.map((set) => (
                        <SelectItem key={set.id} value={set.id}>{set.name}</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
              </>
            )}

            <div className="flex flex-wrap gap-3 text-xs">
              <label className="flex items-center gap-1">
                <input
                  type="checkbox"
                  checked={item.is_required === true}
                  disabled={!isDraft}
                  onChange={(e) => patchItem(item.key, { is_required: e.target.checked })}
                />
                {t('editor.required', 'Obligatori')}
              </label>
              <label className="flex items-center gap-1">
                <input
                  type="checkbox"
                  checked={item.include_in_report === true}
                  disabled={!isDraft}
                  onChange={(e) => patchItem(item.key, { include_in_report: e.target.checked })}
                />
                {t('editor.in_report', 'Incloure al part del client')}
              </label>
              <label className="flex items-center gap-1">
                <input
                  type="checkbox"
                  checked={item.evidence_required === true}
                  disabled={!isDraft}
                  onChange={(e) => patchItem(item.key, { evidence_required: e.target.checked })}
                />
                {t('editor.evidence_required', 'Requereix foto')}
              </label>
            </div>
          </div>
        ))}
      </div>
        </TabsContent>
      </Tabs>

      <div className="flex gap-2">
        {isDraft && editorTab === 'edit' && (
          <Button onClick={() => void handleSave()} disabled={saving}>
            {saving ? t('templates.saving', 'Desant…') : t('templates.save', 'Desar')}
          </Button>
        )}
        <Button variant="ghost" onClick={onClose}>{t('templates.cancel', 'Cancel·lar')}</Button>
      </div>

      <PointPickerDialog
        open={pickerOpen}
        tenantId={tenantId}
        selectedIds={selectedPointIds}
        templateLocale={locale}
        onOpenChange={setPickerOpen}
        onAdd={(points) => setItems((prev) => [...prev, ...points.map(itemFromPoint)])}
      />
    </div>
  )
}

function PlatformPreviewDialog({
  templateId,
  onOpenChange,
  onClone,
  cloning,
}: {
  templateId: string | null
  onOpenChange: (open: boolean) => void
  onClone: (templateId: string) => void
  cloning: boolean
}) {
  const { t } = useTranslation('field-service')
  const { data, isLoading } = useQuery({
    queryKey: ['checklist_platform_preview', templateId],
    queryFn: () => getPlatformTemplatePreview(templateId!),
    enabled: !!templateId,
  })

  const { data: responseSets = [] } = useQuery({
    queryKey: ['checklist_response_sets', 'platform'],
    queryFn: () => listPlatformResponseSets(),
    enabled: !!templateId,
  })

  return (
    <Dialog open={!!templateId} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90dvh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{data?.template.name ?? t('library.preview', 'Previsualització')}</DialogTitle>
          <DialogDescription>
            {data
              ? `${t(`editor.kind_${data.template.kind}`, data.template.kind)} · ${data.template.category} · ${localeLabel(data.template.locale)}`
              : ''}
          </DialogDescription>
        </DialogHeader>

        {isLoading ? (
          <p className="text-sm text-muted-foreground">{t('templates.loading', 'Carregant…')}</p>
        ) : data ? (
          <ChecklistTemplatePreview
            kind={data.template.kind}
            items={templateItemsToPreview(data.items)}
            responseSets={responseSets}
            defaultResponseSetId={data.version?.default_response_set_id ?? null}
          />
        ) : null}

        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            {t('templates.cancel', 'Cancel·lar')}
          </Button>
          <Button disabled={!templateId || cloning} onClick={() => templateId && onClone(templateId)}>
            {t('library.clone_edit', 'Clonar i editar')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function TenantPreviewDialog({
  templateId,
  tenantId,
  onOpenChange,
}: {
  templateId: string | null
  tenantId: string
  onOpenChange: (open: boolean) => void
}) {
  const { t } = useTranslation('field-service')
  const { data, isLoading } = useQuery({
    queryKey: ['checklist_template_preview', templateId],
    queryFn: () => getTemplateDetail(templateId!),
    enabled: !!templateId,
  })
  const { data: responseSets = [] } = useQuery({
    queryKey: ['checklist_response_sets', tenantId],
    queryFn: () => listResponseSets(tenantId),
    enabled: !!templateId,
  })

  return (
    <Dialog open={!!templateId} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90dvh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{data?.template.name ?? t('library.preview', 'Previsualització')}</DialogTitle>
          <DialogDescription>
            {data
              ? `${t(`editor.kind_${data.template.kind}`, data.template.kind)} · ${data.template.category} · ${localeLabel(data.template.locale)}`
              : t('editor.preview_hint', 'Pots provar respostes i notes aquí: no es desen enlloc.')}
          </DialogDescription>
        </DialogHeader>

        {isLoading || !data ? (
          <p className="text-sm text-muted-foreground">{t('templates.loading', 'Carregant…')}</p>
        ) : (
          <ChecklistTemplatePreview
            kind={data.template.kind}
            items={templateItemsToPreview(data.items)}
            responseSets={responseSets}
            defaultResponseSetId={data.editingVersion?.default_response_set_id ?? null}
          />
        )}

        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            {t('templates.cancel', 'Cancel·lar')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

export function ChecklistTemplatesPage() {
  const { t } = useTranslation('field-service')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const queryClient = useQueryClient()
  const tenantId = activeTenant?.id ?? null

  const [tab, setTab] = useState<'mine' | 'platform'>('mine')
  const [editingId, setEditingId] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)
  const [cloning, setCloning] = useState(false)
  const [previewId, setPreviewId] = useState<string | null>(null)
  const [tenantPreviewId, setTenantPreviewId] = useState<string | null>(null)
  const [q, setQ] = useState('')
  const [locale, setLocale] = useState(ALL)
  const [category, setCategory] = useState(ALL)
  const [page, setPage] = useState(0)

  const { data: templates = [], isLoading } = useQuery({
    queryKey: ['checklist_templates', tenantId],
    queryFn: () => listChecklistTemplates(tenantId!),
    enabled: !!tenantId,
  })

  const { data: forkStatus } = useQuery({
    queryKey: ['checklist_template_forks', tenantId],
    queryFn: () => listTemplateForkStatus(tenantId!),
    enabled: !!tenantId,
  })

  const platformFilters = {
    q: q.trim() || undefined,
    locale: locale === ALL ? undefined : locale,
    category: category === ALL ? undefined : category,
    limit: TEMPLATES_PAGE_SIZE,
    offset: page * TEMPLATES_PAGE_SIZE,
  }

  const { data: platformPage, isLoading: platformLoading } = useQuery({
    queryKey: ['checklist_platform_templates', platformFilters],
    queryFn: () => listPlatformTemplates(platformFilters),
    enabled: tab === 'platform',
  })

  const { data: platformCategories = [] } = useQuery({
    queryKey: ['checklist_template_categories', 'platform'],
    queryFn: () => listTemplateCategories(null),
    enabled: tab === 'platform',
  })

  const pageCount = Math.max(1, Math.ceil((platformPage?.total ?? 0) / TEMPLATES_PAGE_SIZE))

  async function invalidateTemplates() {
    await queryClient.invalidateQueries({ queryKey: ['checklist_templates'] })
    await queryClient.invalidateQueries({ queryKey: ['checklist_template_forks'] })
    await queryClient.invalidateQueries({ queryKey: ['published_checklist_templates'] })
  }

  async function handleCreate() {
    if (!tenantId) return
    setCreating(true)
    try {
      const id = await createTemplate({
        tenant_id: tenantId,
        name: t('checklist.template_default', 'Visita estàndard'),
        kind: 'todo',
      })
      await invalidateTemplates()
      setTab('mine')
      setEditingId(id)
    } catch {
      toast({ variant: 'destructive', description: t('templates.save_failed', 'Error en desar') })
    } finally {
      setCreating(false)
    }
  }

  async function handleClone(sourceId: string) {
    if (!tenantId) return
    setCloning(true)
    try {
      const id = await cloneTemplate(sourceId, tenantId)
      await invalidateTemplates()
      setPreviewId(null)
      setTab('mine')
      setEditingId(id)
      toast({ description: t('library.clone_success', 'Plantilla clonada') })
    } catch {
      toast({ variant: 'destructive', description: t('library.clone_failed', 'No s\'ha pogut clonar') })
    } finally {
      setCloning(false)
    }
  }

  async function handleArchive(id: string) {
    try {
      await archiveTemplate(id)
      await invalidateTemplates()
      if (editingId === id) setEditingId(null)
      toast({ description: t('templates.deleted', 'Plantilla eliminada') })
    } catch {
      toast({ variant: 'destructive', description: t('templates.delete_failed', 'No s\'ha pogut eliminar') })
    }
  }

  async function handleToggleDefault(tpl: ChecklistTemplate) {
    try {
      await setTemplateDefault(tpl.id, !tpl.is_default)
      await invalidateTemplates()
    } catch {
      toast({
        variant: 'destructive',
        description: t('editor.default_failed', 'No s\'ha pogut marcar com a per defecte'),
      })
    }
  }

  return (
    <div className="mx-auto max-w-5xl space-y-4 px-4 py-6 pb-24">
      <div className="flex items-start justify-between gap-3">
        <div>
          <Link to="/field/more" className="text-sm text-muted-foreground hover:underline">
            ← {t('more.title', 'Més')}
          </Link>
          <h1 className="mt-1 flex items-center gap-2 text-2xl font-bold">
            <ListChecks className="h-6 w-6" />
            {t('templates.title', 'Plantilles de checklist')}
          </h1>
          <p className="mt-1 text-sm text-muted-foreground">
            {t('editor.subtitle', 'Editor versionat amb publicació i biblioteca de plataforma.')}
          </p>
        </div>
        {!editingId && tab === 'mine' && (
          <Button
            size="sm"
            className="shrink-0 gap-1"
            onClick={() => void handleCreate()}
            disabled={creating || !tenantId}
          >
            <Plus className="h-4 w-4" />
            {t('templates.new', 'Nova')}
          </Button>
        )}
      </div>

      {editingId && tenantId ? (
        <TemplateEditor
          templateId={editingId}
          tenantId={tenantId}
          onClose={() => setEditingId(null)}
        />
      ) : (
        <Tabs value={tab} onValueChange={(v) => setTab(v as 'mine' | 'platform')}>
          <TabsList>
            <TabsTrigger value="mine">{t('templates.tab_mine', 'Les meves')}</TabsTrigger>
            <TabsTrigger value="platform">
              {t('templates.tab_platform', 'Biblioteca plataforma')}
            </TabsTrigger>
          </TabsList>

          <TabsContent value="mine" className="space-y-2">
            {isLoading ? (
              <p className="text-sm text-muted-foreground">{t('templates.loading', 'Carregant…')}</p>
            ) : templates.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                {t('templates.empty', 'Encara no hi ha plantilles.')}
              </p>
            ) : (
              <ul className="divide-y divide-border overflow-hidden rounded-2xl border border-border">
                {templates.map((tpl) => (
                  <li key={tpl.id} className="flex items-start gap-2 bg-card px-4 py-3">
                    <ChecklistKindIcon kind={tpl.kind} className="mt-1" />
                    <div className="min-w-0 flex-1">
                      <p className="flex flex-wrap items-center gap-2 font-medium">
                        <span className="truncate">{tpl.name}</span>
                        {tpl.is_default && (
                          <Badge variant="secondary">{t('editor.default', 'Per defecte')}</Badge>
                        )}
                        {forkStatus?.get(tpl.id)?.updateAvailable && (
                          <Badge variant="secondary" className="gap-1">
                            <RefreshCw className="h-3 w-3" />
                            {t('points.update_available', 'Actualització disponible')}
                          </Badge>
                        )}
                      </p>
                      <p className="text-xs text-muted-foreground">
                        {t(`editor.kind_${tpl.kind}`, tpl.kind)} · {tpl.category} ·{' '}
                        {localeLabel(tpl.locale)}
                      </p>
                    </div>
                    <Button
                      size="icon"
                      variant="ghost"
                      aria-label={t('library.preview', 'Previsualitzar')}
                      onClick={() => setTenantPreviewId(tpl.id)}
                    >
                      <Eye className="h-4 w-4" />
                    </Button>
                    <Button
                      size="icon"
                      variant="ghost"
                      aria-label={t('editor.is_default', 'Per defecte per a aquest tipus')}
                      className={tpl.is_default ? 'text-primary' : ''}
                      onClick={() => void handleToggleDefault(tpl)}
                    >
                      <Star className="h-4 w-4" />
                    </Button>
                    <Button
                      size="icon"
                      variant="ghost"
                      aria-label={t('templates.edit', 'Editar')}
                      onClick={() => setEditingId(tpl.id)}
                    >
                      <Pencil className="h-4 w-4" />
                    </Button>
                    <Button
                      size="icon"
                      variant="ghost"
                      className="text-destructive"
                      aria-label={t('templates.delete', 'Eliminar')}
                      onClick={() => void handleArchive(tpl.id)}
                    >
                      <Trash2 className="h-4 w-4" />
                    </Button>
                  </li>
                ))}
              </ul>
            )}
          </TabsContent>

          <TabsContent value="platform" className="space-y-3">
            <p className="text-xs text-muted-foreground">
              {t(
                'library.hint',
                'Les plantilles de plataforma no s\'apliquen directament: clona-les per poder-les usar i editar.',
              )}
            </p>

            <div className="grid gap-2 sm:grid-cols-3">
              <Input
                className="sm:col-span-3"
                value={q}
                placeholder={t('library.search', 'Cerca plantilles')}
                onChange={(e) => {
                  setQ(e.target.value)
                  setPage(0)
                }}
              />
              <Select
                value={locale}
                onValueChange={(v) => {
                  setLocale(v)
                  setPage(0)
                }}
              >
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  <SelectItem value={ALL}>{t('points.all_locales', 'Tots els idiomes')}</SelectItem>
                  {CHECKLIST_LOCALES.map((l) => (
                    <SelectItem key={l} value={l}>{localeLabel(l)}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <Select
                value={category}
                onValueChange={(v) => {
                  setCategory(v)
                  setPage(0)
                }}
              >
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  <SelectItem value={ALL}>
                    {t('points.all_categories', 'Totes les categories')}
                  </SelectItem>
                  {platformCategories.map((c) => (
                    <SelectItem key={c} value={c}>{c}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            {platformLoading ? (
              <p className="text-sm text-muted-foreground">{t('templates.loading', 'Carregant…')}</p>
            ) : (platformPage?.rows.length ?? 0) === 0 ? (
              <p className="text-sm text-muted-foreground">
                {t('library.empty', 'No hi ha plantilles de plataforma amb aquests filtres.')}
              </p>
            ) : (
              <ul className="divide-y divide-border overflow-hidden rounded-2xl border border-border">
                {(platformPage?.rows ?? []).map((tpl) => (
                  <li key={tpl.id} className="space-y-2 bg-card px-4 py-3">
                    <div className="flex items-start gap-2">
                      <ChecklistKindIcon kind={tpl.kind} className="mt-1" />
                      <div className="min-w-0 flex-1">
                        <p className="flex flex-wrap items-center gap-2 font-medium">
                          <span className="truncate">{tpl.name}</span>
                          <Badge variant="secondary">{t('library.platform', 'Plataforma')}</Badge>
                        </p>
                        <p className="text-xs text-muted-foreground">
                          {t(`editor.kind_${tpl.kind}`, tpl.kind)} · {tpl.category} ·{' '}
                          {localeLabel(tpl.locale)}
                        </p>
                      </div>
                    </div>
                    <div className="flex flex-wrap gap-2">
                      <Button
                        size="sm"
                        variant="outline"
                        className="gap-1"
                        onClick={() => setPreviewId(tpl.id)}
                      >
                        <Eye className="h-4 w-4" />
                        {t('library.preview', 'Previsualitzar')}
                      </Button>
                      <Button
                        size="sm"
                        className="gap-1"
                        disabled={cloning || !tenantId}
                        onClick={() => void handleClone(tpl.id)}
                      >
                        <Copy className="h-4 w-4" />
                        {t('library.clone_edit', 'Clonar i editar')}
                      </Button>
                    </div>
                  </li>
                ))}
              </ul>
            )}

            {(platformPage?.total ?? 0) > TEMPLATES_PAGE_SIZE && (
              <div className="flex items-center justify-between gap-2 text-sm">
                <Button size="sm" variant="outline" disabled={page === 0} onClick={() => setPage(page - 1)}>
                  {t('points.prev', 'Anterior')}
                </Button>
                <span className="text-muted-foreground">
                  {t('points.page_of', 'Pàgina {{page}} de {{pages}}', {
                    page: page + 1,
                    pages: pageCount,
                  })}
                </span>
                <Button
                  size="sm"
                  variant="outline"
                  disabled={page + 1 >= pageCount}
                  onClick={() => setPage(page + 1)}
                >
                  {t('points.next', 'Següent')}
                </Button>
              </div>
            )}
          </TabsContent>
        </Tabs>
      )}

      <PlatformPreviewDialog
        templateId={previewId}
        cloning={cloning}
        onOpenChange={(open) => !open && setPreviewId(null)}
        onClone={(id) => void handleClone(id)}
      />
      {tenantId && (
        <TenantPreviewDialog
          templateId={tenantPreviewId}
          tenantId={tenantId}
          onOpenChange={(open) => !open && setTenantPreviewId(null)}
        />
      )}
    </div>
  )
}
