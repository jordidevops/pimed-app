import { AlertTriangle, FileCheck2, FolderCheck, ReceiptText } from 'lucide-react'
import { useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { usePermission } from '@/hooks/usePermission'
import {
  type CommercialDocument,
} from '@/features/commercial/api/commercialFlowService'
import { ProjectCommercialPanel } from '@/features/commercial/components/ProjectCommercialPanel'
import { CommercialDocumentStatusBadges } from '@/features/commercial/components/CommercialDocumentStatusBadge'
import { CommercialNativeSignDialog } from '@/features/commercial/components/CommercialNativeSignDialog'
import { ProjectBulletinPanel } from './ProjectBulletinPanel'

interface DeliverPhaseViewProps {
  projectId: string
  clientId: string | null
  siteId: string | null
  hasLines: boolean
  visitClosed: boolean
  workLocked: boolean
  publishedAt: string | null
  openReportByDefault?: boolean
  complete: boolean
  latestDeliveryId: string | null
  pendingAmendment: CommercialDocument | null
  serviceMode?: 'execute' | 'assessment' | null
  forceViewDocId?: string | null
  forceCollectDocId?: string | null
  forceReceiptPaymentId?: string | null
  onViewDocument: (documentId: string) => void
  onOpenActivity: () => void
  onForceViewHandled: () => void
  onForceCollectHandled: () => void
  onForceReceiptHandled: () => void
}

function PhaseBlock({
  icon,
  title,
  help,
  children,
  id,
  optionalLabel,
  subtle = false,
}: {
  icon: ReactNode
  title: string
  help: string
  children: ReactNode
  id?: string
  optionalLabel?: string
  subtle?: boolean
}) {
  return (
    <section
      id={id}
      tabIndex={id ? -1 : undefined}
      className={`scroll-mt-36 rounded-xl border border-border p-4 sm:p-5 ${
        subtle ? 'bg-muted/20' : 'bg-card'
      }`}
    >
      <div className="mb-4 flex items-start gap-3">
        <span className="mt-0.5 rounded-lg bg-muted p-2 text-muted-foreground">
          {icon}
        </span>
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <h3 className="font-semibold text-foreground">{title}</h3>
            {optionalLabel && (
              <Badge variant="secondary">{optionalLabel}</Badge>
            )}
          </div>
          <p className="text-sm text-muted-foreground">{help}</p>
        </div>
      </div>
      {children}
    </section>
  )
}

export function DeliverPhaseView({
  projectId,
  clientId,
  siteId,
  hasLines,
  visitClosed,
  workLocked,
  publishedAt,
  openReportByDefault = false,
  complete,
  latestDeliveryId,
  pendingAmendment,
  serviceMode = null,
  forceViewDocId,
  forceCollectDocId,
  forceReceiptPaymentId,
  onViewDocument,
  onOpenActivity,
  onForceViewHandled,
  onForceCollectHandled,
  onForceReceiptHandled,
}: DeliverPhaseViewProps) {
  const { t } = useTranslation(['field-service', 'projects'])
  const queryClient = useQueryClient()
  const canApproveAmendment = usePermission('commercial.pricing.edit')
  const [signAmendmentId, setSignAmendmentId] = useState<string | null>(null)
  const [activeView, setActiveView] = useState<'commercial' | 'report'>(
    openReportByDefault ? 'report' : 'commercial',
  )

  return (
    <div className="space-y-4">
      {pendingAmendment && (
        <PhaseBlock
          icon={<AlertTriangle className="h-5 w-5" />}
          title={t(
            'field-service:deliver.deviations_title',
            'Desviacions i ampliacions',
          )}
          help={t(
            'field-service:deliver.deviations_help',
            'Hi ha una ampliació pendent d’aprovació abans de continuar.',
          )}
        >
          <div className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-amber-300 bg-amber-50 px-3 py-2 dark:border-amber-800 dark:bg-amber-950/30">
            <div>
              <p className="text-sm font-medium">
                {t('projects:projects.commercial.type_amendment', 'Ampliació')}{' '}
                {pendingAmendment.doc_number ?? '—'}
              </p>
              <CommercialDocumentStatusBadges
                doc={pendingAmendment}
                t={(key, fallback) => t(`projects:${key}`, fallback)}
                className="mt-1"
              />
              {!canApproveAmendment && (
                <p className="mt-1 text-xs text-muted-foreground">
                  {t(
                    'field-service:deliver.deviations_office_only',
                    'L’oficina ha d’aprovar abans de cobrar.',
                  )}
                </p>
              )}
            </div>
            <div className="flex flex-wrap gap-2">
              <Button
                type="button"
                size="sm"
                variant="outline"
                onClick={() => onViewDocument(pendingAmendment.id)}
              >
                {t('projects:projects.commercial.view', 'Veure')}
              </Button>
              {canApproveAmendment && (
                <Button
                  type="button"
                  size="sm"
                  onClick={() => setSignAmendmentId(pendingAmendment.id)}
                >
                  {t(
                    'field-service:deliver.review_accept',
                    'Revisar / Acceptar',
                  )}
                </Button>
              )}
            </div>
          </div>
        </PhaseBlock>
      )}

      <div
        role="group"
        aria-label={t(
          'field-service:deliver.view_selector_aria',
          'Contingut d’Entregar',
        )}
        className="grid grid-cols-2 gap-1 rounded-xl bg-muted p-1"
      >
        <Button
          type="button"
          variant={activeView === 'commercial' ? 'default' : 'ghost'}
          className="h-auto min-h-11 whitespace-normal px-2 py-2"
          aria-pressed={activeView === 'commercial'}
          onClick={() => setActiveView('commercial')}
        >
          <ReceiptText className="h-4 w-4 shrink-0" />
          {t('field-service:deliver.delivery_title', 'Albarà i cobrament')}
        </Button>
        <Button
          type="button"
          variant={activeView === 'report' ? 'default' : 'ghost'}
          className="h-auto min-h-11 whitespace-normal px-2 py-2"
          aria-pressed={activeView === 'report'}
          onClick={() => setActiveView('report')}
        >
          <FileCheck2 className="h-4 w-4 shrink-0" />
          <span>
            {t('field-service:deliver.report_selector', 'Part de treball')}
            <span className="ml-1 text-xs opacity-75">
              · {t('field-service:deliver.optional', 'Opcional')}
            </span>
          </span>
        </Button>
      </div>

      {activeView === 'report' ? (
        <PhaseBlock
          id="work-report"
          icon={<FileCheck2 className="h-5 w-5" />}
          title={t(
            'field-service:deliver.report_title',
            'Part de treball (butlletí)',
          )}
          optionalLabel={t('field-service:deliver.optional', 'Opcional')}
          subtle
          help={t(
            'field-service:deliver.report_help',
            'Si l’empresa entrega un part al client, el pot revisar i publicar aquí. No cal publicar-lo per emetre l’albarà ni cobrar.',
          )}
        >
          <ProjectBulletinPanel
            projectId={projectId}
            clientId={clientId}
            siteId={siteId}
            visitClosed={visitClosed}
            workLocked={workLocked}
            publishedAt={publishedAt}
          />
        </PhaseBlock>
      ) : (
        <>
          <PhaseBlock
            icon={<ReceiptText className="h-5 w-5" />}
            title={
              serviceMode === 'assessment'
                ? t(
                    'field-service:deliver.assessment_title',
                    'Pressupost després de l’avaluació',
                  )
                : t('field-service:deliver.delivery_title', 'Albarà i cobrament')
            }
            help={
              serviceMode === 'assessment'
                ? t(
                    'field-service:deliver.assessment_help',
                    'Aquesta visita és d’avaluació: prepara el pressupost a Preparar. L’albarà només aplica quan hi ha pressupost acceptat.',
                  )
                : t(
                    'field-service:deliver.delivery_help',
                    'Consulta l’albarà, registra el cobrament i entrega el comprovant.',
                  )
            }
          >
            <ProjectCommercialPanel
              projectId={projectId}
              hasLines={hasLines}
              section="deliver"
              embedded
              showHeader={false}
              serviceMode={serviceMode}
              forceViewDocId={forceViewDocId}
              forceCollectDocId={forceCollectDocId}
              forceReceiptPaymentId={forceReceiptPaymentId}
              onForceViewHandled={onForceViewHandled}
              onForceCollectHandled={onForceCollectHandled}
              onForceReceiptHandled={onForceReceiptHandled}
            />
          </PhaseBlock>

          {complete && (
            <PhaseBlock
              icon={<FolderCheck className="h-5 w-5" />}
              title={t('projects:projects.commercial.dossier_title', 'Expedient tancat')}
              help={t(
                'projects:projects.commercial.dossier_help',
                'La feina està entregada i cobrada. Pots consultar els documents o l’historial.',
              )}
            >
              <div className="flex flex-wrap gap-2">
                {latestDeliveryId && (
                  <Button
                    type="button"
                    size="sm"
                    variant="outline"
                    onClick={() => onViewDocument(latestDeliveryId)}
                  >
                    {t(
                      'projects:projects.commercial.resend_client',
                      'Reenviar al client',
                    )}
                  </Button>
                )}
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  onClick={onOpenActivity}
                >
                  {t('field-service:deliver.open_history', 'Consultar historial')}
                </Button>
              </div>
            </PhaseBlock>
          )}
        </>
      )}
      {signAmendmentId ? (
        <CommercialNativeSignDialog
          documentId={signAmendmentId}
          action="accept"
          open
          onClose={() => setSignAmendmentId(null)}
          onCompleted={() => {
            void queryClient.invalidateQueries({ queryKey: ['commercial_documents', projectId] })
            void queryClient.invalidateQueries({ queryKey: ['projects'] })
            void queryClient.invalidateQueries({ queryKey: ['project', projectId] })
          }}
        />
      ) : null}
    </div>
  )
}
