import { useState, useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { Archive, AlertTriangle, Clock, Tag, Trash2, RotateCcw, FileText, Search, X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Drawer, DrawerContent, DrawerDescription, DrawerHeader, DrawerTitle, DrawerTrigger } from '@/components/ui/drawer'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { DocumentsSubNav } from './DocumentsSubNav'
import { useArchivedDocuments } from '../api/useArchivedDocuments'
import { useUnarchiveDocument } from '../api/useUnarchiveDocument'
import { useDeleteDocumentAll } from '../api/useDeleteDocumentAll'
import { isCommercialDmsArtifact } from '../utils/commercialDmsArtifact'

function formatDateTime(iso: string | null): string | null {
  if (!iso) return null
  return new Date(iso).toLocaleString('ca-ES', {
    day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  })
}

function formatBytes(bytes: number | null): string {
  if (!bytes) return ''
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

interface ArchivedDocumentRowProps {
  doc: ArchivedDocument
  canWrite: boolean
  onUnarchive: (doc: ArchivedDocument) => void
  onDelete: (doc: ArchivedDocument) => void
}

function ArchivedDocumentRow({ doc, canWrite, onUnarchive, onDelete }: ArchivedDocumentRowProps) {
  const { t } = useTranslation('documents')
  return (
    <div className="flex items-center gap-3 py-3 px-4 rounded-lg border bg-card">
      <div className="shrink-0 text-muted-foreground">
        <FileText className="h-5 w-5" />
      </div>
      <div className="flex-1 min-w-0">
        <p className="font-medium text-sm truncate text-muted-foreground">{doc.title}</p>
        <div className="flex items-center gap-2 mt-0.5 flex-wrap">
          {doc.version_number != null && (
            <span className="text-xs text-muted-foreground">
              {t('row.version', 'v{{n}}', { n: doc.version_number })}
            </span>
          )}
          {doc.size_bytes != null && (
            <span className="text-xs text-muted-foreground">{formatBytes(doc.size_bytes)}</span>
          )}
          {doc.category && (
            <span className="inline-flex items-center gap-1 text-xs text-indigo-600 bg-indigo-50 px-1.5 py-0.5 rounded">
              <Tag className="h-3 w-3" />
              {doc.category}
            </span>
          )}
          {doc.updated_at && (
            <span className="inline-flex items-center gap-1 text-xs text-muted-foreground">
              <Clock className="h-3 w-3" />
              {t('archived.archivedAt', 'Arxivat')} {formatDateTime(doc.updated_at)}
            </span>
          )}
        </div>
      </div>
      {canWrite && (
        <div className="flex items-center gap-1 shrink-0">
          <Button
            variant="ghost"
            size="sm"
            onClick={() => onUnarchive(doc)}
            title={t('archived.unarchive', 'Desarxivar')}
            className="text-indigo-600 hover:text-indigo-700"
          >
            <RotateCcw className="h-4 w-4" />
          </Button>
          {!isCommercialDmsArtifact(doc) && (
          <Button
            variant="ghost"
            size="sm"
            onClick={() => onDelete(doc)}
            title={t('archived.deleteDefinitive', 'Eliminar definitivament')}
            className="text-destructive hover:text-destructive"
          >
            <Trash2 className="h-4 w-4" />
          </Button>
          )}
        </div>
      )}
    </div>
  )
}

export function ArchivedDocumentsPage() {
  const { t } = useTranslation('documents')
  const { toast } = useToast()
  const { activeTenant, activeRole, selectedSiteId, activeSiteRole } = useTenant()
  const tenantId = activeTenant?.id ?? ''

  const canWrite =
    activeRole === 'owner' ||
    activeRole === 'manager' ||
    (!!selectedSiteId && (activeSiteRole === 'owner' || activeSiteRole === 'manager'))

  const { data: archivedDocs = [], isLoading } = useArchivedDocuments()
  const unarchiveMutation = useUnarchiveDocument(tenantId)
  const deleteMutation = useDeleteDocumentAll(tenantId)

  const [searchTerm, setSearchTerm] = useState('')
  const [selectedCategory, setSelectedCategory] = useState<string | null>(null)

  const [unarchiveTarget, setUnarchiveTarget] = useState<ArchivedDocument | null>(null)
  const [deleteTarget, setDeleteTarget] = useState<ArchivedDocument | null>(null)

  // ── Categories disponibles (de la llista completa no filtrada) ────────────
  const availableCategories = useMemo(() => {
    const cats = new Set<string>()
    archivedDocs.forEach((d) => { if (d.category) cats.add(d.category) })
    return Array.from(cats).sort()
  }, [archivedDocs])

  // ── Filtrat: cerca + categoria ────────────────────────────────────────────
  const filteredDocs = useMemo(() => {
    const lcSearch = searchTerm.toLowerCase()
    return archivedDocs
      .filter((d) => !lcSearch || d.title?.toLowerCase().includes(lcSearch))
      .filter((d) => {
        if (!selectedCategory) return true
        if (selectedCategory === '__none__') return !d.category
        return d.category === selectedCategory
      })
  }, [archivedDocs, searchTerm, selectedCategory])

  async function handleUnarchive() {
    if (!unarchiveTarget?.id) return
    try {
      await unarchiveMutation.mutateAsync(unarchiveTarget.id)
      setUnarchiveTarget(null)
      toast({ title: t('archived.unarchiveSuccess', 'Document restaurat correctament') })
    } catch (err) {
      const msg = err instanceof Error ? err.message : ''
      toast({ variant: 'destructive', title: t('archived.unarchiveError', 'Error en desarxivar'), description: msg || undefined })
    }
  }

  async function handleDelete() {
    if (!deleteTarget?.id) return
    try {
      await deleteMutation.mutateAsync(deleteTarget.id)
      setDeleteTarget(null)
      toast({ title: t('archived.deleteSuccess', 'Document eliminat definitivament') })
    } catch (err) {
      const msg = err instanceof Error ? err.message : ''
      toast({ variant: 'destructive', title: t('row.deleteError', 'Error en eliminar'), description: msg || undefined })
    }
  }

  return (
    <div className="p-6 space-y-6">
      <DocumentsSubNav />

      <div className="max-w-5xl mx-auto space-y-6">
        {/* Icona d'avís amb tooltip i drawer */}
        <div className="flex justify-end">
          <Drawer>
            <div className="relative group">
              <DrawerTrigger asChild>
                <button
                  type="button"
                  className="p-1.5 rounded-md text-amber-600 hover:bg-amber-50 transition-colors"
                  aria-label={t('archived.bannerAria', 'Avís sobre eliminació permanent')}
                >
                  <AlertTriangle className="h-4 w-4" />
                </button>
              </DrawerTrigger>
              <div className="pointer-events-none absolute right-0 top-full mt-1.5 z-50 w-72 rounded-md border bg-popover px-3 py-2 text-xs text-popover-foreground shadow-md opacity-0 group-hover:opacity-100 transition-opacity">
                {t('archived.banner', "Eliminar documents arxivats és una acció irreversible. Els fitxers s'esborraran definitivament.")}
              </div>
            </div>
            <DrawerContent>
              <DrawerHeader>
                <DrawerTitle className="flex items-center gap-2 text-amber-700">
                  <AlertTriangle className="h-4 w-4" />
                  {t('archived.bannerTitle', 'Acció irreversible')}
                </DrawerTitle>
                <DrawerDescription>
                  {t('archived.banner', "Eliminar documents arxivats és una acció irreversible. Els fitxers s'esborraran definitivament.")}
                </DrawerDescription>
              </DrawerHeader>
            </DrawerContent>
          </Drawer>
        </div>

        {/* Cerca */}
        <div className="relative">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground pointer-events-none" />
          <Input
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
            placeholder={t('archived.search', 'Cerca documents arxivats...')}
            className="pl-9"
          />
          {searchTerm && (
            <button
              type="button"
              onClick={() => setSearchTerm('')}
              className="absolute right-2.5 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
            >
              <X className="h-4 w-4" />
            </button>
          )}
        </div>

        {/* Pills de categoria */}
        {availableCategories.length > 0 && (
          <div className="flex items-center gap-2 flex-wrap">
            <button
              type="button"
              onClick={() => setSelectedCategory(null)}
              className={`inline-flex items-center gap-1 text-xs px-2.5 py-1 rounded-full border transition-colors ${
                !selectedCategory
                  ? 'bg-foreground text-background border-foreground'
                  : 'text-muted-foreground border-border hover:bg-muted/60'
              }`}
            >
              {t('page.filterAll', 'Tots')}
            </button>
            {availableCategories.map((cat) => (
              <button
                key={cat}
                type="button"
                onClick={() => setSelectedCategory(selectedCategory === cat ? null : cat)}
                className={`inline-flex items-center gap-1 text-xs px-2.5 py-1 rounded-full border transition-colors ${
                  selectedCategory === cat
                    ? 'bg-indigo-600 text-white border-indigo-600'
                    : 'text-muted-foreground border-border hover:bg-muted/60'
                }`}
              >
                <Tag className="h-3 w-3" />
                {cat}
              </button>
            ))}
          </div>
        )}

        {/* Llista */}
        {isLoading ? (
          <div className="text-sm text-muted-foreground py-8 text-center">
            {t('page.loading', 'Carregant...')}
          </div>
        ) : archivedDocs.length === 0 ? (
          <div className="flex flex-col items-center gap-3 py-16 text-center text-muted-foreground">
            <Archive className="h-10 w-10 opacity-30" />
            <p className="text-sm">{t('archived.emptyState', "Cap document arxivat")}</p>
          </div>
        ) : filteredDocs.length === 0 ? (
          <div className="flex flex-col items-center gap-3 py-16 text-center text-muted-foreground">
            <Search className="h-10 w-10 opacity-30" />
            <p className="text-sm">{t('page.emptySearch', 'Cap resultat per a la cerca')}</p>
            <button
              type="button"
              onClick={() => { setSearchTerm(''); setSelectedCategory(null) }}
              className="text-xs text-primary hover:underline"
            >
              {t('page.clearFilters', 'Esborrar filtres')}
            </button>
          </div>
        ) : (
          <div className="space-y-2">
            {filteredDocs.map((doc) => (
              <ArchivedDocumentRow
                key={doc.id}
                doc={doc}
                canWrite={canWrite}
                onUnarchive={setUnarchiveTarget}
                onDelete={setDeleteTarget}
              />
            ))}
          </div>
        )}
      </div>

      {/* Diàleg: Desarxivar */}
      <Dialog open={!!unarchiveTarget} onOpenChange={(v) => { if (!v) setUnarchiveTarget(null) }}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>{t('archived.unarchiveConfirmTitle', 'Restaurar document')}</DialogTitle>
            <DialogDescription>
              {t('archived.unarchiveConfirmDesc', "El document '{{title}}' tornarà a ser visible a la llista de documents actius.", { title: unarchiveTarget?.title })}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setUnarchiveTarget(null)}>
              {t('common.cancel', 'Cancel·lar')}
            </Button>
            <Button
              onClick={handleUnarchive}
              disabled={unarchiveMutation.isPending}
              className="bg-indigo-600 hover:bg-indigo-700 text-white"
            >
              {t('archived.unarchive', 'Desarxivar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Diàleg: Eliminar definitivament */}
      <Dialog open={!!deleteTarget} onOpenChange={(v) => { if (!v) setDeleteTarget(null) }}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>{t('archived.deleteConfirmTitle', 'Eliminar document definitivament')}</DialogTitle>
            <DialogDescription>
              {t('archived.deleteConfirmDesc', "S'eliminaran totes les versions i fitxers del document '{{title}}'. Aquesta acció és irreversible.", { title: deleteTarget?.title })}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setDeleteTarget(null)}>
              {t('common.cancel', 'Cancel·lar')}
            </Button>
            <Button
              variant="destructive"
              onClick={handleDelete}
              disabled={deleteMutation.isPending}
            >
              {t('row.deleteConfirm', 'Eliminar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
