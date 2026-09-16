import { useState, useMemo, useEffect } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { useSearchParams } from 'react-router-dom'
import { FolderOpen, FileText, ChevronRight, Plus, Home, Search, AlertCircle, Clock, FilePlus2, Tag, FolderPlus, ClipboardList, ArrowUpDown, Filter, X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useFolders } from '../api/useFolders'
import { useDocuments } from '../api/useDocuments'
import { useDeleteFolder } from '../api/useDeleteFolder'
import { useFolderCounts } from '../api/useFolderCounts'
import { FolderForm } from './FolderForm'
import { DocumentRow } from './DocumentRow'
import { DocumentUploadModal } from './DocumentUploadModal'
import { AuditExpeditionModal } from './AuditExpeditionModal'
import { DocumentShareModal } from './DocumentShareModal'
import { DocumentsSubNav } from './DocumentsSubNav'
import { useDocumentTags } from '../api/useDocumentTags'
import { useUserProfiles } from '../api/useUserProfiles'
import { supabase } from '@/lib/supabase'
import { DocumentOrchestrator } from '../../signing'
import { useDocumentVersionSubmissionsBatch } from '../../signing/api/useDocumentVersionSubmissionsBatch'
import { useShareLinkCountsBatch } from '../api/useShareLinkCountsBatch'
import { useSigningConfig } from '../../signing/api/useSigningConfig'
import type { Folder } from '../api/documentsService'
import { getFolderPath } from '../api/documentsService'

interface BreadcrumbItem {
  id: string | null
  name: string
}

interface DocumentsPageProps {
  /** Quan s'especifica, amaga la navegació per carpetes i mostra documents de l'entitat. */
  entityFilter?: { type: string; id: string }
  /** Nom visible de l'entitat (p.e. nom de l'empleat), passat al modal d'orquestrador. */
  entityLabel?: string
  /** Email de l'entitat, passat al modal d'orquestrador per auto-assignació. */
  entityEmail?: string
}

function tagColorClass(color?: string | null): string {
  switch ((color ?? '').toLowerCase()) {
    case '#ef4444':
      return 'bg-red-500'
    case '#f97316':
      return 'bg-orange-500'
    case '#eab308':
      return 'bg-yellow-500'
    case '#22c55e':
      return 'bg-green-500'
    case '#3b82f6':
      return 'bg-blue-500'
    case '#8b5cf6':
      return 'bg-violet-500'
    case '#ec4899':
      return 'bg-pink-500'
    case '#6b7280':
    default:
      return 'bg-gray-500'
  }
}

