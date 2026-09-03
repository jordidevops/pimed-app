import { FileText } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import type { DocumentGeneratorUiBlock } from '@/features/ai-chat/schemas/chartBlock'
import type { OrchestratorSource } from '@/features/signing'
import type { SigningRolesSchema } from '@/features/signing/api/signingService'
import type { RoleAssignment } from '@/features/signing/utils/roleAssignmentUtils'

type Props = {
  block: DocumentGeneratorUiBlock
  consumed?: boolean
  onOpen: (source: OrchestratorSource, entityContext?: { type: string; id: string; label?: string; email?: string }) => void
}

export function ChatDocumentGeneratorBlock({ block, consumed, onOpen }: Props) {
  const { t } = useTranslation('chat')

  function handleOpen() {
    const raw = block.source as Record<string, unknown>
    if (raw.kind !== 'template_locale') return

    const source: OrchestratorSource = {
      kind: 'template_locale',
      localeId: String(raw.localeId),
      localeName: String(raw.localeName ?? block.locale ?? ''),
      variablesSchema: (raw.variablesSchema as Record<string, unknown> | null) ?? null,
      signingRolesSchema: (raw.signingRolesSchema as SigningRolesSchema | null) ?? null,
      templateType: raw.templateType === 'html' ? 'html' : 'docx',
      templateCategory: (raw.templateCategory as string | null) ?? null,
      htmlContent: (raw.htmlContent as string | null) ?? null,
      templateName: block.templateName,
      storagePath: (raw.storagePath as string | null) ?? null,
      templateId: (raw.templateId as string | null) ?? null,
      blockMapping: (raw.blockMapping as Record<string, string> | null) ?? null,
      prefillVariableValues: (raw.prefillVariableValues as Record<string, string> | undefined) ?? undefined,
      prefillRoleAssignments: (raw.prefillRoleAssignments as RoleAssignment[] | undefined) ?? undefined,
      prefillOutputAction: (raw.prefillOutputAction as OrchestratorSource extends { kind: 'template_locale' } ? NonNullable<OrchestratorSource['prefillOutputAction']> : never) ?? undefined,
      documentTitle: block.documentTitle ?? block.templateName,
    }

    const entityContext = raw.entityContext as { type: string; id: string; label?: string; email?: string } | null
    onOpen(source, entityContext ?? undefined)
  }

  return (
    <div className="rounded-xl border border-indigo-200 bg-indigo-50/50 p-4 space-y-3 max-w-md">
      <div className="flex items-start gap-2">
        <FileText className="h-5 w-5 text-indigo-700 shrink-0 mt-0.5" />
        <div className="space-y-1 min-w-0">
          <p className="text-sm font-medium text-indigo-950">
            {t('documentGeneratorTitle', 'Generar document')}
          </p>
          <p className="text-xs text-indigo-900/80">
            {block.templateName}
            {block.locale ? ` · ${block.locale}` : ''}
          </p>
          {block.documentTitle && block.documentTitle !== block.templateName && (
            <p className="text-xs text-indigo-800/70">
              {t('documentGeneratorDocTitle', 'Títol')}: {block.documentTitle}
            </p>
          )}
        </div>
      </div>
      <p className="text-xs text-indigo-900/70">
        {t(
          'documentGeneratorHint',
          'Obre el formulari de l\'app per revisar variables, rols i acció de sortida abans de generar al DMS.',
        )}
      </p>
      <div className="flex justify-end">
        {consumed ? (
          <p className="text-xs text-indigo-800/70">
            {t('documentGeneratorConsumed', 'Document generat des d\'aquest formulari. Demana un document nou a l\'assistent si en vols un altre.')}
          </p>
        ) : (
          <Button type="button" size="sm" onClick={handleOpen}>
            {t('documentGeneratorOpen', 'Obrir generador de documents')}
          </Button>
        )}
      </div>
    </div>
  )
}
