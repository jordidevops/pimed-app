import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { BookOpen, Plus, Trash2 } from 'lucide-react'
import { useTenant } from '../../contexts/TenantContext'
import { useToast } from '../../hooks/use-toast'
import { useTenantFeatures } from '../../features/entity-timeline/api/useTenantFeatures'
import { TimelineFeatureDisabledNotice } from '../../features/entity-timeline/components/TimelineFeatureDisabledNotice'
import {
  deleteAuditEventPlaybook,
  listAuditEventPlaybooks,
  PLAYBOOK_AUDIT_ACTIONS,
  upsertAuditEventPlaybook,
  type AuditEventPlaybook,
} from '../../features/entity-timeline/api/playbookService'
import { listCommentTemplates } from '../../features/entity-timeline/api/timelineService'

export function PlaybooksPage() {
  const { t } = useTranslation('settings')
  const { toast } = useToast()
  const { activeRole, activeTenant } = useTenant()
  const { data: features, isLoading: featuresLoading } = useTenantFeatures()
  const queryClient = useQueryClient()
  const canManage = activeRole === 'owner' || activeRole === 'manager'

  const [formOpen, setFormOpen] = useState(false)
  const [action, setAction] = useState<string>('EMPLOYEE_TERMINATED')
  const [templateId, setTemplateId] = useState('')

  const { data: playbooks = [], isLoading, isError } = useQuery({
    queryKey: ['audit-event-playbooks'],
    queryFn: listAuditEventPlaybooks,
    enabled: canManage,
  })

  const { data: templates = [] } = useQuery({
    queryKey: ['comment-templates-playbooks'],
    queryFn: () => listCommentTemplates(),
    enabled: canManage,
  })

  const grouped = useMemo(() => {
    const map = new Map<string, AuditEventPlaybook[]>()
    for (const pb of playbooks) {
      const list = map.get(pb.action) ?? []
      list.push(pb)
      map.set(pb.action, list)
    }
    for (const [, list] of map) {
      list.sort((a, b) => a.sort_order - b.sort_order)
    }
    return map
  }, [playbooks])

  const saveMutation = useMutation({
    mutationFn: () =>
      upsertAuditEventPlaybook({
        action,
        template_id: templateId,
      }),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['audit-event-playbooks'] })
      setFormOpen(false)
      setTemplateId('')
      toast({ description: t('playbooks.saved', 'Playbook desat') })
    },
    onError: () => {
      toast({
        variant: 'destructive',
        description: t('playbooks.save_error', 'No s\'ha pogut desar el playbook'),
      })
    },
  })

  const toggleMutation = useMutation({
    mutationFn: (pb: AuditEventPlaybook) =>
      upsertAuditEventPlaybook({
        id: pb.id,
        action: pb.action,
        template_id: pb.template_id,
        sort_order: pb.sort_order,
        is_active: !pb.is_active,
      }),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['audit-event-playbooks'] })
    },
  })

  const deleteMutation = useMutation({
    mutationFn: deleteAuditEventPlaybook,
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['audit-event-playbooks'] })
      toast({ description: t('playbooks.deleted', 'Playbook eliminat') })
    },
  })

  if (!featuresLoading && features?.entity_timeline_playbooks === false) {
    return (
      <TimelineFeatureDisabledNotice
        titleKey="playbooks.feature_disabled_title"
        titleDefault="Playbooks no disponibles"
        descriptionKey="playbooks.feature_disabled_description"
        descriptionDefault="Aquesta funcionalitat no està inclosa al pla de la teva organització. Contacta amb suport per ampliar el pla."
      />
    )
  }

  if (!canManage) {
    return (
      <p className="text-sm text-muted-foreground">
        {t('playbooks.forbidden', 'Només owner/manager pot gestionar playbooks.')}
      </p>
    )
  }

  return (
    <div className="space-y-6 max-w-3xl">
      <div className="flex items-start justify-between gap-4">
        <div className="flex items-start gap-3">
          <BookOpen className="h-6 w-6 text-primary shrink-0 mt-0.5" aria-hidden />
          <div>
            <h3 className="text-base font-semibold text-foreground">
              {t('playbooks.title', 'Protocols automàtics')}
            </h3>
            <p className="text-sm text-muted-foreground mt-1">
              {t('playbooks.description', 'Tasques de protocol quan es registra un esdeveniment d\'auditoria (actor Sistema).')}
            </p>
          </div>
        </div>
        <button
          type="button"
          onClick={() => setFormOpen((v) => !v)}
          className="inline-flex items-center gap-1.5 text-sm text-primary hover:underline shrink-0"
        >
          <Plus className="h-4 w-4" aria-hidden />
          {t('playbooks.add', 'Afegir')}
        </button>
      </div>

      {formOpen && (
        <form
          className="rounded-xl border border-border bg-card p-4 space-y-3"
          onSubmit={(e) => {
            e.preventDefault()
            if (!templateId) return
            saveMutation.mutate()
          }}
        >
          <label className="block text-sm">
            <span className="text-muted-foreground">{t('playbooks.action', 'Event audit')}</span>
            <select
              className="mt-1 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
              value={action}
              onChange={(e) => setAction(e.target.value)}
            >
              {PLAYBOOK_AUDIT_ACTIONS.map((a) => (
                <option key={a} value={a}>{a}</option>
              ))}
            </select>
          </label>
          <label className="block text-sm">
            <span className="text-muted-foreground">{t('playbooks.template', 'Plantilla')}</span>
            <select
              className="mt-1 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
              value={templateId}
              onChange={(e) => setTemplateId(e.target.value)}
              required
            >
              <option value="">{t('playbooks.template_placeholder', 'Selecciona plantilla...')}</option>
              {templates.map((tpl) => (
                <option key={tpl.id} value={tpl.id}>{tpl.title}</option>
              ))}
            </select>
          </label>
          <button
            type="submit"
            disabled={saveMutation.isPending || !templateId}
            className="text-sm bg-primary text-primary-foreground px-4 py-2 rounded-md disabled:opacity-50"
          >
            {t('playbooks.save', 'Desar')}
          </button>
        </form>
      )}

      {isLoading ? (
        <p className="text-sm text-muted-foreground">{t('playbooks.loading', 'Carregant...')}</p>
      ) : isError ? (
        <p className="text-sm text-destructive">
          {t('playbooks.load_error', 'No s\'han pogut carregar els playbooks.')}
        </p>
      ) : playbooks.length === 0 ? (
        <p className="text-sm text-muted-foreground">{t('playbooks.empty', 'Cap playbook configurat.')}</p>
      ) : (
        <div className="space-y-6">
          {[...grouped.entries()].map(([auditAction, items]) => (
            <section key={auditAction}>
              <h3 className="text-sm font-semibold text-foreground mb-2">{auditAction}</h3>
              <ul className="space-y-2">
                {items.map((pb) => (
                  <li
                    key={pb.id}
                    className="rounded-xl border border-border bg-card p-4 flex flex-col sm:flex-row sm:items-center gap-3"
                  >
                    <div className="flex-1 min-w-0">
                      <p className="font-medium text-foreground">{pb.template_title}</p>
                      <p className="text-xs text-muted-foreground line-clamp-2 mt-0.5">{pb.template_body}</p>
                    </div>
                    <div className="flex items-center gap-3 shrink-0">
                      <label className="flex items-center gap-2 text-sm cursor-pointer">
                        <input
                          type="checkbox"
                          checked={pb.is_active}
                          disabled={toggleMutation.isPending}
                          onChange={() => toggleMutation.mutate(pb)}
                        />
                        {t('playbooks.active', 'Actiu')}
                      </label>
                      <button
                        type="button"
                        className="text-destructive hover:opacity-80"
                        disabled={deleteMutation.isPending}
                        onClick={() => deleteMutation.mutate(pb.id)}
                        title={t('playbooks.delete', 'Eliminar')}
                      >
                        <Trash2 className="h-4 w-4" aria-hidden />
                      </button>
                    </div>
                  </li>
                ))}
              </ul>
            </section>
          ))}
        </div>
      )}
    </div>
  )
}