export function DocumentsPage({ entityFilter, entityLabel, entityEmail }: DocumentsPageProps = {}) {
  const { t } = useTranslation('documents')
  const { toast } = useToast()
  const [searchParams, setSearchParams] = useSearchParams()
  const { activeTenant, activeRole, selectedSiteId, activeSiteRole } = useTenant()
  const canWrite =
    activeRole === 'owner' ||
    activeRole === 'manager' ||
    (!!selectedSiteId && (activeSiteRole === 'owner' || activeSiteRole === 'manager'))
  const isEmbedded = !!entityFilter
  const folderParam = isEmbedded ? null : searchParams.get('folder')

  const { data: signingConfig } = useSigningConfig(activeTenant?.id ?? undefined)

  // ─── Carpetes: navegació jeràrquica ───────────────────────────────────────
  const [currentFolderId, setCurrentFolderId] = useState<string | null>(null)
  const [breadcrumbs, setBreadcrumbs] = useState<BreadcrumbItem[]>([
    { id: null, name: t('page.root', 'Inici') },
  ])

  useEffect(() => {
    if (isEmbedded) return
    let cancelled = false
    if (!folderParam) {
      setCurrentFolderId(null)
      setBreadcrumbs([{ id: null, name: t('page.root', 'Inici') }])
      return
    }
    void getFolderPath(folderParam).then((path) => {
      if (cancelled || path.length === 0) return
      setCurrentFolderId(folderParam)
      setBreadcrumbs([
        { id: null, name: t('page.root', 'Inici') },
        ...path.map((folder) => ({ id: folder.id!, name: folder.name ?? '' })),
      ])
    }).catch(() => {
      if (!cancelled) {
        setCurrentFolderId(null)
        setBreadcrumbs([{ id: null, name: t('page.root', 'Inici') }])
      }
    })
    return () => {
      cancelled = true
    }
  }, [folderParam, isEmbedded, t])

  // ─── Cerca ────────────────────────────────────────────────────────────────
  const [searchTerm, setSearchTerm] = useState('')

  // ─── Filtre d'expiry ──────────────────────────────────────────────────────
  type ExpiryFilter = 'all' | 'expired' | 'soon'
  const [expiryFilter, setExpiryFilter] = useState<ExpiryFilter>('all')

  // ─── Filtre per tag ────────────────────────────────────────────────────────
  const [selectedTagId, setSelectedTagId] = useState<string | null>(null)
  const { data: allTags = [] } = useDocumentTags()
  const { data: taggedDocIds } = useQuery({
    queryKey: ['documents-by-tag', selectedTagId],
    queryFn: async () => {
      const { data } = await supabase
        .from('document_tag_assignments')
        .select('document_id')
        .eq('tag_id', selectedTagId!)
      return new Set(data?.map((d) => d.document_id) ?? [])
    },
    enabled: !!selectedTagId,
  })

  // ─── Vista: carpetes vs categories ────────────────────────────────────────
  const [viewMode, setViewMode] = useState<'folders' | 'categories'>('folders')
  const [selectedCategory, setSelectedCategory] = useState<string | null>(null)

  // ─── Ordre ────────────────────────────────────────────────────────────────
  type SortBy = 'title' | 'created_at'
  const [sortBy, setSortBy] = useState<SortBy>('created_at')

  // ─── Filtre per tipus de fitxer ───────────────────────────────────────────
  type MimeFilter = 'all' | 'pdf' | 'docx' | 'html' | 'image' | 'spreadsheet' | 'other'
  const [mimeFilter, setMimeFilter] = useState<MimeFilter>('all')

  // ─── Filtre per usuari ────────────────────────────────────────────────────
  const [selectedUserId, setSelectedUserId] = useState<string | null>(null)
  const { data: userProfiles = [] } = useUserProfiles()

  // ─── Modals ──────────────────────────────────────────────────────────────
  const [folderFormOpen, setFolderFormOpen] = useState(false)
  const [editFolder, setEditFolder] = useState<Folder | null>(null)
  const [uploadOpen, setUploadOpen] = useState(false)
  const [deleteTargetFolder, setDeleteTargetFolder] = useState<Folder | null>(null)
  const [deleteConfirmOpen, setDeleteConfirmOpen] = useState(false)
  // ─── Expedició d'auditoria: selecció múltiple ────────────────────────
  const [expeditionMode, setExpeditionMode] = useState(false)
  const [selectedDocIds, setSelectedDocIds] = useState<Set<string>>(new Set())
  const [expeditionOpen, setExpeditionOpen] = useState(false)
  // ─── Share links ──────────────────────────────────────────────────────
  const [shareTarget, setShareTarget] = useState<typeof documents[0] | null>(null)
  // ─── Document orchestrator ────────────────────────────────────────────
  const [orchestratorOpen, setOrchestratorOpen] = useState(false)
  // ─── Filtres popover ──────────────────────────────────────────────────
  const [filtersOpen, setFiltersOpen] = useState(false)

  function toggleDocSelection(id: string) {
    setSelectedDocIds((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id); else next.add(id)
      return next
    })
  }

  function startExpedition() {
    if (selectedDocIds.size === 0) return
    setExpeditionOpen(true)
  }

  function exitExpeditionMode() {
    setExpeditionMode(false)
    setSelectedDocIds(new Set())
  }

  function requestDeleteFolder(folder: Folder) {
    const c = folderCounts[folder.id!]
    const total = (c?.folders ?? 0) + (c?.docs ?? 0)
    if (total > 0) {
      toast({
        variant: 'destructive',
        description: t('folders.deleteNotEmpty', 'No es pot eliminar una carpeta amb contingut.'),
      })
      return
    }
    setDeleteTargetFolder(folder)
    setDeleteConfirmOpen(true)
  }

  async function confirmDeleteFolder() {
    if (!deleteTargetFolder?.id) return
    try {
      await deleteFolder.mutateAsync(deleteTargetFolder.id)
      setDeleteConfirmOpen(false)
      setDeleteTargetFolder(null)
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('folders.error', 'Error en desar la carpeta'),
      })
    }
  }
  // ─── Queries (scope-aware) ─────────────────────────────────────────────
  const { data: folders = [], isLoading: foldersLoading } = useFolders(
    currentFolderId,
    {
      scopeMode: isEmbedded ? 'embedded' : 'global',
      entityType: isEmbedded ? entityFilter.type : undefined,
      entityId: isEmbedded ? entityFilter.id : undefined,
      siteId: !isEmbedded ? selectedSiteId : undefined,
    },
  )
  const { data: documents = [], isLoading: docsLoading } = useDocuments({
    folderId: viewMode === 'folders' ? currentFolderId : undefined,
    allFolders: viewMode === 'categories',
    entityType: isEmbedded ? entityFilter.type : undefined,
    entityId: isEmbedded ? entityFilter.id : undefined,
    siteId: !isEmbedded ? selectedSiteId : undefined,
  })
  const deleteFolder = useDeleteFolder(currentFolderId)

  // ─── Counts per carpeta ───────────────────────────────────────────────────
  const folderIds = folders.map((f) => f.id!).filter(Boolean)
  const folderCounts = useFolderCounts(activeTenant?.id ?? '', folderIds)

  // ─── Badge de signatura per a tots els documents (ha d'estar ABANS del guard) ──
  const allDocVersionIds = documents
    .map((d) => d.version_id)
    .filter((id): id is string => !!id)
  const { data: signingBadgesByVersion = {} } = useDocumentVersionSubmissionsBatch(allDocVersionIds)

  // ─── Badge share links per a tots els documents ───────────────────────────
  const allDocIds = documents.map((d) => d.id!).filter(Boolean)
  const { data: shareLinkCounts = {} } = useShareLinkCountsBatch(allDocIds)

  // ─── Folder navigation ────────────────────────────────────────────────────
  function setFolderInUrl(folderId: string | null) {
    if (isEmbedded) return
    const next = new URLSearchParams(searchParams)
    if (folderId) next.set('folder', folderId)
    else next.delete('folder')
    setSearchParams(next, { replace: true })
  }

  function enterFolder(folder: Folder) {
    setSearchTerm('')
    if (isEmbedded) {
      setCurrentFolderId(folder.id!)
      setBreadcrumbs((prev) => [...prev, { id: folder.id!, name: folder.name ?? '' }])
      return
    }
    setFolderInUrl(folder.id!)
  }

  function navigateTo(index: number) {
    const crumb = breadcrumbs[index]
    setSearchTerm('')
    if (isEmbedded) {
      setBreadcrumbs(breadcrumbs.slice(0, index + 1))
      setCurrentFolderId(crumb.id)
      return
    }
    setFolderInUrl(crumb.id)
  }

  // ─── Cerca + expiry client-side ──────────────────────────────────────────
  const lcSearch = searchTerm.toLowerCase()
  const isSearching = lcSearch.length > 0
  const filteredFolders = isSearching
    ? folders.filter((f) => f.name?.toLowerCase().includes(lcSearch))
    : folders

  const now = new Date()
  function applyExpiryFilter(docs: typeof documents) {
    if (expiryFilter === 'all') return docs
    return docs.filter((d) => {
      if (!d.expires_at) return false
      const expiry = new Date(d.expires_at)
      if (expiryFilter === 'expired') return expiry < now
      if (expiryFilter === 'soon') {
        const days = (expiry.getTime() - now.getTime()) / (1000 * 60 * 60 * 24)
        return days <= 30 && expiry >= now
      }
      return true
    })
  }

  function matchesMimeFilter(mimeType: string | null): boolean {
    if (mimeFilter === 'all') return true
    const mime = (mimeType ?? '').toLowerCase()
    if (mimeFilter === 'pdf') return mime === 'application/pdf'
    if (mimeFilter === 'docx') return mime.includes('wordprocessingml')
    if (mimeFilter === 'html') return mime === 'text/html'
    if (mimeFilter === 'image') return mime.startsWith('image/')
    if (mimeFilter === 'spreadsheet') return mime.includes('spreadsheetml') || mime === 'text/csv' || mime === 'application/vnd.ms-excel'
    return !(
      mime === 'application/pdf' ||
      mime.includes('wordprocessingml') ||
      mime === 'text/html' ||
      mime.startsWith('image/') ||
      mime.includes('spreadsheetml') ||
      mime === 'text/csv' ||
      mime === 'application/vnd.ms-excel'
    )
  }

  const filteredDocuments = applyExpiryFilter(
    isSearching
      ? documents.filter((d) => d.title?.toLowerCase().includes(lcSearch))
      : documents
  )
    .filter((d) => !selectedTagId || taggedDocIds?.has(d.id!))
    .filter((d) => matchesMimeFilter(d.mime_type))
    .filter((d) => {
      if (!selectedCategory) return true
      if (selectedCategory === '__none__') return !d.category
      return d.category === selectedCategory
    })
    .filter((d) => !selectedUserId || d.created_by === selectedUserId)
    .slice()
    .sort((a, b) => {
      if (sortBy === 'created_at') {
        const aDate = a.created_at ? new Date(a.created_at).getTime() : 0
        const bDate = b.created_at ? new Date(b.created_at).getTime() : 0
        return bDate - aDate
      }
      return (a.title ?? '').localeCompare(b.title ?? '')
    })

  const groupedDocs = useMemo(() => {
    if (viewMode !== 'categories') return []
    const map = new Map<string | null, typeof filteredDocuments>()
    filteredDocuments.forEach((d) => {
      const cat = d.category ?? null
      if (!map.has(cat)) map.set(cat, [])
      map.get(cat)!.push(d)
    })
    const sortedKeys = Array.from(map.keys()).sort((a, b) => {
      if (a === null) return 1
      if (b === null) return -1
      return a.localeCompare(b)
    })
    return sortedKeys.map((cat) => ({ category: cat, docs: map.get(cat)! }))
  }, [filteredDocuments, viewMode])

  const isLoading = foldersLoading || docsLoading

  // ─── Filtres derivats ─────────────────────────────────────────────────
  const distinctDocumentUserIds = useMemo(
    () => new Set(documents.map(d => d.created_by).filter((id): id is string => !!id)),
    [documents]
  )
  const distinctCategories = useMemo(() => {
    const cats = new Set<string>()
    documents.forEach((d) => { if (d.category) cats.add(d.category) })
    return Array.from(cats).sort()
  }, [documents])
  const documentUserProfiles = useMemo(
    () => userProfiles.filter(u => u.id !== null && distinctDocumentUserIds.has(u.id)),
    [userProfiles, distinctDocumentUserIds]
  )
  const showUserFilter = documentUserProfiles.length > 1

  const activeFilterCount = [
    expiryFilter !== 'all',
    mimeFilter !== 'all',
    !!selectedTagId,
    !!selectedUserId,
    !!selectedCategory,
  ].filter(Boolean).length

  function clearAllFilters() {
    setExpiryFilter('all')
    setMimeFilter('all')
    setSelectedTagId(null)
    setSelectedUserId(null)
    setSelectedCategory(null)
  }

  // ─── Guard (tots els hooks ja s'han executat) ─────────────────────────────
  if (!activeTenant) return null

  return (
    <div className="p-6 space-y-6">
      {/* ── Capçalera ─────────────────────────────────────────────────────── */}
      {!isEmbedded && (
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2">
            <FileText className="h-6 w-6 text-primary" />
            <h1 className="text-xl font-semibold">{t('page.title', 'Documents')}</h1>
          </div>
          {canWrite && (
            <div className="flex gap-2 flex-wrap">
              <Button
                variant={expeditionMode ? 'default' : 'outline'}
                size="sm"
                onClick={() => expeditionMode ? exitExpeditionMode() : setExpeditionMode(true)}
              >
                <ClipboardList className="h-4 w-4 mr-1" />
                {expeditionMode
                  ? t('page.exitExpedition', 'Cancel\u00b7lar selecci\u00f3')
                  : t('page.expedition', 'Expedir per auditoria')}
              </Button>
              <Button variant="outline" size="sm" onClick={() => { setEditFolder(null); setFolderFormOpen(true) }}>
                <FolderPlus className="h-4 w-4 mr-1" />
                {t('page.newFolder', 'Nova carpeta')}
              </Button>
              <Button variant="outline" size="sm" onClick={() => setUploadOpen(true)}>
                <Plus className="h-4 w-4 mr-1" />
                {t('page.newDocument', 'Nou document')}
              </Button>
              <Button size="sm" onClick={() => setOrchestratorOpen(true)}>
                <FilePlus2 className="h-4 w-4 mr-1" />
                {t('page.prepareDocument', 'Generar document')}
              </Button>
            </div>
          )}
        </div>
      )}

      {/* ── Sub-navegació ─────────────────────────────────────────────────── */}
      {!isEmbedded && <DocumentsSubNav />}

      {/* ── Mode embedded: botons compactes ───────────────────────────────── */}
      {isEmbedded && canWrite && (
        <div className="flex justify-end gap-2">
          <Button variant="outline" size="sm" onClick={() => { setEditFolder(null); setFolderFormOpen(true) }}>
            <Plus className="h-4 w-4 mr-1" />
            {t('page.newFolder', 'Nova carpeta')}
          </Button>
          <Button variant="outline" size="sm" onClick={() => setUploadOpen(true)}>
            <Plus className="h-4 w-4 mr-1" />
            {t('page.newDocument', 'Nou document')}
          </Button>
          <Button size="sm" onClick={() => setOrchestratorOpen(true)}>
            <FilePlus2 className="h-4 w-4 mr-1" />
            {t('page.prepareDocument', 'Generar document')}
          </Button>
        </div>
      )}

      {/* ── Cerca ─────────────────────────────────────────────────────────── */}
      <div className="flex items-center gap-2">
        <div className="relative flex-1">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground pointer-events-none" />
          <Input
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
            placeholder={t('page.search', 'Cerca documents i carpetes...')}
            className="pl-9"
          />
        </div>
        <div className="flex items-center rounded-md border overflow-hidden shrink-0">
          <button
            type="button"
            onClick={() => { setViewMode('folders'); setSelectedCategory(null) }}
            className={`inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium transition-colors ${
              viewMode === 'folders' ? 'bg-foreground text-background' : 'text-muted-foreground hover:bg-muted/60'
            }`}
          >
            <FolderOpen className="h-3.5 w-3.5" />
            {t('page.viewFolders', 'Carpetes')}
          </button>
          <button
            type="button"
            onClick={() => setViewMode('categories')}
            className={`inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium transition-colors border-l ${
              viewMode === 'categories' ? 'bg-foreground text-background' : 'text-muted-foreground hover:bg-muted/60'
            }`}
          >
            <Tag className="h-3.5 w-3.5" />
            {t('page.viewCategories', 'Categories')}
          </button>
        </div>
      </div>

      {/* ── Filtres + Ordenació ──────────────────────────────────────────── */}
      <div className="flex items-center gap-2 flex-wrap">
        <Popover open={filtersOpen} onOpenChange={setFiltersOpen}>
          <PopoverTrigger asChild>
            <Button variant="outline" size="sm" className="relative shrink-0 gap-1.5">
              <Filter className="h-3.5 w-3.5" />
              {t('page.filtersButton', 'Filtres')}
              {activeFilterCount > 0 && (
                <span className="absolute -top-1.5 -right-1.5 bg-primary text-primary-foreground text-[10px] font-bold rounded-full min-w-4 h-4 flex items-center justify-center px-1 leading-none">
                  {activeFilterCount}
                </span>
              )}
            </Button>
          </PopoverTrigger>
          <PopoverContent align="start" className="w-80 p-4 space-y-4">

            {/* Venciment */}
            <div className="space-y-2">
              <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                {t('page.filterGroupExpiry', 'Venciment')}
              </p>
              <div className="flex items-center gap-1.5 flex-wrap">
                {(['all', 'expired', 'soon'] as const).map((v) => (
                  <button
                    key={v}
                    type="button"
                    onClick={() => setExpiryFilter(v)}
                    className={`inline-flex items-center gap-1 px-2.5 py-1 rounded-full text-xs font-medium transition-colors ${
                      expiryFilter === v
                        ? v === 'expired' ? 'bg-red-500 text-white' : v === 'soon' ? 'bg-amber-500 text-white' : 'bg-primary text-primary-foreground'
                        : 'bg-muted text-muted-foreground hover:bg-muted/80'
                    }`}
                  >
                    {v === 'expired' && <AlertCircle className="h-3 w-3" />}
                    {v === 'soon' && <Clock className="h-3 w-3" />}
                    {v === 'all' ? t('page.filterAll', 'Tots') : v === 'expired' ? t('page.filterExpired', 'Caducats') : t('page.filterSoon', 'Expiren aviat')}
                  </button>
                ))}
              </div>
            </div>

            {/* Tipus de fitxer */}
            <div className="space-y-2">
              <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                {t('page.filterGroupType', 'Tipus de fitxer')}
              </p>
              <div className="flex items-center gap-1.5 flex-wrap">
                {([
                  { v: 'all',         label: t('page.filterTypeAll',   'Tots'),             cls: 'bg-primary text-primary-foreground' },
                  { v: 'pdf',         label: t('page.filterTypePdf',   'PDF'),              cls: 'bg-rose-500 text-white' },
                  { v: 'docx',        label: t('page.filterTypeDocx',  'DOCX'),             cls: 'bg-blue-500 text-white' },
                  { v: 'html',        label: t('page.filterTypeHtml',  'HTML'),             cls: 'bg-sky-600 text-white' },
                  { v: 'image',       label: t('page.filterTypeImage', 'Imatges'),          cls: 'bg-violet-500 text-white' },
                  { v: 'spreadsheet', label: t('page.filterTypeSheet', 'Fulls de càlcul'),  cls: 'bg-emerald-500 text-white' },
                  { v: 'other',       label: t('page.filterTypeOther', 'Altres'),           cls: 'bg-slate-500 text-white' },
                ] as { v: typeof mimeFilter; label: string; cls: string }[]).map(({ v, label, cls }) => (
                  <button
                    key={v}
                    type="button"
                    onClick={() => setMimeFilter(v)}
                    className={`inline-flex items-center gap-1 px-2.5 py-1 rounded-full text-xs font-medium transition-colors ${mimeFilter === v ? cls : 'bg-muted text-muted-foreground hover:bg-muted/80'}`}
                  >
                    {label}
                  </button>
                ))}
              </div>
            </div>

            {/* Etiquetes */}
            {allTags.length > 0 && (
              <div className="space-y-2">
                <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                  {t('page.filterGroupTags', 'Etiquetes')}
                </p>
                <div className="flex items-center gap-1.5 flex-wrap">
                  <button
                    type="button"
                    onClick={() => setSelectedTagId(null)}
                    className={`inline-flex items-center px-2.5 py-1 rounded-full text-xs font-medium transition-colors ${!selectedTagId ? 'bg-foreground text-background' : 'bg-muted text-muted-foreground hover:bg-muted/80'}`}
                  >
                    {t('page.filterTagAll', 'Totes')}
                  </button>
                  {allTags.map((tag) => (
                    <button
                      key={tag.id}
                      type="button"
                      onClick={() => setSelectedTagId(selectedTagId === tag.id ? null : tag.id)}
                      className={`inline-flex items-center px-2.5 py-1 rounded-full text-xs font-medium text-white transition-opacity ${tagColorClass(tag.color)} ${selectedTagId === tag.id ? 'opacity-100 ring-2 ring-offset-1 ring-foreground' : 'opacity-70 hover:opacity-100'}`}
                    >
                      {tag.name}
                    </button>
                  ))}
                </div>
              </div>
            )}

            {/* Categoria */}
            {distinctCategories.length > 0 && (
              <div className="space-y-2">
                <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                  {t('page.filterGroupCategory', 'Categoria')}
                </p>
                <div className="flex items-center gap-1.5 flex-wrap">
                  <button
                    type="button"
                    onClick={() => setSelectedCategory(null)}
                    className={`inline-flex items-center px-2.5 py-1 rounded-full text-xs font-medium transition-colors ${!selectedCategory ? 'bg-foreground text-background' : 'bg-muted text-muted-foreground hover:bg-muted/80'}`}
                  >
                    {t('page.filterAll', 'Tots')}
                  </button>
                  {distinctCategories.map((cat) => (
                    <button
                      key={cat}
                      type="button"
                      onClick={() => setSelectedCategory(selectedCategory === cat ? null : cat)}
                      className={`inline-flex items-center gap-1 px-2.5 py-1 rounded-full text-xs font-medium transition-colors ${selectedCategory === cat ? 'bg-indigo-600 text-white' : 'bg-muted text-muted-foreground hover:bg-muted/80'}`}
                    >
                      <Tag className="h-3 w-3" />
                      {cat}
                    </button>
                  ))}
                </div>
              </div>
            )}

            {/* Creat per — només si hi ha >1 usuari */}
            {showUserFilter && (
              <div className="space-y-2">
                <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                  {t('page.filterGroupUser', 'Creat per')}
                </p>
                <div className="flex items-center gap-1.5 flex-wrap">
                  <button
                    type="button"
                    onClick={() => setSelectedUserId(null)}
                    className={`inline-flex items-center px-2.5 py-1 rounded-full text-xs font-medium transition-colors ${!selectedUserId ? 'bg-foreground text-background' : 'bg-muted text-muted-foreground hover:bg-muted/80'}`}
                  >
                    {t('page.filterUserAll', 'Tots')}
                  </button>
                  {documentUserProfiles.map((user) => (
                    <button
                      key={user.id}
                      type="button"
                      onClick={() => setSelectedUserId(selectedUserId === user.id ? null : user.id)}
                      title={user.full_name ?? user.email ?? ''}
                      className={`inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium transition-colors border ${selectedUserId === user.id ? 'bg-indigo-100 text-indigo-700 border-indigo-300' : 'bg-muted text-muted-foreground border-transparent hover:bg-muted/80'}`}
                    >
                      {user.avatar_url ? (
                        <img src={user.avatar_url} alt="" className="w-4 h-4 rounded-full object-cover" />
                      ) : (
                        <span className="w-4 h-4 rounded-full bg-indigo-300 text-indigo-800 text-[9px] flex items-center justify-center font-bold leading-none">
                          {(user.full_name ?? user.email ?? '?')[0].toUpperCase()}
                        </span>
                      )}
                      {user.full_name ?? user.email}
                    </button>
                  ))}
                </div>
              </div>
            )}

            {/* Peu: botó de netejar */}
            {activeFilterCount > 0 && (
              <div className="pt-1 border-t">
                <button
                  type="button"
                  onClick={clearAllFilters}
                  className="text-xs text-muted-foreground hover:text-foreground underline underline-offset-2 transition-colors"
                >
                  {t('page.clearFilters', 'Esborrar tots els filtres')}
                </button>
              </div>
            )}
          </PopoverContent>
        </Popover>

        {/* Pills dels filtres actius (descartables) */}
        {activeFilterCount > 0 && (
          <div className="flex items-center gap-1.5 flex-wrap flex-1 min-w-0">
            {expiryFilter !== 'all' && (
              <span className={`inline-flex items-center gap-1 pl-2 pr-1 py-0.5 rounded-full text-xs font-medium ${expiryFilter === 'expired' ? 'bg-red-100 text-red-700' : 'bg-amber-100 text-amber-700'}`}>
                {expiryFilter === 'expired' ? t('page.filterExpired', 'Caducats') : t('page.filterSoon', 'Expiren aviat')}
                <button type="button" onClick={() => setExpiryFilter('all')} className="ml-0.5 rounded-full hover:bg-black/10 p-0.5" aria-label="Clear">
                  <X className="h-2.5 w-2.5" />
                </button>
              </span>
            )}
            {mimeFilter !== 'all' && (
              <span className="inline-flex items-center gap-1 pl-2 pr-1 py-0.5 rounded-full text-xs font-medium bg-muted text-foreground">
                {mimeFilter === 'pdf' ? 'PDF' : mimeFilter === 'docx' ? 'DOCX' : mimeFilter === 'html' ? 'HTML' : mimeFilter === 'image' ? t('page.filterTypeImage', 'Imatges') : mimeFilter === 'spreadsheet' ? t('page.filterTypeSheet', 'Fulls') : t('page.filterTypeOther', 'Altres')}
                <button type="button" onClick={() => setMimeFilter('all')} className="ml-0.5 rounded-full hover:bg-black/10 p-0.5" aria-label="Clear">
                  <X className="h-2.5 w-2.5" />
                </button>
              </span>
            )}
            {selectedTagId && (() => {
              const tag = allTags.find(tg => tg.id === selectedTagId)
              return tag ? (
                <span className={`inline-flex items-center gap-1 pl-2 pr-1 py-0.5 rounded-full text-xs font-medium text-white ${tagColorClass(tag.color)}`}>
                  {tag.name}
                  <button type="button" onClick={() => setSelectedTagId(null)} className="ml-0.5 rounded-full hover:bg-black/20 p-0.5" aria-label="Clear">
                    <X className="h-2.5 w-2.5" />
                  </button>
                </span>
              ) : null
            })()}
            {selectedUserId && (() => {
              const user = userProfiles.find(u => u.id === selectedUserId)
              return user ? (
                <span className="inline-flex items-center gap-1 pl-2 pr-1 py-0.5 rounded-full text-xs font-medium bg-indigo-100 text-indigo-700">
                  {user.full_name ?? user.email}
                  <button type="button" onClick={() => setSelectedUserId(null)} className="ml-0.5 rounded-full hover:bg-black/10 p-0.5" aria-label="Clear">
                    <X className="h-2.5 w-2.5" />
                  </button>
                </span>
              ) : null
            })()}
            {selectedCategory && (
              <span className="inline-flex items-center gap-1 pl-2 pr-1 py-0.5 rounded-full text-xs font-medium bg-indigo-100 text-indigo-700">
                <Tag className="h-3 w-3" />
                {selectedCategory}
                <button type="button" onClick={() => setSelectedCategory(null)} className="ml-0.5 rounded-full hover:bg-black/10 p-0.5" aria-label="Clear">
                  <X className="h-2.5 w-2.5" />
                </button>
              </span>
            )}
          </div>
        )}

        {/* Ordenació — sempre visible */}
        <button
          type="button"
          onClick={() => setSortBy(sortBy === 'title' ? 'created_at' : 'title')}
          className="inline-flex items-center gap-1 px-3 py-1 rounded-full text-xs font-medium transition-colors bg-muted text-muted-foreground hover:bg-muted/80 shrink-0 ml-auto"
          title={sortBy === 'title' ? t('page.sortByDate', 'Ordenar per data') : t('page.sortByTitle', 'Ordenar per títol')}
        >
          <ArrowUpDown className="h-3 w-3" />
          {sortBy === 'title' ? t('page.sortTitle', 'A–Z') : t('page.sortDate', 'Data ↓')}
        </button>
      </div>

      {/* ── Fil d'Ariadna (només en vista carpetes) ───────────────────────────── */}
      {viewMode === 'folders' && breadcrumbs.length > 1 && (
        <nav className="flex items-center gap-1 text-sm text-muted-foreground">
          {breadcrumbs.map((crumb, idx) => (
            <div key={idx} className="flex items-center gap-1">
              {idx > 0 && <ChevronRight className="h-3.5 w-3.5" />}
              {idx < breadcrumbs.length - 1 ? (
                <button
                  onClick={() => navigateTo(idx)}
                  className="hover:text-foreground transition-colors"
                >
                  {idx === 0 ? <Home className="h-3.5 w-3.5" /> : crumb.name}
                </button>
              ) : (
                <span className="text-foreground font-medium">
                  {idx === 0 ? <Home className="h-3.5 w-3.5 inline" /> : crumb.name}
                </span>
              )}
            </div>
          ))}
        </nav>
      )}

      {isLoading && (
        <p className="text-sm text-muted-foreground">{t('page.loading', 'Carregant...')}</p>
      )}

      {!isLoading && viewMode === 'folders' && (
        <div className="space-y-2">
          {/* ── Carpetes ─────────────────────────────────────────────────── */}
          {filteredFolders.map((folder) => (
            <div
              key={folder.id}
              className="flex items-center gap-2 py-2.5 px-4 rounded-lg border bg-card hover:bg-accent/30 transition-colors cursor-pointer group"
            >
              <FolderOpen
                className="h-5 w-5 text-yellow-500 shrink-0"
                onClick={() => enterFolder(folder)}
              />
              <div
                className="flex-1 min-w-0 flex items-baseline gap-2"
                onClick={() => enterFolder(folder)}
              >
                <span className="text-sm font-medium truncate">{folder.name}</span>
                {(() => {
                  const c = folderCounts[folder.id!]
                  const total = (c?.folders ?? 0) + (c?.docs ?? 0)
                  return total > 0 ? (
                    <span className="text-xs text-muted-foreground shrink-0">{total}</span>
                  ) : null
                })()}
              </div>
              {canWrite && (
                <div className="hidden group-hover:flex items-center gap-1">
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => { setEditFolder(folder); setFolderFormOpen(true) }}
                  >
                    {t('folders.rename', 'Reanomena')}
                  </Button>
                  <Button
                    variant="ghost"
                    size="sm"
                    className="text-destructive hover:text-destructive"
                    onClick={() => requestDeleteFolder(folder)}
                  >
                    {t('folders.delete', 'Elimina')}
                  </Button>
                </div>
              )}
            </div>
          ))}

          {/* ── Documents ─────────────────────────────────────────────────── */}
          {filteredDocuments.map((doc) => (
            <div key={doc.id} className={`flex items-start gap-2 ${expeditionMode ? 'cursor-pointer' : ''}`}
              onClick={expeditionMode ? () => toggleDocSelection(doc.id!) : undefined}>
              {expeditionMode && (
                <input
                  type="checkbox"
                  readOnly
                  checked={selectedDocIds.has(doc.id!)}
                  title={t('page.selectDocument', 'Seleccionar document')}
                  aria-label={t('page.selectDocument', 'Seleccionar document')}
                  className="mt-3.5 h-4 w-4 shrink-0 accent-primary"
                />
              )}
              <div className="flex-1 min-w-0">
                <DocumentRow
                  document={doc}
                  canWrite={canWrite && !expeditionMode}
                  activeSubmission={doc.version_id ? signingBadgesByVersion[doc.version_id] ?? null : null}
                  signingConfig={signingConfig ?? null}
                  activeShareLinkCount={doc.id ? (shareLinkCounts[doc.id] ?? 0) : 0}
                  onShare={canWrite && !expeditionMode && !isEmbedded && (doc as any).storage_type === 'native' ? () => setShareTarget(doc) : undefined}
                />
              </div>
            </div>
          ))}

          {/* ── Buit ──────────────────────────────────────────────────────── */}
          {filteredFolders.length === 0 && filteredDocuments.length === 0 && (
            <div className="text-center py-12 text-muted-foreground">
              <FileText className="h-10 w-10 mx-auto mb-3 opacity-30" />
              <p className="text-sm">
                {isSearching
                  ? t('page.emptySearch', 'Cap resultat per a la cerca')
                  : isEmbedded
                    ? t('page.emptyEmbedded', 'Cap document associat')
                    : t('page.empty', 'Aquesta carpeta és buida')}
              </p>
            </div>
          )}
        </div>
      )}

      {/* ── Vista per categories ──────────────────────────────────────────── */}
      {!isLoading && viewMode === 'categories' && (
        <div className="space-y-6">
          {groupedDocs.map(({ category, docs }) => (
            <div key={category ?? '__none__'}>
              <div className="flex items-center gap-2 mb-2">
                <Tag className="h-4 w-4 text-indigo-500 shrink-0" />
                <span className="text-sm font-semibold text-foreground">
                  {category ?? t('page.noCategory', 'Sense categoria')}
                </span>
                <span className="text-xs text-muted-foreground">({docs.length})</span>
              </div>
              <div className="space-y-2 pl-6 border-l-2 border-indigo-100">
                {docs.map((doc) => (
                  <div key={doc.id} className={`flex items-start gap-2 ${expeditionMode ? 'cursor-pointer' : ''}`}
                    onClick={expeditionMode ? () => toggleDocSelection(doc.id!) : undefined}>
                    {expeditionMode && (
                      <input
                        type="checkbox"
                        readOnly
                        checked={selectedDocIds.has(doc.id!)}
                        title={t('page.selectDocument', 'Seleccionar document')}
                        aria-label={t('page.selectDocument', 'Seleccionar document')}
                        className="mt-3.5 h-4 w-4 shrink-0 accent-primary"
                      />
                    )}
                    <div className="flex-1 min-w-0">
                      <DocumentRow
                        document={doc}
                        canWrite={canWrite && !expeditionMode}
                        activeSubmission={doc.version_id ? signingBadgesByVersion[doc.version_id] ?? null : null}
                        signingConfig={signingConfig ?? null}
                        activeShareLinkCount={doc.id ? (shareLinkCounts[doc.id] ?? 0) : 0}
                        onShare={canWrite && !expeditionMode && !isEmbedded && (doc as any).storage_type === 'native' ? () => setShareTarget(doc) : undefined}
                      />
                    </div>
                  </div>
                ))}
              </div>
            </div>
          ))}
          {filteredDocuments.length === 0 && (
            <div className="text-center py-12 text-muted-foreground">
              <FileText className="h-10 w-10 mx-auto mb-3 opacity-30" />
              <p className="text-sm">
                {isSearching
                  ? t('page.emptySearch', 'Cap resultat per a la cerca')
                  : t('page.emptyCategories', 'Cap document amb categories assignades')}
              </p>
            </div>
          )}
        </div>
      )}

      {/* ── Modals ────────────────────────────────────────────────────────── */}
      <FolderForm
        open={folderFormOpen}
        onClose={() => { setFolderFormOpen(false); setEditFolder(null) }}
        parentId={currentFolderId}
        editFolder={editFolder}
        entityType={isEmbedded ? entityFilter!.type : undefined}
        entityId={isEmbedded ? entityFilter!.id : undefined}
      />
      <DocumentUploadModal
        open={uploadOpen}
        onClose={() => setUploadOpen(false)}
        folderId={currentFolderId}
        folderName={currentFolderId ? (breadcrumbs[breadcrumbs.length - 1]?.name ?? null) : null}
        entityType={isEmbedded ? entityFilter!.type : undefined}
        entityId={isEmbedded ? entityFilter!.id : undefined}
      />
      <Dialog open={deleteConfirmOpen} onOpenChange={(v) => { if (!v) { setDeleteConfirmOpen(false); setDeleteTargetFolder(null) } }}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>{t('folders.deleteConfirmTitle', 'Eliminar carpeta')}</DialogTitle>
            <DialogDescription>
              {t('folders.deleteConfirmDescription', 'Vols eliminar aquesta carpeta? Aquesta acció no es pot desfer.')}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => { setDeleteConfirmOpen(false); setDeleteTargetFolder(null) }}>
              {t('common.cancel', 'Cancel·lar')}
            </Button>
            <Button variant="destructive" onClick={confirmDeleteFolder} disabled={deleteFolder.isPending}>
              {t('folders.deleteConfirmAction', 'Eliminar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      <AuditExpeditionModal
        open={expeditionOpen}
        onClose={() => { setExpeditionOpen(false); exitExpeditionMode() }}
        documents={filteredDocuments.filter((d) => selectedDocIds.has(d.id!))}
      />
      {shareTarget && (
        <DocumentShareModal
          open={!!shareTarget}
          onOpenChange={(v) => { if (!v) setShareTarget(null) }}
          document={shareTarget}
          tenantId={activeTenant!.id}
        />
      )}
      <DocumentOrchestrator
        open={orchestratorOpen}
        onClose={() => setOrchestratorOpen(false)}
        entityContext={entityFilter ? { ...entityFilter, label: entityLabel, email: entityEmail } : undefined}
      />

      {/* ── Barra d'acció expedició (flotant) ───────────────────────── */}
      {expeditionMode && (
        <div className="fixed bottom-6 left-1/2 -translate-x-1/2 flex items-center gap-3 bg-background border rounded-full px-5 py-2.5 shadow-lg z-40">
          <span className="text-sm font-medium">
            {t('page.expeditionSelected', '{{n}} document(s) seleccionat(s)', { n: selectedDocIds.size })}
          </span>
          <Button size="sm" disabled={selectedDocIds.size === 0} onClick={startExpedition}>
            {t('page.generateUrls', 'Generar URLs')}
          </Button>
          <Button variant="ghost" size="sm" onClick={exitExpeditionMode}>
            {t('common.cancel', 'Cancel\u00b7lar')}
          </Button>
        </div>
      )}    </div>
  )
}
