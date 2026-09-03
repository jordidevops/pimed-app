import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Plus, Copy, Pencil, Trash2, Shield, Building2, Code2, AlignLeft, Eye } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Input } from '@/components/ui/input'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useContentBlocks, type ContentBlock, type BlockType, type BlockFormat } from '@/features/signing/api/useContentBlocks'
import {
  useCreateContentBlockMutation,
  useUpdateContentBlockMutation,
  useDeleteContentBlockMutation,
  useCloneContentBlockMutation,
} from '@/features/signing/api/useContentBlockMutations'

type FilterType = 'ALL' | BlockType

const BLOCK_TYPE_OPTIONS: { value: BlockType; labelKey: string }[] = [
  { value: 'PAGE_HEADER',     labelKey: 'blocks.typePageHeader' },
  { value: 'PAGE_FOOTER',     labelKey: 'blocks.typePageFooter' },
  { value: 'DOCUMENT_HEADER', labelKey: 'blocks.typeDocumentHeader' },
  { value: 'DOCUMENT_FOOTER', labelKey: 'blocks.typeDocumentFooter' },
  { value: 'CUSTOM',          labelKey: 'blocks.typeCustom' },
]

const FORMAT_OPTIONS: { value: BlockFormat; labelKey: string }[] = [
  { value: 'HTML', labelKey: 'blocks.formatHtml' },
  { value: 'TEXT', labelKey: 'blocks.formatText' },
]

interface BlockFormState {
  name:      string
  blockType: BlockType
  format:    BlockFormat
  content:   string
}

const DEFAULT_FORM: BlockFormState = {
  name:      '',
  blockType: 'CUSTOM',
  format:    'HTML',
  content:   '',
}

