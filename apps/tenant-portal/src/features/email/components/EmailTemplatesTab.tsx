import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Pencil, RotateCcw, Copy } from 'lucide-react'
import { useEmailTemplates, useEmailLayouts } from '../api/useEmailTemplates'
import { useEmailTemplateMutations } from '../api/useEmailTemplateMutations'
import { EmailTemplateEditor } from './EmailTemplateEditor'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Spinner } from '@/components/ui/Spinner'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '@/components/ui/dialog'
import type { EmailTemplate } from '../types'

interface EmailTemplatesTabProps {
  tenantId: string
}

interface TemplateRow {
  eventType: string
  platform: EmailTemplate
  tenant: EmailTemplate | null
}

export function EmailTemplatesTab({ tenantId }: EmailTemplatesTabProps) {
  const { t } = useTranslation('email')
  const { data: allTemplates = [], isLoading, isError } = useEmailTemplates(tenantId)
  const { data: allLayouts = [], isLoading: layoutsLoading } = useEmailLayouts(tenantId)
  const { deleteTemplate } = useEmailTemplateMutations(tenantId)

  const [editorTemplate, setEditorTemplate] = useState<EmailTemplate | null>(null)
  const [deleteConfirm, setDeleteConfirm] = useState<EmailTemplate | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)

  // Separar plantilles de plataforma i de tenant
  const platformTemplates = allTemplates.filter(
    (t) => t.is_platform_default && t.event_type,
  )
  const tenantTemplates = allTemplates.filter((t) => !t.is_platform_default)

  // Mapa event_type → plantilla del tenant
  const tenantByEvent = new Map<string, EmailTemplate>()
  for (const tpl of tenantTemplates) {
    if (tpl.event_type) tenantByEvent.set(tpl.event_type, tpl)
  }

  // Plantilles standalone del tenant (sense event_type)
  const standaloneTemplates = tenantTemplates.filter((t) => !t.event_type)

  // ── Layouts ──────────────────────────────────────────────────────────────
  const platformLayouts = allLayouts.filter((l) => l.is_platform_default)
  const tenantLayouts = allLayouts.filter((l) => !l.is_platform_default)
  const tenantLayoutBySlug = new Map<string, EmailTemplate>()
  for (const l of tenantLayouts) {
    if (l.slug) tenantLayoutBySlug.set(l.slug, l)
  }
  const layoutRows: TemplateRow[] = platformLayouts.map((p) => ({
    eventType: p.slug ?? p.id,
    platform: p,
    tenant: tenantLayoutBySlug.get(p.slug ?? '') ?? null,
  }))

  // Combinar: per a cada event de plataforma, mostrar override del tenant o la de plataforma
  const rows: TemplateRow[] = platformTemplates.map((p) => ({
    eventType: p.event_type!,
    platform: p,
    tenant: tenantByEvent.get(p.event_type!) ?? null,
  }))

  /**
   * Obre l'editor directament amb la plantilla del tenant (si existeix)
   * o la de plataforma. El clon NO es crea fins que l'usuari premi "Desar".
   */
  const handleEdit = (row: TemplateRow) => {
    setActionError(null)
    setEditorTemplate(row.tenant ?? row.platform)
  }

  const handleRestore = (tenant: EmailTemplate) => {
    setDeleteConfirm(tenant)
  }

  const confirmRestore = async () => {
    if (!deleteConfirm) return
    setActionError(null)
    try {
      await deleteTemplate.mutateAsync(deleteConfirm.id)
    } catch (err) {
      setActionError((err as Error).message)
    } finally {
      setDeleteConfirm(null)
    }
  }

  if (isLoading) {
    return (
      <div className="flex justify-center py-12">
        <Spinner />
      </div>
    )
  }

  if (isError) {
    return (
      <p className="text-sm text-destructive py-4">
        {t('email.templates.load_error', 'Error en carregar les plantilles.')}
      </p>
    )
  }

  return (
    <div className="space-y-6">
      {/* ─── Plantilles per event ─── */}
      <section>
        <h3 className="text-sm font-semibold text-foreground mb-3">
          {t('email.templates.events_section_title', 'Plantilles per event')}
        </h3>
        <p className="text-xs text-muted-foreground mb-4">
          {t(
            'email.templates.events_section_desc',
            "Per a cada tipus d'event, el sistema usa la teva plantilla personalitzada si n'hi ha, o la predefinida de la plataforma com a fallback.",
          )}
        </p>

        {rows.length === 0 ? (
          <p className="text-sm text-muted-foreground py-4">
            {t(
              'email.templates.no_platform_templates',
              'No hi ha plantilles de plataforma configurades.',
            )}
          </p>
        ) : (
          <div className="divide-y divide-border rounded-md border border-border">
            {rows.map((row) => {
              const active = row.tenant ?? row.platform
              const isCustom = !!row.tenant
              const isDraft = row.tenant?.is_draft ?? false

              return (
                <div
                  key={row.eventType}
                  className="flex items-center justify-between gap-4 px-4 py-3"
                >
                  {/* Info */}
                  <div className="min-w-0 flex-1 space-y-0.5">
                    <div className="flex items-center gap-2 flex-wrap">
                      <span className="text-sm font-medium text-foreground truncate">
                        {active.name}
                      </span>
                      {isCustom ? (
                        <Badge variant="default" className="bg-blue-600 text-white shrink-0">
                          {t('email.templates.badge_custom', 'Personalitzada')}
                        </Badge>
                      ) : (
                        <Badge variant="secondary" className="shrink-0">
                          {t(
                            'email.templates.badge_platform',
                            'Per defecte de la plataforma',
                          )}
                        </Badge>
                      )}
                      {isDraft && (
                        <Badge variant="outline" className="shrink-0">
                          {t('email.templates.badge_draft', 'Esborrany')}
                        </Badge>
                      )}
                    </div>
                    <p className="text-xs text-muted-foreground font-mono">
                      {row.eventType}
                    </p>
                  </div>

                  {/* Accions */}
                  <div className="flex items-center gap-2 shrink-0">
                    {!isCustom && (
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() => handleEdit(row)}
                      >
                        <Copy className="h-3.5 w-3.5 mr-1.5" />
                        {t('email.templates.action_customize', 'Personalitzar')}
                      </Button>
                    )}
                    {isCustom && (
                      <>
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => setEditorTemplate(row.tenant!)}
                        >
                          <Pencil className="h-3.5 w-3.5 mr-1.5" />
                          {t('email.templates.action_edit', 'Editar')}
                        </Button>
                        <Button
                          size="sm"
                          variant="ghost"
                          className="text-muted-foreground hover:text-destructive"
                          onClick={() => handleRestore(row.tenant!)}
                        >
                          <RotateCcw className="h-3.5 w-3.5 mr-1.5" />
                          {t('email.templates.action_restore', 'Restaurar per defecte')}
                        </Button>
                      </>
                    )}
                  </div>
                </div>
              )
            })}
          </div>
        )}
      </section>

      {/* ─── Plantilles standalone (sense event_type) ─── */}
      {standaloneTemplates.length > 0 && (
        <section>
          <h3 className="text-sm font-semibold text-foreground mb-3">
            {t('email.templates.standalone_section_title', 'Plantilles addicionals')}
          </h3>
          <div className="divide-y divide-border rounded-md border border-border">
            {standaloneTemplates.map((tpl) => (
              <div
                key={tpl.id}
                className="flex items-center justify-between gap-4 px-4 py-3"
              >
                <div className="min-w-0 flex-1 space-y-0.5">
                  <div className="flex items-center gap-2 flex-wrap">
                    <span className="text-sm font-medium text-foreground truncate">
                      {tpl.name}
                    </span>
                    {tpl.is_draft && (
                      <Badge variant="outline" className="shrink-0">
                        {t('email.templates.badge_draft', 'Esborrany')}
                      </Badge>
                    )}
                  </div>
                  <p className="text-xs text-muted-foreground font-mono">{tpl.slug}</p>
                </div>
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => setEditorTemplate(tpl)}
                >
                  <Pencil className="h-3.5 w-3.5 mr-1.5" />
                  {t('email.templates.action_edit', 'Editar')}
                </Button>
              </div>
            ))}
          </div>
        </section>
      )}

      {/* ─── Layouts globals ─── */}
      {!layoutsLoading && layoutRows.length > 0 && (
        <section>
          <h3 className="text-sm font-semibold text-foreground mb-3">
            {t('email.templates.layouts_section_title', 'Layouts globals')}
          </h3>
          <p className="text-xs text-muted-foreground mb-4">
            {t(
              'email.templates.layouts_section_desc',
              "El layout és el marc visual (capçalera, peu de pàgina, colors) que embolcalla totes les plantilles de correu. Pots personalitzar-lo o usar un dels predefinits de la plataforma.",
            )}
          </p>
          <div className="divide-y divide-border rounded-md border border-border">
            {layoutRows.map((row) => {
              const active = row.tenant ?? row.platform
              const isCustom = !!row.tenant
              const isDraft = row.tenant?.is_draft ?? false

              return (
                <div
                  key={row.eventType}
                  className="flex items-center justify-between gap-4 px-4 py-3"
                >
                  <div className="min-w-0 flex-1 space-y-0.5">
                    <div className="flex items-center gap-2 flex-wrap">
                      <span className="text-sm font-medium text-foreground truncate">
                        {active.name}
                      </span>
                      {isCustom ? (
                        <Badge variant="default" className="bg-blue-600 text-white shrink-0">
                          {t('email.templates.badge_custom', 'Personalitzada')}
                        </Badge>
                      ) : (
                        <Badge variant="secondary" className="shrink-0">
                          {t('email.templates.badge_platform', 'Per defecte de la plataforma')}
                        </Badge>
                      )}
                      {isDraft && (
                        <Badge variant="outline" className="shrink-0">
                          {t('email.templates.badge_draft', 'Esborrany')}
                        </Badge>
                      )}
                    </div>
                    <p className="text-xs text-muted-foreground font-mono">
                      {row.platform.slug}
                    </p>
                  </div>

                  <div className="flex items-center gap-2 shrink-0">
                    {!isCustom && (
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() => handleEdit(row)}
                      >
                        <Copy className="h-3.5 w-3.5 mr-1.5" />
                        {t('email.templates.action_customize', 'Personalitzar')}
                      </Button>
                    )}
                    {isCustom && (
                      <>
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => setEditorTemplate(row.tenant!)}
                        >
                          <Pencil className="h-3.5 w-3.5 mr-1.5" />
                          {t('email.templates.action_edit', 'Editar')}
                        </Button>
                        <Button
                          size="sm"
                          variant="ghost"
                          className="text-muted-foreground hover:text-destructive"
                          onClick={() => handleRestore(row.tenant!)}
                        >
                          <RotateCcw className="h-3.5 w-3.5 mr-1.5" />
                          {t('email.templates.action_restore', 'Restaurar per defecte')}
                        </Button>
                      </>
                    )}
                  </div>
                </div>
              )
            })}
          </div>
        </section>
      )}

      {/* Error d'acció */}
      {actionError && (
        <p className="text-sm text-destructive">{actionError}</p>
      )}

      {/* ─── Dialog confirmació restaurar ─── */}
      <Dialog
        open={!!deleteConfirm}
        onOpenChange={(open) => !open && setDeleteConfirm(null)}
      >
        <DialogContent>
          <DialogHeader>
            <DialogTitle>
              {t('email.templates.restore_dialog_title', 'Restaurar valors per defecte')}
            </DialogTitle>
          </DialogHeader>
          <p className="text-sm text-muted-foreground">
            {t(
              'email.templates.restore_dialog_desc',
              "S'eliminarà la teva plantilla personalitzada «{{name}}». A partir d'ara s'usarà la plantilla predefinida de la plataforma.",
              { name: deleteConfirm?.name ?? '' },
            )}
          </p>
          <DialogFooter>
            <Button variant="outline" onClick={() => setDeleteConfirm(null)}>
              {t('email.templates.restore_dialog_cancel', 'Cancel·lar')}
            </Button>
            <Button
              variant="destructive"
              onClick={confirmRestore}
              disabled={deleteTemplate.isPending}
            >
              {deleteTemplate.isPending
                ? t('email.templates.restoring', 'Eliminant...')
                : t('email.templates.restore_dialog_confirm', 'Restaurar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* ─── Editor de plantilla ─── */}
      <EmailTemplateEditor
        template={editorTemplate}
        tenantId={tenantId}
        onClose={() => setEditorTemplate(null)}
      />
    </div>
  )
}
