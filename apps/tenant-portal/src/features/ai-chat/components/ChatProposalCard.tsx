import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Check, FileText, Loader2, X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import type { AiChatProposal } from '../api/chatApi'

type Props = {
  proposal: AiChatProposal
  onApply: (proposalToken: string) => Promise<void>
  onReject?: () => void
  onOpenDocumentGenerator?: () => Promise<void>
  onError?: (message: string) => void
}

function formatPreview(proposal: AiChatProposal): string {
  const preview = proposal.preview ?? {}
  if (proposal.toolName === 'propose_update_employee') {
    const before = preview.before as Record<string, unknown> | undefined
    const after = preview.after as Record<string, unknown> | undefined
    const name = preview.employeeName ?? preview.employeeId
    const lines: string[] = [`Empleat: ${String(name)}`]
    if (before && after) {
      if (before.fullName !== after.fullName) {
        lines.push(`Nom: ${before.fullName} → ${after.fullName}`)
      }
      if (before.jobPositionId !== after.jobPositionId) {
        const from =
          (before.jobPositionName as string | undefined) ??
          String(before.jobPositionId ?? '—')
        const to =
          (after.jobPositionName as string | undefined) ??
          String(after.jobPositionId ?? '—')
        lines.push(`Lloc de treball: ${from} → ${to}`)
      }
      if (before.status !== after.status) {
        lines.push(`Estat: ${before.status} → ${after.status}`)
      }
    }
    return lines.join('\n')
  }
  if (proposal.toolName === 'propose_create_contact') {
    const lines = [
      `Contacte: ${String(preview.displayName ?? '—')}`,
      `Tipus: ${String(preview.kind ?? 'person')}`,
    ]
    if (preview.email) lines.push(`Email: ${String(preview.email)}`)
    if (preview.phone) lines.push(`Telèfon: ${String(preview.phone)}`)
    if (preview.taxId) lines.push(`NIF/CIF: ${String(preview.taxId)}`)
    return lines.join('\n')
  }
  if (proposal.toolName === 'propose_extract_structured_data') {
    const lines = [
      `Contacte extret: ${String(preview.displayName ?? '—')}`,
      `Tipus: ${String(preview.kind ?? 'person')}`,
    ]
    if (preview.sourceHint) lines.push(`Origen: ${String(preview.sourceHint)}`)
    if (preview.confidence) lines.push(`Confiança: ${String(preview.confidence)}`)
    if (preview.email) lines.push(`Email: ${String(preview.email)}`)
    if (preview.phone) lines.push(`Telèfon: ${String(preview.phone)}`)
    if (preview.taxId) lines.push(`NIF/CIF: ${String(preview.taxId)}`)
    const uncertain = preview.uncertainFields as string[] | undefined
    if (uncertain?.length) {
      lines.push(`Revisa: ${uncertain.join(', ')}`)
    }
    return lines.join('\n')
  }
  if (proposal.toolName === 'propose_generate_document') {
    const lines = [
      `Plantilla: ${String(preview.templateName ?? preview.templateLocaleId ?? '—')}`,
      `Locale: ${String(preview.locale ?? '—')}`,
      `Títol: ${String(preview.documentTitle ?? preview.templateName ?? '—')}`,
    ]
    const vars = preview.variables as Record<string, unknown> | undefined
    if (vars && Object.keys(vars).length > 0) {
      lines.push(`Variables: ${Object.keys(vars).join(', ')}`)
    }
    const roles = preview.roleAssignments as Array<Record<string, unknown>> | undefined
    if (roles?.length) {
      lines.push(
        `Rols: ${roles.map((r) => `${r.role}→${r.entityType}`).join(', ')}`,
      )
    }
    return lines.join('\n')
  }
  return JSON.stringify(preview, null, 2)
}

export function ChatProposalCard({ proposal, onApply, onReject, onOpenDocumentGenerator, onError }: Props) {
  const { t } = useTranslation('chat')
  const [applying, setApplying] = useState(false)
  const [localStatus, setLocalStatus] = useState(proposal.status)
  const [errorMessage, setErrorMessage] = useState<string | null>(null)

  const isDocumentProposal = proposal.toolName === 'propose_generate_document'
  const isPending = localStatus === 'pending'
  const isApplied = localStatus === 'applied'

  async function handleApply() {
    if (!isPending || applying) return
    setApplying(true)
    setErrorMessage(null)
    try {
      if (isDocumentProposal && onOpenDocumentGenerator) {
        await onOpenDocumentGenerator()
        setLocalStatus('applied')
        return
      }
      await onApply(proposal.proposalToken)
      setLocalStatus('applied')
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      setErrorMessage(message)
      onError?.(message)
    } finally {
      setApplying(false)
    }
  }

  return (
    <div className="rounded-xl border border-amber-200 bg-amber-50/60 p-4 space-y-3 max-w-md">
      <div className="flex items-center justify-between gap-2">
        <p className="text-sm font-medium text-amber-950">
          {isDocumentProposal
            ? t('documentProposalTitle', 'Document preparat')
            : t('proposalTitle', 'Acció pendent de confirmació')}
        </p>
        {isApplied ? (
          <Badge className="bg-emerald-600 hover:bg-emerald-600">
            {isDocumentProposal
              ? t('documentProposalOpened', 'Obert')
              : t('proposalApplied', 'Aplicada')}
          </Badge>
        ) : (
          <Badge variant="outline" className="border-amber-400 text-amber-900">
            {t('proposalPending', 'Pendent')}
          </Badge>
        )}
      </div>
      <pre className="text-xs whitespace-pre-wrap text-amber-950/90 font-sans">
        {formatPreview(proposal)}
      </pre>
      {errorMessage && (
        <p className="text-xs text-destructive font-medium" role="alert">
          {errorMessage}
        </p>
      )}
      {isPending && (
        <div className="flex gap-2 justify-end">
          {onReject && (
            <Button type="button" variant="ghost" size="sm" onClick={onReject}>
              <X className="h-4 w-4 mr-1" />
              {t('proposalDismiss', 'Descartar')}
            </Button>
          )}
          <Button type="button" size="sm" disabled={applying} onClick={() => void handleApply()}>
            {applying ? (
              <Loader2 className="h-4 w-4 mr-1 animate-spin" />
            ) : isDocumentProposal ? (
              <FileText className="h-4 w-4 mr-1" />
            ) : (
              <Check className="h-4 w-4 mr-1" />
            )}
            {isDocumentProposal
              ? t('documentProposalOpen', 'Obrir generador de documents')
              : t('proposalApply', 'Confirmar i aplicar')}
          </Button>
        </div>
      )}
      {isApplied && !isDocumentProposal && (
        <p className="text-xs text-emerald-800">{t('proposalAppliedHint', 'Canvis aplicats correctament.')}</p>
      )}
      {isApplied && isDocumentProposal && (
        <p className="text-xs text-emerald-800">
          {t('documentProposalOpenedHint', 'Completa el formulari i prem «Generar document al DMS».')}
        </p>
      )}
    </div>
  )
}
