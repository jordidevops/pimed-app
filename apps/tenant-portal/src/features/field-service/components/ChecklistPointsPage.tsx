import { useEffect, useMemo, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router-dom'
import { Copy, Languages, ListTree, Plus, RefreshCw } from 'lucide-react'
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
import { AIGenerateAction } from '@/features/ai/components/AIGenerateAction'
import {
  CHECKLIST_LOCALES,
  POINTS_PAGE_SIZE,
  archiveOrDeletePoint,
  clonePoint,
  createPoint,
  listPlatformPoints,
  listPointCategories,
  listPointForkStatus,
  listPointUsage,
  listTenantPoints,
  updatePoint,
  type ChecklistLocale,
  type ChecklistReviewPoint,
} from '../api/checklistPointsService'

const ALL = '__all__'

type PointScope = 'tenant' | 'platform'

interface PointFilters {
  q: string
  locale: string
  category: string
  page: number
}

const EMPTY_FILTERS: PointFilters = { q: '', locale: ALL, category: ALL, page: 0 }

const LOCALE_LABELS: Record<ChecklistLocale, string> = {
  ca: 'Català',
  es: 'Castellà',
  en: 'English',
}

function localeLabel(locale: string): string {
  return LOCALE_LABELS[locale as ChecklistLocale] ?? locale.toUpperCase()
}

function FiltersBar({
  filters,
  categories,
  onChange,
}: {
  filters: PointFilters
  categories: string[]
  onChange: (next: PointFilters) => void
}) {
  const { t } = useTranslation('field-service')

  return (
    <section className="space-y-3 rounded-2xl border border-border bg-card p-4 shadow-sm">
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <div className="space-y-1.5 sm:col-span-2">
          <label className="text-sm font-medium">{t('points.search_label', 'Cercar')}</label>
          <Input
            value={filters.q}
            placeholder={t('points.search', 'Títol o descripció')}
            onChange={(e) => onChange({ ...filters, q: e.target.value, page: 0 })}
          />
        </div>
        <div className="space-y-1.5">
          <label className="text-sm font-medium">{t('points.locale', 'Idioma')}</label>
          <Select
            value={filters.locale}
            onValueChange={(v) => onChange({ ...filters, locale: v, page: 0 })}
          >
            <SelectTrigger>
              <SelectValue placeholder={t('points.locale', 'Idioma')} />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value={ALL}>{t('points.all_locales', 'Tots els idiomes')}</SelectItem>
              {CHECKLIST_LOCALES.map((l) => (
                <SelectItem key={l} value={l}>{localeLabel(l)}</SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-1.5">
          <label className="text-sm font-medium">{t('points.category', 'Categoria')}</label>
          <Select
            value={filters.category}
            onValueChange={(v) => onChange({ ...filters, category: v, page: 0 })}
          >
            <SelectTrigger>
              <SelectValue placeholder={t('points.category', 'Categoria')} />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value={ALL}>{t('points.all_categories', 'Totes les categories')}</SelectItem>
              {categories.map((c) => (
                <SelectItem key={c} value={c}>{c}</SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      </div>
    </section>
  )
}

function Pagination({
  page,
  total,
  onPage,
}: {
  page: number
  total: number
  onPage: (next: number) => void
}) {
  const { t } = useTranslation('field-service')
  const pageCount = Math.max(1, Math.ceil(total / POINTS_PAGE_SIZE))

  return (
    <div className="flex items-center justify-between gap-2 text-xs text-muted-foreground">
      <span>{t('points.results_count', '{{count}} resultats', { count: total })}</span>
      {total > POINTS_PAGE_SIZE && (
        <div className="flex items-center gap-2">
          <Button size="sm" variant="outline" disabled={page === 0} onClick={() => onPage(page - 1)}>
            {t('points.prev', 'Anterior')}
          </Button>
          <span className="tabular-nums">
            {t('points.page_of', 'Pàgina {{page}} de {{pages}}', { page: page + 1, pages: pageCount })}
          </span>
          <Button
            size="sm"
            variant="outline"
            disabled={page + 1 >= pageCount}
            onClick={() => onPage(page + 1)}
          >
            {t('points.next', 'Següent')}
          </Button>
        </div>
      )}
    </div>
  )
}

function PointEditorDialog({
  open,
  point,
  tenantId,
  onOpenChange,
  onSaved,
}: {
  open: boolean
  point: ChecklistReviewPoint | null
  tenantId: string
  onOpenChange: (open: boolean) => void
  onSaved: () => void
}) {
  const { t } = useTranslation('field-service')
  const { toast } = useToast()
  const [title, setTitle] = useState('')
  const [description, setDescription] = useState('')
  const [clientText, setClientText] = useState('')
  const [locale, setLocale] = useState<ChecklistLocale>('ca')
  const [category, setCategory] = useState('general')
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    if (!open) return
    setTitle(point?.title ?? '')
    setDescription(point?.description ?? '')
    setClientText(point?.client_text ?? '')
    setLocale(point?.locale ?? 'ca')
    setCategory(point?.category ?? 'general')
  }, [open, point])

  const { data: usage = [] } = useQuery({
    queryKey: ['checklist_point_usage', point?.id],
    queryFn: () => listPointUsage(point!.id),
    enabled: open && !!point?.id,
  })

  async function handleSave() {
    if (!title.trim()) {
      toast({ variant: 'destructive', description: t('points.title_required', 'Cal un títol') })
      return
    }
    setSaving(true)
    try {
      if (point) {
        await updatePoint(point.id, {
          title,
          description,
          client_text: clientText,
          locale,
          category,
        })
      } else {
        await createPoint({
          tenant_id: tenantId,
          title,
          description,
          client_text: clientText,
          locale,
          category,
        })
      }
      toast({ description: t('points.saved', 'Punt desat') })
      onSaved()
      onOpenChange(false)
    } catch (err) {
      const msg = err instanceof Error ? err.message : t('points.save_failed', 'Error en desar')
      toast({ variant: 'destructive', description: msg })
    } finally {
      setSaving(false)
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90dvh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {point ? t('points.edit', 'Editar punt') : t('points.new', 'Nou punt')}
          </DialogTitle>
          <DialogDescription>
            {t(
              'points.editor_hint',
              'La descripció interna la veu el tècnic; el text per al client surt al part.',
            )}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-3">
          <div className="space-y-1.5">
            <label className="text-sm font-medium">{t('points.field_title', 'Títol')}</label>
            <Input value={title} onChange={(e) => setTitle(e.target.value)} />
          </div>
          <div className="space-y-1.5">
            <label className="text-sm font-medium">
              {t('points.field_description', 'Descripció interna')}
            </label>
            <Textarea
              rows={3}
              value={description}
              onChange={(e) => setDescription(e.target.value)}
            />
          </div>
          <div className="space-y-1.5">
            <label className="text-sm font-medium">
              {t('points.field_client_text', 'Text per al part del client')}
            </label>
            <Textarea rows={2} value={clientText} onChange={(e) => setClientText(e.target.value)} />
          </div>
          <div className="grid gap-3 sm:grid-cols-2">
            <div className="space-y-1.5">
              <label className="text-sm font-medium">{t('points.locale', 'Idioma')}</label>
              <Select value={locale} onValueChange={(v) => setLocale(v as ChecklistLocale)}>
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
              <Input value={category} onChange={(e) => setCategory(e.target.value)} />
            </div>
          </div>

          {usage.length > 0 && (
            <div className="rounded-lg border border-border p-3 space-y-1">
              <p className="text-sm font-medium">{t('points.usage', 'Usat a')}</p>
              {usage.map((u) => (
                <p key={`${u.templateId}-${u.versionNumber}`} className="text-xs text-muted-foreground">
                  {u.templateName} · v{u.versionNumber} · {u.versionStatus}
                </p>
              ))}
            </div>
          )}
        </div>

        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            {t('templates.cancel', 'Cancel·lar')}
          </Button>
          <Button onClick={() => void handleSave()} disabled={saving}>
            {saving ? t('templates.saving', 'Desant…') : t('templates.save', 'Desar')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

type TranslatedPoint = { title?: string; description?: string; client_text?: string }

function parseTranslation(content: string): TranslatedPoint | null {
  const cleaned = content.trim().replace(/^```(?:json)?/i, '').replace(/```$/, '').trim()
  try {
    const parsed = JSON.parse(cleaned) as TranslatedPoint
    if (parsed && typeof parsed === 'object') return parsed
  } catch {
    return null
  }
  return null
}

function ClonePointDialog({
  open,
  point,
  tenantId,
  onOpenChange,
  onCloned,
}: {
  open: boolean
  point: ChecklistReviewPoint | null
  tenantId: string
  onOpenChange: (open: boolean) => void
  onCloned: () => void
}) {
  const { t } = useTranslation('field-service')
  const { toast } = useToast()
  const [targetLocale, setTargetLocale] = useState<ChecklistLocale>('es')
  const [working, setWorking] = useState(false)

  useEffect(() => {
    if (open) setTargetLocale(point?.locale === 'es' ? 'ca' : 'es')
  }, [open, point])

  async function applyTranslation(translated: TranslatedPoint) {
    if (!point) return
    setWorking(true)
    try {
      const newId = await clonePoint({
        sourcePointId: point.id,
        tenantId,
        locale: targetLocale,
        title: translated.title?.trim() || point.title,
      })
      await updatePoint(newId, {
        description: translated.description ?? point.description,
        client_text: translated.client_text ?? point.client_text,
      })
      toast({ description: t('points.clone_translated', 'Punt clonat i traduït') })
      onCloned()
      onOpenChange(false)
    } catch (err) {
      const msg = err instanceof Error ? err.message : t('points.clone_failed', 'No s\'ha pogut clonar')
      toast({ variant: 'destructive', description: msg })
    } finally {
      setWorking(false)
    }
  }

  const messages = useMemo(() => {
    if (!point) return []
    return [
      {
        role: 'system' as const,
        content:
          'Ets un traductor tècnic de manteniment i serveis de camp. Respon NOMÉS amb un objecte JSON '
          + 'amb les claus "title", "description" i "client_text". No afegeixis text fora del JSON.',
      },
      {
        role: 'user' as const,
        content: `Tradueix del ${point.locale} al ${targetLocale} aquest punt de revisió:\n`
          + JSON.stringify({
            title: point.title,
            description: point.description ?? '',
            client_text: point.client_text ?? '',
          }),
      },
    ]
  }, [point, targetLocale])

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{t('points.clone_translate', 'Clonar i traduir amb IA')}</DialogTitle>
          <DialogDescription>{point?.title}</DialogDescription>
        </DialogHeader>

        <div className="space-y-3">
          <div className="space-y-1.5">
            <label className="text-sm font-medium">{t('points.target_locale', 'Idioma destí')}</label>
            <Select
              value={targetLocale}
              onValueChange={(v) => setTargetLocale(v as ChecklistLocale)}
            >
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>
                {CHECKLIST_LOCALES.map((l) => (
                  <SelectItem key={l} value={l}>{localeLabel(l)}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <AIGenerateAction
            feature="checklist_point_translation"
            messages={messages}
            responseFormat="json"
            disabled={!point || working}
            label={t('points.translate_and_clone', 'Traduir i clonar')}
            onSuccess={(result) => {
              const parsed = parseTranslation(result.content)
              if (!parsed) {
                toast({
                  variant: 'destructive',
                  description: t('points.translate_parse_failed', 'La IA no ha retornat un JSON vàlid'),
                })
                return
              }
              void applyTranslation(parsed)
            }}
          />

          <p className="text-xs text-muted-foreground">
            {t(
              'points.translate_hint',
              'Si prefereixes traduir-ho manualment, clona el punt i edita\'l després.',
            )}
          </p>
        </div>

        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            {t('templates.cancel', 'Cancel·lar')}
          </Button>
          <Button
            variant="outline"
            disabled={!point || working}
            onClick={() => void applyTranslation({})}
          >
            {t('points.clone_only', 'Clonar sense traduir')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function PlatformPreviewDialog({
  point,
  onOpenChange,
}: {
  point: ChecklistReviewPoint | null
  onOpenChange: (open: boolean) => void
}) {
  const { t } = useTranslation('field-service')

  return (
    <Dialog open={!!point} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{point?.title}</DialogTitle>
          <DialogDescription>
            {point ? `${point.category} · ${localeLabel(point.locale)}` : ''}
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-3 text-sm">
          <div>
            <p className="font-medium">{t('points.field_description', 'Descripció interna')}</p>
            <p className="text-muted-foreground whitespace-pre-line">
              {point?.description || t('points.no_description', 'Sense descripció')}
            </p>
          </div>
          <div>
            <p className="font-medium">{t('points.field_client_text', 'Text per al part del client')}</p>
            <p className="text-muted-foreground whitespace-pre-line">
              {point?.client_text || t('points.no_client_text', 'Sense text per al client')}
            </p>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  )
}

export function ChecklistPointsPage() {
  const { t } = useTranslation('field-service')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const queryClient = useQueryClient()
  const tenantId = activeTenant?.id ?? null

  const [scope, setScope] = useState<PointScope>('tenant')
  const [tenantFilters, setTenantFilters] = useState<PointFilters>(EMPTY_FILTERS)
  const [platformFilters, setPlatformFilters] = useState<PointFilters>(EMPTY_FILTERS)
  const [editorOpen, setEditorOpen] = useState(false)
  const [editingPoint, setEditingPoint] = useState<ChecklistReviewPoint | null>(null)
  const [cloneTarget, setCloneTarget] = useState<ChecklistReviewPoint | null>(null)
  const [previewPoint, setPreviewPoint] = useState<ChecklistReviewPoint | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)

  const filters = scope === 'tenant' ? tenantFilters : platformFilters
  const setFilters = scope === 'tenant' ? setTenantFilters : setPlatformFilters

  const queryFilters = {
    q: filters.q.trim() || undefined,
    locale: filters.locale === ALL ? undefined : filters.locale,
    category: filters.category === ALL ? undefined : filters.category,
    limit: POINTS_PAGE_SIZE,
    offset: filters.page * POINTS_PAGE_SIZE,
  }

  const { data: tenantPage, isLoading: tenantLoading } = useQuery({
    queryKey: ['checklist_points', 'tenant', tenantId, queryFilters],
    queryFn: () => listTenantPoints(tenantId!, queryFilters),
    enabled: !!tenantId && scope === 'tenant',
  })

  const { data: platformPage, isLoading: platformLoading } = useQuery({
    queryKey: ['checklist_points', 'platform', queryFilters],
    queryFn: () => listPlatformPoints(queryFilters),
    enabled: scope === 'platform',
  })

  const { data: categories = [] } = useQuery({
    queryKey: ['checklist_point_categories', scope, tenantId],
    queryFn: () => listPointCategories(scope === 'tenant' ? tenantId : null),
    enabled: scope === 'platform' || !!tenantId,
  })

  const { data: forkStatus } = useQuery({
    queryKey: ['checklist_point_forks', tenantId],
    queryFn: () => listPointForkStatus(tenantId!),
    enabled: !!tenantId,
  })

  async function invalidatePoints() {
    await queryClient.invalidateQueries({ queryKey: ['checklist_points'] })
    await queryClient.invalidateQueries({ queryKey: ['checklist_point_forks'] })
    await queryClient.invalidateQueries({ queryKey: ['checklist_point_categories'] })
  }

  async function handleClone(point: ChecklistReviewPoint) {
    if (!tenantId) return
    setBusyId(point.id)
    try {
      await clonePoint({ sourcePointId: point.id, tenantId })
      await invalidatePoints()
      toast({ description: t('points.cloned', 'Punt clonat al teu catàleg') })
    } catch (err) {
      const msg = err instanceof Error ? err.message : t('points.clone_failed', 'No s\'ha pogut clonar')
      toast({ variant: 'destructive', description: msg })
    } finally {
      setBusyId(null)
    }
  }

  async function handleDelete(point: ChecklistReviewPoint) {
    if (!window.confirm(t('points.delete_confirm', 'Segur que vols eliminar aquest punt?'))) return
    setBusyId(point.id)
    try {
      const result = await archiveOrDeletePoint(point.id)
      await invalidatePoints()
      toast({
        description:
          result === 'archived'
            ? t('points.archived', 'Punt arxivat (encara s\'usa en alguna plantilla)')
            : t('points.deleted', 'Punt eliminat'),
      })
    } catch (err) {
      const msg = err instanceof Error ? err.message : t('points.delete_failed', 'No s\'ha pogut eliminar')
      toast({ variant: 'destructive', description: msg })
    } finally {
      setBusyId(null)
    }
  }

  function StatusChip({ point }: { point: ChecklistReviewPoint }) {
    if (point.is_archived) {
      return <Badge variant="secondary">{t('points.status_archived', 'Arxivat')}</Badge>
    }
    if (point.is_active) {
      return (
        <Badge className="border-transparent bg-emerald-50 text-emerald-700 hover:bg-emerald-50">
          {t('points.status_active', 'Actiu')}
        </Badge>
      )
    }
    return <Badge variant="outline">{t('points.status_inactive', 'Inactiu')}</Badge>
  }

  function PointsTable({ rows }: { rows: ChecklistReviewPoint[] }) {
    const isTenant = scope === 'tenant'

    return (
      <div className="overflow-x-auto rounded-xl border border-border bg-card shadow-sm">
        <table className="min-w-full divide-y divide-border text-sm">
          <thead className="bg-muted/40">
            <tr>
              <th className="px-4 py-3 text-left font-medium text-muted-foreground">
                {t('points.col_title', 'Títol')}
              </th>
              <th className="px-4 py-3 text-left font-medium text-muted-foreground">
                {t('points.col_taxonomy', 'Taxonomia')}
              </th>
              <th className="px-4 py-3 text-left font-medium text-muted-foreground">
                {t('points.locale', 'Idioma')}
              </th>
              <th className="px-4 py-3 text-left font-medium text-muted-foreground">
                {t('points.col_usage', 'Ús')}
              </th>
              <th className="px-4 py-3 text-left font-medium text-muted-foreground">
                {t('points.col_status', 'Estat')}
              </th>
              <th className="px-4 py-3 text-right font-medium text-muted-foreground">
                {t('points.col_actions', 'Accions')}
              </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {rows.map((point) => {
              const status = isTenant ? forkStatus?.get(point.id) : undefined
              return (
                <tr
                  key={point.id}
                  className={point.is_archived ? 'opacity-60' : undefined}
                >
                  <td className="px-4 py-3 align-top">
                    <button
                      type="button"
                      className="block w-full text-left"
                      onClick={() => {
                        if (isTenant) {
                          setEditingPoint(point)
                          setEditorOpen(true)
                        } else {
                          setPreviewPoint(point)
                        }
                      }}
                    >
                      <p className="font-medium text-foreground flex flex-wrap items-center gap-2">
                        <span>{point.title}</span>
                        {status?.updateAvailable && (
                          <Badge variant="secondary" className="gap-1 font-normal">
                            <RefreshCw className="h-3 w-3" />
                            {t('points.update_available', 'Actualització disponible')}
                          </Badge>
                        )}
                      </p>
                      {point.description && (
                        <p className="mt-0.5 max-w-xl text-xs text-muted-foreground line-clamp-2">
                          {point.description}
                        </p>
                      )}
                    </button>
                  </td>
                  <td className="px-4 py-3 align-top">
                    <div className="flex flex-wrap gap-1">
                      <Badge variant="secondary" className="font-normal">{point.category}</Badge>
                      {point.vertical && point.vertical !== 'generic' && (
                        <Badge variant="outline" className="font-normal">{point.vertical}</Badge>
                      )}
                    </div>
                  </td>
                  <td className="px-4 py-3 align-top text-muted-foreground whitespace-nowrap">
                    {localeLabel(point.locale)}
                    <span className="ml-1 text-xs text-muted-foreground/70">
                      v{point.catalog_version}
                    </span>
                  </td>
                  <td className="px-4 py-3 align-top tabular-nums text-muted-foreground">
                    {point.usage_count ?? 0}
                  </td>
                  <td className="px-4 py-3 align-top">
                    <StatusChip point={point} />
                  </td>
                  <td className="px-4 py-3 align-top">
                    <div className="flex flex-wrap justify-end gap-2">
                      {isTenant ? (
                        <>
                          <Button
                            size="sm"
                            variant="outline"
                            disabled={busyId === point.id}
                            onClick={() => {
                              setEditingPoint(point)
                              setEditorOpen(true)
                            }}
                          >
                            {t('points.edit', 'Editar')}
                          </Button>
                          <Button
                            size="sm"
                            variant="outline"
                            className="text-destructive hover:text-destructive"
                            disabled={busyId === point.id}
                            onClick={() => void handleDelete(point)}
                          >
                            {t('templates.delete', 'Eliminar')}
                          </Button>
                        </>
                      ) : (
                        <>
                          <Button
                            size="sm"
                            variant="outline"
                            className="gap-1"
                            disabled={busyId === point.id || !tenantId}
                            onClick={() => void handleClone(point)}
                          >
                            <Copy className="h-3.5 w-3.5" />
                            {t('points.clone', 'Clonar')}
                          </Button>
                          <Button
                            size="sm"
                            variant="ghost"
                            className="gap-1"
                            disabled={!tenantId}
                            onClick={() => setCloneTarget(point)}
                          >
                            <Languages className="h-3.5 w-3.5" />
                            {t('points.clone_translate_short', 'Traduir IA')}
                          </Button>
                        </>
                      )}
                    </div>
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
    )
  }

  const page = scope === 'tenant' ? tenantPage : platformPage
  const isLoading = scope === 'tenant' ? tenantLoading : platformLoading

  return (
    <div className="mx-auto max-w-5xl space-y-4 px-4 py-6 pb-24">
      <div className="flex items-start justify-between gap-3">
        <div>
          <Link to="/field/more" className="text-sm text-muted-foreground hover:underline">
            ← {t('more.title', 'Més')}
          </Link>
          <h1 className="mt-1 text-2xl font-bold flex items-center gap-2">
            <ListTree className="h-6 w-6" />
            {t('points.title', 'Punts de revisió')}
          </h1>
          <p className="mt-1 text-sm text-muted-foreground">
            {t(
              'points.subtitle',
              'Catàleg reutilitzable de punts per a les checklists de revisió.',
            )}
          </p>
        </div>
        {scope === 'tenant' && (
          <Button
            size="sm"
            className="gap-1 shrink-0"
            disabled={!tenantId}
            onClick={() => {
              setEditingPoint(null)
              setEditorOpen(true)
            }}
          >
            <Plus className="h-4 w-4" />
            {t('points.new', 'Nou punt')}
          </Button>
        )}
      </div>

      <Tabs value={scope} onValueChange={(v) => setScope(v as PointScope)}>
        <TabsList>
          <TabsTrigger value="tenant">{t('points.tab_mine', 'Els meus punts')}</TabsTrigger>
          <TabsTrigger value="platform">
            {t('points.tab_platform', 'Punts de la plataforma')}
          </TabsTrigger>
        </TabsList>

        <TabsContent value={scope} className="space-y-3">
          <FiltersBar filters={filters} categories={categories} onChange={setFilters} />

          {isLoading ? (
            <p className="text-sm text-muted-foreground">{t('templates.loading', 'Carregant…')}</p>
          ) : (page?.rows.length ?? 0) === 0 ? (
            <div className="rounded-xl border border-dashed border-border bg-card px-4 py-10 text-center text-sm text-muted-foreground">
              {scope === 'tenant'
                ? t('points.empty_tenant', 'Encara no tens punts. Crea\'n un o clona\'l de la plataforma.')
                : t('points.empty_platform', 'No hi ha punts de plataforma amb aquests filtres.')}
            </div>
          ) : (
            <PointsTable rows={page?.rows ?? []} />
          )}

          <Pagination
            page={filters.page}
            total={page?.total ?? 0}
            onPage={(next) => setFilters({ ...filters, page: next })}
          />
        </TabsContent>
      </Tabs>

      {tenantId && (
        <PointEditorDialog
          open={editorOpen}
          point={editingPoint}
          tenantId={tenantId}
          onOpenChange={setEditorOpen}
          onSaved={() => void invalidatePoints()}
        />
      )}

      {tenantId && (
        <ClonePointDialog
          open={!!cloneTarget}
          point={cloneTarget}
          tenantId={tenantId}
          onOpenChange={(open) => !open && setCloneTarget(null)}
          onCloned={() => void invalidatePoints()}
        />
      )}

      <PlatformPreviewDialog
        point={previewPoint}
        onOpenChange={(open) => !open && setPreviewPoint(null)}
      />
    </div>
  )
}
