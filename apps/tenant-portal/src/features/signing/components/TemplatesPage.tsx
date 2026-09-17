import { useState, useMemo } from 'react'
import { useNavigate } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Copy, FilePlus2, Trash2, ChevronRight, FileText, Globe, AlertTriangle, Search, X, Tag } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useDocumentTemplates } from '../api/useDocumentTemplates'
import {
  useCloneTemplateMutation,
  useDeleteTemplateMutation,
} from '../api/useDocumentTemplateMutations'
import { TemplateFormModal } from './TemplateFormModal'
import { DocumentsSubNav } from '@/features/documents/components/DocumentsSubNav'
import type { DocumentTemplateWithLocales } from '../api/signingService'
import {
  isFullBodyTemplateCategory,
  templateCategoryLabel,
  templateKindLabel,
} from '../utils/templateCategories'
import { parseCommercialTemplateLegalGaps } from '@/features/commercial/utils/rpcError'

// ─── Template card ─────────────────────────────────────────────────────────────

function TemplateCard({
  template,
  canWrite,
  tenantId,
  onDelete,
  onClone,
}: {
  template:  DocumentTemplateWithLocales
  canWrite:  boolean
  tenantId:  string
  onDelete:  (t: DocumentTemplateWithLocales) => void
  onClone:   (t: DocumentTemplateWithLocales) => void
}) {
  const { t }    = useTranslation('signing')
  const navigate = useNavigate()

  const isPlatform = !!template.is_platform_default
  const isOwn      = !isPlatform && template.tenant_id === tenantId

  return (
    <div
      className="rounded-xl border bg-card overflow-hidden hover:bg-accent/30 transition-colors cursor-pointer"
      onClick={() => navigate(`/documents/templates/${template.id}`)}
      role="button"
      tabIndex={0}
      onKeyDown={e => e.key === 'Enter' && navigate(`/documents/templates/${template.id}`)}
    >
      <div className="flex items-center gap-3 px-4 py-3">
        <Globe className="h-4 w-4 text-muted-foreground shrink-0" />
        <div className="flex-1 min-w-0">
          <p className="font-medium text-sm truncate">{template.name}</p>
          {template.description && (
            <p className="text-xs text-muted-foreground truncate">{template.description}</p>
          )}
          <div className="flex flex-wrap gap-1 mt-1.5">
            {template.locales.length === 0 ? (
              <span className="inline-flex items-center gap-1 text-[10px] font-medium bg-amber-100 text-amber-700 dark:bg-amber-900/40 dark:text-amber-400 px-1.5 py-0.5 rounded">
                <AlertTriangle className="h-2.5 w-2.5" />
                {t('template.noLocales', 'Sense locales')}
              </span>
            ) : (
              template.locales.map(l => (
                <span
                  key={l.id}
                  className={`text-[10px] font-mono px-1.5 py-0.5 rounded uppercase ${
                    l.is_active
                      ? 'bg-slate-100 text-slate-700 dark:bg-slate-800 dark:text-slate-300'
                      : 'bg-muted text-muted-foreground line-through'
                  }`}
                >
                  {l.locale}
                </span>
              ))
            )}
          </div>
        </div>
          {isFullBodyTemplateCategory(template.category) ? (
            <span className="text-[10px] font-semibold px-2 py-0.5 rounded bg-teal-100 text-teal-800">
              {templateKindLabel(t, template.category)}
            </span>
          ) : template.category ? (
            <span className="text-xs text-muted-foreground bg-muted px-2 py-0.5 rounded">
              {templateCategoryLabel(t, template.category)}
            </span>
          ) : null}
        <span className={`text-[10px] font-semibold px-2 py-0.5 rounded uppercase ${isPlatform ? 'bg-indigo-100 text-indigo-700' : 'bg-amber-100 text-amber-700'}`}>
          {isPlatform ? t('template.platform_badge', 'Sistema') : t('template.own_badge', 'Pròpia')}
        </span>
        <span className={`text-[10px] font-mono font-semibold px-2 py-0.5 rounded uppercase ${
          template.template_type === 'html' ? 'bg-emerald-100 text-emerald-700' : 'bg-sky-100 text-sky-700'
        }`}>
          {(template.template_type ?? 'docx').toUpperCase()}
        </span>

        {canWrite && isPlatform && (
          <Button
            variant="outline"
            size="sm"
            className="h-7 text-xs shrink-0"
            onClick={e => { e.stopPropagation(); onClone(template) }}
          >
            <Copy className="h-3.5 w-3.5 mr-1" />
            {t('template.clone', 'Clonar per personalitzar')}
          </Button>
        )}

        {canWrite && isOwn && (
          <Button
            variant="ghost"
            size="sm"
            className="h-7 text-destructive hover:text-destructive shrink-0"
            onClick={e => { e.stopPropagation(); onDelete(template) }}
          >
            <Trash2 className="h-3.5 w-3.5" />
          </Button>
        )}

        <ChevronRight className="h-4 w-4 text-muted-foreground shrink-0" />
      </div>
    </div>
  )
}