export function ContentBlocksSection() {
  const { t } = useTranslation('signing')
  const { activeTenant } = useTenant()
  const activeTenantId = activeTenant?.id ?? null
  const { toast } = useToast()

  const { data: blocks = [], isLoading } = useContentBlocks(activeTenantId ?? undefined)

  const createMut  = useCreateContentBlockMutation(activeTenantId ?? '')
  const updateMut  = useUpdateContentBlockMutation(activeTenantId ?? '')
  const deleteMut  = useDeleteContentBlockMutation(activeTenantId ?? '')
  const cloneMut   = useCloneContentBlockMutation(activeTenantId ?? '')

  const [filter, setFilter]         = useState<FilterType>('ALL')
  const [dialogOpen, setDialogOpen] = useState(false)
  const [editing, setEditing]       = useState<ContentBlock | null>(null)
  const [form, setForm]             = useState<BlockFormState>(DEFAULT_FORM)
  const [deleteTarget, setDeleteTarget] = useState<ContentBlock | null>(null)
  const [viewBlock, setViewBlock]   = useState<ContentBlock | null>(null)

  // ── Filtratge ──────────────────────────────────────────────────────────────
  const visible = filter === 'ALL'
    ? blocks
    : blocks.filter(b => b.block_type === filter)

  // ── Accions ────────────────────────────────────────────────────────────────
  function openCreate() {
    setEditing(null)
    setForm(DEFAULT_FORM)
    setDialogOpen(true)
  }

  function openEdit(block: ContentBlock) {
    setEditing(block)
    setForm({
      name:      block.name ?? '',
      blockType: (block.block_type as BlockType) ?? 'CUSTOM',
      format:    (block.format as BlockFormat) ?? 'HTML',
      content:   block.content ?? '',
    })
    setDialogOpen(true)
  }

  async function handleSave() {
    if (!activeTenantId || !form.name.trim()) return

    try {
      if (editing) {
        await updateMut.mutateAsync({
          blockId:  editing.id!,
          tenantId: activeTenantId,
          name:     form.name,
          content:  form.content,
          format:   form.format,
        })
        toast({ title: t('blocks.updateSuccess', 'Bloc actualitzat') })
      } else {
        await createMut.mutateAsync({
          tenantId:  activeTenantId,
          name:      form.name,
          blockType: form.blockType,
          format:    form.format,
          content:   form.content,
        })
        toast({ title: t('blocks.createSuccess', 'Bloc creat') })
      }
      setDialogOpen(false)
    } catch (err) {
      toast({ title: (err as Error).message, variant: 'destructive' })
    }
  }

  async function handleClone(block: ContentBlock) {
    if (!activeTenantId) return
    try {
      await cloneMut.mutateAsync({
        sourceBlockId: block.id!,
        tenantId:      activeTenantId,
        newName:       `${block.name} (còpia)`,
      })
      toast({ title: t('blocks.cloneSuccess', 'Bloc clonat correctament') })
    } catch (err) {
      toast({ title: t('blocks.cloneError', 'Error en clonar el bloc'), variant: 'destructive' })
    }
  }

  async function handleDelete() {
    if (!activeTenantId || !deleteTarget) return
    try {
      await deleteMut.mutateAsync({ blockId: deleteTarget.id!, tenantId: activeTenantId })
      toast({ title: t('blocks.deleteSuccess', 'Bloc eliminat') })
    } catch (err) {
      toast({ title: (err as Error).message, variant: 'destructive' })
    } finally {
      setDeleteTarget(null)
    }
  }

  function blockTypeLabel(type: string | null) {
    const found = BLOCK_TYPE_OPTIONS.find(o => o.value === type)
    return found ? t(found.labelKey, found.value) : (type ?? '')
  }

  const isBusy = createMut.isPending || updateMut.isPending || cloneMut.isPending || deleteMut.isPending

  // ── Render ─────────────────────────────────────────────────────────────────
  return (
    <div className="rounded-lg border bg-card p-6 space-y-4">
      {/* Capçalera */}
      <div className="flex items-start justify-between gap-4">
        <div>
          <h3 className="text-base font-semibold text-foreground">
            {t('blocks.sectionTitle', 'Blocs de contingut')}
          </h3>
          <p className="text-sm text-muted-foreground mt-0.5">
            {t('blocks.sectionDescription', 'Capçaleres, peus de pàgina i blocs reutilitzables per als teus documents.')}
          </p>
        </div>
        <Button size="sm" onClick={openCreate} disabled={isBusy}>
          <Plus className="h-4 w-4 mr-1" />
          {t('blocks.newBlockButton', 'Nou bloc')}
        </Button>
      </div>

      {/* Filtres per tipus */}
      <div className="flex flex-wrap gap-1.5">
        {(['ALL', 'PAGE_HEADER', 'PAGE_FOOTER', 'DOCUMENT_HEADER', 'DOCUMENT_FOOTER', 'CUSTOM'] as const).map(f => (
          <button
            key={f}
            onClick={() => setFilter(f)}
            className={`px-2.5 py-1 rounded-full text-xs font-medium transition-colors ${
              filter === f
                ? 'bg-primary text-primary-foreground'
                : 'bg-muted text-muted-foreground hover:bg-muted/80'
            }`}
          >
            {f === 'ALL'             ? t('blocks.filterAll', 'Tots')
            : f === 'PAGE_HEADER'    ? t('blocks.filterPageHeader', 'Cap. pàgina')
            : f === 'PAGE_FOOTER'    ? t('blocks.filterPageFooter', 'Peu pàgina')
            : f === 'DOCUMENT_HEADER'? t('blocks.filterDocHeader', 'Cap. document')
            : f === 'DOCUMENT_FOOTER'? t('blocks.filterDocFooter', 'Peu document')
            :                          t('blocks.filterCustom', 'Personalitzat')}
          </button>
        ))}
      </div>

      {/* Llista de blocs */}
      {isLoading ? (
        <div className="py-6 text-center text-sm text-muted-foreground">…</div>
      ) : visible.length === 0 ? (
        <div className="py-6 text-center text-sm text-muted-foreground">
          {t('blocks.emptyState', 'No hi ha blocs de contingut. Crea\'n un o clona un bloc de sistema.')}
        </div>
      ) : (
        <div className="divide-y rounded-md border overflow-hidden">
          {visible.map(block => {
            const isSystem = block.is_platform_default
            return (
              <div key={block.id} className="flex items-center gap-3 px-4 py-3 bg-background hover:bg-muted/40 transition-colors">
                {/* Icona format */}
                <div className="shrink-0 text-muted-foreground">
                  {block.format === 'HTML' ? <Code2 className="h-4 w-4" /> : <AlignLeft className="h-4 w-4" />}
                </div>

                {/* Info principal */}
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2 flex-wrap">
                    <span className="text-sm font-medium truncate">{block.name}</span>
                    {isSystem ? (
                      <Badge variant="secondary" className="text-xs gap-1">
                        <Shield className="h-3 w-3" />
                        {t('blocks.systemBadge', 'Sistema')}
                      </Badge>
                    ) : (
                      <Badge variant="outline" className="text-xs gap-1">
                        <Building2 className="h-3 w-3" />
                        {t('blocks.tenantBadge', 'Pròpia')}
                      </Badge>
                    )}
                    <span className="text-xs text-muted-foreground">{blockTypeLabel(block.block_type)}</span>
                  </div>
                </div>

                {/* Botons d'acció */}
                <div className="flex items-center gap-1 shrink-0">
                  {isSystem ? (
                    <>
                      <Button
                        variant="ghost"
                        size="sm"
                        className="h-7 px-2 text-xs"
                        onClick={() => setViewBlock(block)}
                      >
                        <Eye className="h-3.5 w-3.5 mr-1" />
                        {t('blocks.viewButton', 'Veure')}
                      </Button>
                      <Button
                        variant="ghost"
                        size="sm"
                        className="h-7 px-2 text-xs"
                        onClick={() => handleClone(block)}
                        disabled={isBusy}
                      >
                        <Copy className="h-3.5 w-3.5 mr-1" />
                        {t('blocks.cloneButton', 'Clonar')}
                      </Button>
                    </>
                  ) : (
                    <>
                      <Button
                        variant="ghost"
                        size="sm"
                        className="h-7 px-2 text-xs"
                        onClick={() => openEdit(block)}
                        disabled={isBusy}
                      >
                        <Pencil className="h-3.5 w-3.5 mr-1" />
                        {t('blocks.editButton', 'Editar')}
                      </Button>
                      <Button
                        variant="ghost"
                        size="sm"
                        className="h-7 px-2 text-xs text-destructive hover:text-destructive"
                        onClick={() => setDeleteTarget(block)}
                        disabled={isBusy}
                      >
                        <Trash2 className="h-3.5 w-3.5" />
                      </Button>
                    </>
                  )}
                </div>
              </div>
            )
          })}
        </div>
      )}

      {/* Dialog crear/editar */}
      <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
        <DialogContent className="max-w-2xl">
          <DialogHeader>
            <DialogTitle>
              {editing
                ? t('blocks.dialogEditTitle', 'Editar bloc')
                : t('blocks.dialogCreateTitle', 'Nou bloc de contingut')}
            </DialogTitle>
          </DialogHeader>

          <div className="space-y-4 py-2">
            {/* Nom */}
            <div className="space-y-1.5">
              <label className="text-xs font-medium text-muted-foreground">{t('blocks.fieldName', 'Nom')}</label>
              <Input
                value={form.name}
                onChange={e => setForm(f => ({ ...f, name: e.target.value }))}
                placeholder={t('blocks.fieldNamePlaceholder', 'Ex: Peu legal estàndard')}
              />
            </div>

            {/* Tipus + Format (només creació) */}
            {!editing && (
              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-1.5">
                  <label className="text-xs font-medium text-muted-foreground">{t('blocks.fieldBlockType', 'Tipus')}</label>
                  <select
                    value={form.blockType}
                    onChange={e => setForm(f => ({ ...f, blockType: e.target.value as BlockType }))}
                    className="h-9 w-full text-sm border rounded-md px-2 bg-background"
                  >
                    {BLOCK_TYPE_OPTIONS.map(o => (
                      <option key={o.value} value={o.value}>
                        {t(o.labelKey, o.value)}
                      </option>
                    ))}
                  </select>
                </div>

                <div className="space-y-1.5">
                  <label className="text-xs font-medium text-muted-foreground">{t('blocks.fieldFormat', 'Format')}</label>
                  <select
                    value={form.format}
                    onChange={e => setForm(f => ({ ...f, format: e.target.value as BlockFormat }))}
                    className="h-9 w-full text-sm border rounded-md px-2 bg-background"
                  >
                    {FORMAT_OPTIONS.map(o => (
                      <option key={o.value} value={o.value}>
                        {t(o.labelKey, o.value)}
                      </option>
                    ))}
                  </select>
                </div>
              </div>
            )}

            {/* Contingut */}
            <div className="space-y-1.5">
              <label className="text-xs font-medium text-muted-foreground">{t('blocks.fieldContent', 'Contingut')}</label>
              <textarea
                value={form.content}
                onChange={e => setForm(f => ({ ...f, content: e.target.value }))}
                rows={10}
                className="w-full rounded-md border bg-background px-3 py-2 font-mono text-sm resize-y"
              />
            </div>
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={() => setDialogOpen(false)}>
              {t('blocks.cancelButton', 'Cancel·lar')}
            </Button>
            <Button onClick={handleSave} disabled={isBusy || !form.name.trim()}>
              {t('blocks.saveButton', 'Desar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Dialog veure bloc de sistema (read-only) */}
      {viewBlock && (
        <Dialog open onOpenChange={open => { if (!open) setViewBlock(null) }}>
          <DialogContent className="max-w-2xl">
            <DialogHeader>
              <DialogTitle className="flex items-center gap-2">
                <Shield className="h-4 w-4 text-muted-foreground" />
                {viewBlock.name}
              </DialogTitle>
            </DialogHeader>
            <div className="space-y-3 py-1">
              <div className="flex gap-4 text-xs text-muted-foreground">
                <span>{t('blocks.fieldBlockType', 'Tipus')}: <strong>{blockTypeLabel(viewBlock.block_type)}</strong></span>
                <span>{t('blocks.fieldFormat', 'Format')}: <strong>{viewBlock.format}</strong></span>
              </div>
              <div className="rounded-md border bg-muted/30 p-3 font-mono text-xs whitespace-pre-wrap break-all max-h-80 overflow-y-auto">
                {viewBlock.content || <span className="text-muted-foreground italic">{t('blocks.emptyContent', '(sense contingut)')}</span>}
              </div>
            </div>
            <DialogFooter>
              <Button variant="outline" onClick={() => setViewBlock(null)}>
                {t('blocks.closeButton', 'Tancar')}
              </Button>
              <Button onClick={() => { setViewBlock(null); handleClone(viewBlock) }} disabled={isBusy || !activeTenantId}>
                <Copy className="h-3.5 w-3.5 mr-1" />
                {t('blocks.cloneButton', 'Clonar')}
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      )}
      {deleteTarget && (
        <Dialog open onOpenChange={open => { if (!open) setDeleteTarget(null) }}>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>{t('blocks.deleteConfirmTitle', 'Eliminar bloc')}</DialogTitle>
            </DialogHeader>
            <p className="text-sm text-muted-foreground">
              {t('blocks.deleteConfirmMessage', 'Segur que vols eliminar «{{name}}»? Aquesta acció no es pot desfer.', {
                name: deleteTarget.name ?? '',
              })}
            </p>
            <DialogFooter>
              <Button variant="outline" onClick={() => setDeleteTarget(null)}>
                {t('blocks.cancelButton', 'Cancel·lar')}
              </Button>
              <Button variant="destructive" onClick={handleDelete} disabled={deleteMut.isPending}>
                {t('blocks.deleteConfirmButton', 'Eliminar')}
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      )}
    </div>
  )
}
