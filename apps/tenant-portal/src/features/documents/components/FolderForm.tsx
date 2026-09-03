import { useEffect, useState } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { useTranslation } from 'react-i18next'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Checkbox } from '@/components/ui/checkbox'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { folderSchema, type FolderFormValues } from '../schemas/folderSchema'
import { useCreateFolder } from '../api/useCreateFolder'
import { useUpdateFolder } from '../api/useUpdateFolder'
import type { Folder } from '../api/documentsService'

interface FolderFormProps {
  open: boolean
  onClose: () => void
  parentId?: string | null
  editFolder?: Folder | null
  /** Tipus d'entitat del mòdul (ex: 'employee'). Present en mode embedded. */
  entityType?: string
  /** ID del registre concret. Present en mode embedded. */
  entityId?: string
}

export function FolderForm({ open, onClose, parentId, editFolder, entityType, entityId }: FolderFormProps) {
  const { t } = useTranslation('documents')
  const { toast } = useToast()
  const { activeTenant, selectedSiteId, canUseAllSites, sites } = useTenant()
  const isEditing = !!editFolder
  const isEmbedded = !!entityType

  // Toggle: carpeta compartida per a tots els registres del mòdul (shared) vs. específica d'aquest registre
  const [isShared, setIsShared] = useState(true)
  // Site selector (solo visible per a usuaris globals quan no s'està editant)
  const [formSiteId, setFormSiteId] = useState<string | null>(null)

  const createMutation = useCreateFolder(parentId)
  const updateMutation = useUpdateFolder(parentId)

  const {
    register,
    handleSubmit,
    reset,
    formState: { errors, isSubmitting },
  } = useForm<FolderFormValues>({
    resolver: zodResolver(folderSchema),
    defaultValues: { name: '' },
  })

  useEffect(() => {
    if (!open) return
    reset({ name: editFolder?.name ?? '' })
    setIsShared(true) // sempre shared per defecte en crear
    setFormSiteId(selectedSiteId) // pre-selecciona el site actiu del context
  }, [open, editFolder, reset, selectedSiteId])

  async function onSubmit(values: FolderFormValues) {
    try {
      if (isEditing) {
        await updateMutation.mutateAsync({ id: editFolder!.id!, params: values })
        toast({ title: t('folders.updated', "Carpeta actualitzada") })
      } else {
        await createMutation.mutateAsync({
          tenant_id: activeTenant!.id!,
          name: values.name,
          parent_id: parentId ?? null,
          site_id: canUseAllSites ? (formSiteId ?? null) : (selectedSiteId ?? null),
          // Mode embedded: entity_type sempre present; entity_id = null si shared
          entity_type: isEmbedded ? entityType : null,
          entity_id: isEmbedded && !isShared ? entityId ?? null : null,
        })
        toast({ title: t('folders.created', "Carpeta creada") })
      }
      onClose()
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('folders.error', "Error en desar la carpeta"),
        description: err instanceof Error ? err.message : undefined,
      })
    }
  }

  return (
    <Dialog open={open} onOpenChange={(v) => !v && onClose()}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>
            {isEditing
              ? t('folders.editTitle', 'Reanomena la carpeta')
              : t('folders.createTitle', 'Nova carpeta')}
          </DialogTitle>
        </DialogHeader>
        <form onSubmit={handleSubmit(onSubmit)} className="space-y-4">
          <div>
            <label className="block text-sm font-medium mb-1">
              {t('folders.nameLabel', 'Nom')}
            </label>
            <Input {...register('name')} placeholder={t('folders.namePlaceholder', 'Nom de la carpeta')} />
            {errors.name && (
              <p className="text-xs text-destructive mt-1">
                {t(
                  errors.name.message ?? 'validation.folder_name_required',
                  'El nom és obligatori',
                )}
              </p>
            )}
          </div>

          {/* Selector de site: només en creació i per a usuaris amb accés global */}
          {!isEditing && canUseAllSites && (
            <div>
              <label className="block text-sm font-medium mb-1">
                {t('folders.siteLabel', 'Site (visibilitat)')}
              </label>
              <select
                value={formSiteId ?? ''}
                onChange={(e) => setFormSiteId(e.target.value || null)}
                title={t('folders.siteLabel', 'Site (visibilitat)')}
                aria-label={t('folders.siteLabel', 'Site (visibilitat)')}
                className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-ring"
              >
                <option value="">{t('folders.siteAll', 'Tots els sites (global)')}</option>
                {sites.map((s) => (
                  <option key={s.id} value={s.id}>{s.name}</option>
                ))}
              </select>
              <p className="text-xs text-muted-foreground mt-1">
                {t('folders.siteHint', 'Les carpetes globals s\'assignen automàticament a tots els sites')}
              </p>
            </div>
          )}

          {/* Toggle: només en mode embedded i quan es crea (no en edició) */}
          {isEmbedded && !isEditing && (
            <div className="flex items-start gap-3 rounded-md border p-3 bg-muted/30">
              <Checkbox
                id="folder-shared"
                checked={isShared}
                onCheckedChange={(checked: boolean | 'indeterminate') => setIsShared(checked === true)}
                className="mt-0.5"
              />
              <div className="space-y-0.5">
                <label htmlFor="folder-shared" className="text-sm font-medium cursor-pointer">
                  {t('folders.sharedToggle', 'Carpeta compartida amb tots els registres')}
                </label>
                <p className="text-xs text-muted-foreground">
                  {isShared
                    ? t('folders.sharedTooltip', "Aquesta carpeta apareixerà a tots els registres d'aquest mòdul")
                    : t('folders.specificTooltip', 'Aquesta carpeta serà exclusiva d\'aquest registre')}
                </p>
              </div>
            </div>
          )}

          <div className="flex justify-end gap-2">
            <Button type="button" variant="outline" onClick={onClose}>
              {t('common.cancel', 'Cancel·lar')}
            </Button>
            <Button type="submit" disabled={isSubmitting}>
              {isSubmitting
                ? t('common.saving', 'Desant...')
                : isEditing
                  ? t('common.save', 'Desar')
                  : t('common.create', 'Crear')}
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  )
}