// ─── TemplatesPage ─────────────────────────────────────────────────────────────

export function TemplatesPage() {
  const { t }   = useTranslation('signing')
  const { t: tDocuments } = useTranslation('documents')
  const { toast } = useToast()
  const { activeTenant, activeRole } = useTenant()
  const tenantId = activeTenant?.id ?? ''
  const canWrite = activeRole === 'owner' || activeRole === 'manager'
  const tenantArchetype   = activeTenant?.archetype ?? null
  const tenantVertical    = activeTenant?.sector_vertical ?? null

  const { data: templates = [], isLoading } = useDocumentTemplates(tenantId || undefined)
  const cloneMutation  = useCloneTemplateMutation(tenantId)
  const deleteMutation = useDeleteTemplateMutation(tenantId)

  const [formMode,     setFormMode]     = useState<{ kind: 'create_template' } | null>(null)
  const [deleteTarget, setDeleteTarget] = useState<DocumentTemplateWithLocales | null>(null)
  const [searchQuery,  setSearchQuery]  = useState('')
  const [typeFilter,   setTypeFilter]   = useState<'all' | 'html' | 'docx'>('all')
  const [catFilter,    setCatFilter]    = useState<string>('')
  const [sortBy,       setSortBy]       = useState<'name' | 'date'>('date')
  const [sectorOnly,   setSectorOnly]   = useState(false)

  const allCategories = useMemo(() => {
    const cats = new Set<string>()
    templates.forEach(t => { if (t.category) cats.add(t.category) })
    return Array.from(cats).sort()
  }, [templates])

  function applyFilters(list: DocumentTemplateWithLocales[]) {
    let filtered = list
    if (sectorOnly && (tenantArchetype || tenantVertical)) {
      filtered = filtered.filter(t => {
        const ta = t.target_archetypes
        const tv = t.target_verticals
        const normArchetype = tenantArchetype?.toLowerCase() ?? null
        const normVertical = tenantVertical?.toLowerCase() ?? null
        const normTa = ta?.map(v => v.toLowerCase())
        const normTv = tv?.map(v => v.toLowerCase())
        // NULL = universal → always show; otherwise check intersection
        const archetypeMatch = !normTa || !normArchetype || normTa.includes(normArchetype)
        const verticalMatch  = !normTv || !normVertical  || normTv.includes(normVertical)
        return archetypeMatch && verticalMatch
      })
    }
    if (searchQuery.trim()) {
      const q = searchQuery.toLowerCase()
      filtered = filtered.filter(t =>
        (t.name ?? '').toLowerCase().includes(q) ||
        (t.description ?? '').toLowerCase().includes(q)
      )
    }
    if (typeFilter !== 'all') {
      filtered = filtered.filter(t => (t.template_type ?? 'docx') === typeFilter)
    }
    if (catFilter) {
      filtered = filtered.filter(t => t.category === catFilter)
    }
    if (sortBy === 'name') {
      filtered = [...filtered].sort((a, b) => (a.name ?? '').localeCompare(b.name ?? '', 'ca'))
    } else {
      filtered = [...filtered].sort((a, b) => {
        const da = a.created_at ? new Date(a.created_at).getTime() : 0
        const db = b.created_at ? new Date(b.created_at).getTime() : 0
        return db - da
      })
    }
    return filtered
  }

  const platformTemplates = applyFilters(templates.filter(t => t.is_platform_default))
  const tenantTemplates   = applyFilters(templates.filter(t => !t.is_platform_default))

  // ── Handlers ─────────────────────────────────────────────────────────────────

  async function handleClone(tmpl: DocumentTemplateWithLocales) {
    try {
      const { copiedLocales } = await cloneMutation.mutateAsync(tmpl)
      const desc = copiedLocales > 0
        ? t('template.clonedWithLocales', 'Plantilla clonada. {{n}} locale(s) copiats.', { n: copiedLocales })
        : t('template.cloned', 'Plantilla clonada correctament')
      toast({ description: desc })
    } catch (err) {
      const gaps = parseCommercialTemplateLegalGaps(err)
      if (gaps && gaps.length > 0) {
        toast({
          variant: 'destructive',
          description: `${t('locale.legalGaps', 'Falten marcadors obligatoris per activar aquesta plantilla:')} ${gaps.join(', ')}`,
        })
        return
      }
      toast({ variant: 'destructive', description: err instanceof Error ? err.message : t('template.cloneError', 'Error en clonar la plantilla') })
    }
  }

  async function confirmDelete() {
    if (!deleteTarget?.id) return
    try {
      await deleteMutation.mutateAsync(deleteTarget.id)
      toast({ description: t('template.deleted', 'Plantilla eliminada') })
      setDeleteTarget(null)
    } catch (err) {
      toast({ variant: 'destructive', description: err instanceof Error ? err.message : t('template.deleteError', 'Error en eliminar la plantilla') })
    }
  }

  if (!activeTenant) return null

  return (
    <div className="p-6 space-y-6">
      <div className="flex items-center gap-2">
        <FileText className="h-6 w-6 text-primary" />
        <h1 className="text-xl font-semibold">{tDocuments('page.title', 'Documents')}</h1>
      </div>

      {/* Sub-navegació */}
      <DocumentsSubNav />

      <div className="max-w-5xl mx-auto space-y-6">

      {/* Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2 flex-wrap">
          <h2 className="text-lg font-semibold">{t('page.title', 'Plantilles de documents')}</h2>
          {(tenantArchetype || tenantVertical) && (
            <span className="inline-flex items-center gap-1 text-[10px] font-semibold bg-amber-100 text-amber-700 px-2 py-0.5 rounded-full">
              <Tag className="h-2.5 w-2.5" />
              {tenantVertical ?? tenantArchetype}
            </span>
          )}
        </div>
        {canWrite && (
          <Button onClick={() => setFormMode({ kind: 'create_template' })}>
            <FilePlus2 className="h-4 w-4 mr-2" />
            {t('page.newTemplate', 'Nova plantilla')}
          </Button>
        )}
      </div>

      {/* Filtres */}
      <div className="flex flex-col gap-2">
        <div className="relative">
          <Search className="absolute left-2.5 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground pointer-events-none" />
          <Input
            value={searchQuery}
            onChange={e => setSearchQuery(e.target.value)}
            placeholder={t('page.searchPlaceholder', 'Cercar per nom o descripció...')}
            className="pl-8 pr-8 h-9"
          />
          {searchQuery && (
            <button
              type="button"
              onClick={() => setSearchQuery('')}
              title={t('page.clearSearch', 'Netejar cerca')}
              className="absolute right-2.5 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
            >
              <X className="h-3.5 w-3.5" />
            </button>
          )}
        </div>
        <div className="flex flex-wrap gap-2">
          {(tenantArchetype || tenantVertical) && (
            <button
              type="button"
              onClick={() => setSectorOnly(v => !v)}
              className={`flex items-center gap-1 text-xs px-2.5 py-1 rounded-full border font-medium transition-colors ${
                sectorOnly
                  ? 'bg-amber-100 text-amber-700 border-amber-300'
                  : 'bg-background text-muted-foreground border-border hover:border-foreground/40'
              }`}
            >
              <Tag className="h-3 w-3" />
              {t('page.sectorFilter', 'Per al meu sector')}
            </button>
          )}
          {(['all', 'html', 'docx'] as const).map(type => (
            <button
              key={type}
              type="button"
              onClick={() => setTypeFilter(type)}
              className={`text-xs px-2.5 py-1 rounded-full border font-medium transition-colors ${
                typeFilter === type
                  ? type === 'html'
                    ? 'bg-emerald-100 text-emerald-700 border-emerald-300'
                    : type === 'docx'
                      ? 'bg-sky-100 text-sky-700 border-sky-300'
                      : 'bg-primary text-primary-foreground border-primary'
                  : 'bg-background text-muted-foreground border-border hover:border-foreground/40'
              }`}
            >
              {type === 'all' ? t('page.filterAll', 'Tots') : type.toUpperCase()}
            </button>
          ))}
          {allCategories.length > 0 && (
            <>
              <span className="text-xs text-muted-foreground self-center">|</span>
              {allCategories.map(cat => (
                <button
                  key={cat}
                  type="button"
                  onClick={() => setCatFilter(catFilter === cat ? '' : cat)}
                  className={`text-xs px-2.5 py-1 rounded-full border font-medium transition-colors ${
                    catFilter === cat
                      ? 'bg-indigo-100 text-indigo-700 border-indigo-300'
                      : 'bg-background text-muted-foreground border-border hover:border-foreground/40'
                  }`}
                >
                  {templateCategoryLabel(t, cat)}
                </button>
              ))}
            </>
          )}
          <span className="text-xs text-muted-foreground self-center">|</span>
          {(['date', 'name'] as const).map(s => (
            <button
              key={s}
              type="button"
              onClick={() => setSortBy(s)}
              className={`text-xs px-2.5 py-1 rounded-full border font-medium transition-colors ${
                sortBy === s
                  ? 'bg-purple-100 text-purple-700 border-purple-300'
                  : 'bg-background text-muted-foreground border-border hover:border-foreground/40'
              }`}
            >
              {s === 'date' ? t('page.sortDate', 'Data') : t('page.sortName', 'Nom')}
            </button>
          ))}
        </div>
      </div>

      {isLoading && (
        <p className="text-sm text-muted-foreground">{t('page.loading', 'Carregant...')}</p>
      )}

      <Tabs defaultValue="own">
        <TabsList>
          <TabsTrigger value="own">{t('page.tenant', 'Les meves plantilles')}</TabsTrigger>
          <TabsTrigger value="platform">{t('page.platform', 'Plantilles del sistema')}</TabsTrigger>
        </TabsList>

        <TabsContent value="own" className="space-y-3 mt-4">
          {tenantTemplates.length === 0 && !isLoading ? (
            <p className="text-sm text-muted-foreground">{t('page.emptyTenant', 'Cap plantilla pròpia. Podeu clonar una del sistema o crear-ne una de nova.')}</p>
          ) : tenantTemplates.map(tmpl => (
            <TemplateCard
              key={tmpl.id}
              template={tmpl}
              canWrite={canWrite}
              tenantId={tenantId}
              onDelete={tpl => setDeleteTarget(tpl)}
              onClone={handleClone}
            />
          ))}
        </TabsContent>

        <TabsContent value="platform" className="space-y-3 mt-4">
          {platformTemplates.length === 0 && !isLoading ? (
            <p className="text-sm text-muted-foreground">{t('page.empty', 'No hi ha plantilles disponibles')}</p>
          ) : platformTemplates.map(tmpl => (
            <TemplateCard
              key={tmpl.id}
              template={tmpl}
              canWrite={canWrite}
              tenantId={tenantId}
              onDelete={tpl => setDeleteTarget(tpl)}
              onClone={handleClone}
            />
          ))}
        </TabsContent>
      </Tabs>

      {/* Form modal */}
      {formMode && (
        <TemplateFormModal
          open
          onClose={() => setFormMode(null)}
          mode={formMode}
        />
      )}

      {/* Delete confirm */}
      <Dialog open={!!deleteTarget} onOpenChange={v => { if (!v) setDeleteTarget(null) }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t('template.delete', 'Eliminar plantilla')}</DialogTitle>
            <DialogDescription>{t('template.deleteConfirm', 'Vols eliminar aquesta plantilla? S\'eliminaran tots els locales associats.')}</DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setDeleteTarget(null)}>{t('common.cancel', 'Cancel·lar')}</Button>
            <Button variant="destructive" onClick={confirmDelete} disabled={deleteMutation.isPending}>
              {t('template.deleteConfirmAction', 'Eliminar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      </div>

    </div>
  )
}
