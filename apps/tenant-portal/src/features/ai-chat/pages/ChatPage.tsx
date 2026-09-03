import { useEffect, useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useLocation } from 'react-router-dom'
import { Share2, Sparkles } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { useToast } from '@/hooks/use-toast'
import { Button } from '@/components/ui/button'
import { fetchAiUserAccess } from '@/features/ai/api/aiRpc'
import { aiUserAccessQueryKey } from '@/features/ai/api/aiQueryKeys'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import {
  appendAssistantChatMessage,
  deleteConversation,
  deleteChatPreset,
  upsertChatPreset,
  useAiChatPresets,
  useAiConversations,
  useAiMessages,
  useAiProposals,
  useApplyChatProposal,
  useSendChatTurn,
} from '@/features/ai-chat/api/chatApi'
import { ChatSidebar } from '@/features/ai-chat/components/ChatSidebar'
import { ChatThread } from '@/features/ai-chat/components/ChatThread'
import { ChatComposer } from '@/features/ai-chat/components/ChatComposer'
import { ChatShareDialog } from '@/features/ai-chat/components/ChatShareDialog'
import { ChatModelSelector } from '@/features/ai-chat/components/ChatModelSelector'
import { ChatPresetSelector } from '@/features/ai-chat/components/ChatPresetSelector'
import { ChatToolTrace, type ChatToolTraceEntry } from '@/features/ai-chat/components/ChatToolTrace'
import { DocumentOrchestrator, type DocumentGenerationNotify, type OrchestratorSource } from '@/features/signing'
import { fetchPdfConverterConfig } from '@/features/signing/api/usePdfConverterConfig'
import { buildOrchestratorSourceFromProposalPreview } from '@/features/ai-chat/utils/documentGeneratorSource'
import { parseUiBlock, parseUiBlocks } from '@/features/ai-chat/schemas/chartBlock'
import { useAiModelCapabilities } from '@/features/ai-chat/hooks/useAiModelCapabilities'
import { useChatModelSelection } from '@/features/ai-chat/hooks/useChatModelSelection'
import type { ChatAttachmentRef } from '@/features/ai-chat/utils/chatAttachments'
import {
  CHAT_ATTACHMENTS_MAX,
  revokeAttachmentPreviews,
  uploadChatAttachment,
  validateChatAttachmentFile,
} from '@/features/ai-chat/utils/chatAttachments'
import { buildPendingUserMessage, type PendingUserMessage } from '@/features/ai-chat/utils/pendingUserMessage'
import { createStreamDisplay } from '@/features/ai-chat/utils/streamDisplay'
import { formatBytes } from '@/features/storage/utils/fileUtils'
import { loadChatSession, loadConsumedGenerators, markConsumedGenerator, saveChatSession } from '@/features/ai-chat/utils/chatSessionState'
import type { DocumentResultUiBlock } from '@/features/ai-chat/schemas/chartBlock'
import { useStorageUsage } from '@/features/storage/api/useStorageUsage'

export function ChatPage() {
  const location = useLocation()
  const { t } = useTranslation('chat')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const { activeTenant, activeRole } = useTenant()
  const tenantId = activeTenant?.id ?? null

  const [activeConversationId, setActiveConversationId] = useState<string | null>(null)
  const [draft, setDraft] = useState('')
  const [attachments, setAttachments] = useState<ChatAttachmentRef[]>([])
  const [attaching, setAttaching] = useState(false)
  const [lastToolTrace, setLastToolTrace] = useState<ChatToolTraceEntry[]>([])
  const [streamingContent, setStreamingContent] = useState<string | null>(null)
  const [pendingUser, setPendingUser] = useState<PendingUserMessage | null>(null)
  const [selectedPresetId, setSelectedPresetId] = useState<string | null>(null)
  const [regenerating, setRegenerating] = useState(false)
  const [shareOpen, setShareOpen] = useState(false)
  const [pendingAssistantCommit, setPendingAssistantCommit] = useState<{
    conversationId: string
    content: string
  } | null>(null)
  const [pendingUiBlocks, setPendingUiBlocks] = useState<ReturnType<typeof parseUiBlocks> | null>(null)
  const [orchestratorSource, setOrchestratorSource] = useState<OrchestratorSource | null>(null)
  const [orchestratorEntityContext, setOrchestratorEntityContext] = useState<{
    type: string
    id: string
    label?: string
    email?: string
  } | undefined>(undefined)
  const [consumedGeneratorKeys, setConsumedGeneratorKeys] = useState<Set<string>>(() => new Set())
  const [activeGeneratorBlockKey, setActiveGeneratorBlockKey] = useState<string | null>(null)
  const [ephemeralDocumentResult, setEphemeralDocumentResult] = useState<DocumentResultUiBlock | null>(null)
  const sessionRestoredRef = useRef(false)
  const locationDraftAppliedRef = useRef(false)
  const activeConversationIdRef = useRef<string | null>(null)

  const canManageSharedPresets = activeRole === 'owner' || activeRole === 'manager'

  const sendingRef = useRef(false)
  const streamDisplayRef = useRef(createStreamDisplay((text) => setStreamingContent(text)))

  const { data: access, isLoading: accessLoading } = useQuery({
    queryKey: aiUserAccessQueryKey(tenantId!),
    enabled: !!tenantId,
    queryFn: () => fetchAiUserAccess(tenantId!),
  })
  const canChat = !!access?.configured && !access?.blocked
  const { data: storageUsage } = useStorageUsage(tenantId ?? undefined)

  const { data: conversations = [], isLoading: convLoading } = useAiConversations(!!tenantId && canChat)
  const { data: messages = [], isLoading: msgLoading } = useAiMessages(activeConversationId)
  const { data: proposals = [] } = useAiProposals(activeConversationId)
  const { data: presets = [], isLoading: presetsLoading } = useAiChatPresets(!!tenantId && canChat)
  const sendMutation = useSendChatTurn(tenantId)
  const applyMutation = useApplyChatProposal(tenantId, activeConversationId)

  const modelSelection = useChatModelSelection(tenantId, activeConversationId, conversations)
  const { getCapabilities, isLoading: capsLoading } = useAiModelCapabilities(tenantId)

  const currentCapabilities = useMemo(
    () => getCapabilities(modelSelection.provider, modelSelection.model),
    [getCapabilities, modelSelection.provider, modelSelection.model],
  )
  const quotaUi = useMemo(() => {
    const usedBytes = Math.max(0, Number(storageUsage?.total_bytes ?? 0))
    // El tenant portal no té accés a api.tenant_entitlements; només avisem si l'upload falla per quota.
    const capBytes = 0
    const blocked = false
    const blockedReason = ''
    const hasCap = capBytes > 0
    const ratio = hasCap ? usedBytes / capBytes : 0
    const percent = hasCap ? Math.min(999, Math.round(ratio * 100)) : 0

    if (blocked) {
      return {
        attachBlocked: true,
        attachBlockedReason: t(
          'quotaBlocked',
          "L'emmagatzematge està bloquejat. Contacta amb l'administrador del tenant.",
        ),
        notice: {
          level: 'error' as const,
          message: blockedReason
            ? t('quotaBlockedWithReason', "Emmagatzematge bloquejat: {{reason}}", { reason: blockedReason })
            : t('quotaBlocked', "L'emmagatzematge està bloquejat. Contacta amb l'administrador del tenant."),
        },
      }
    }

    if (hasCap && ratio >= 1) {
      return {
        attachBlocked: true,
        attachBlockedReason: t(
          'quotaExceededAttachDisabled',
          "Has superat la quota d'emmagatzematge. Allibera espai a Emmagatzematge.",
        ),
        notice: {
          level: 'error' as const,
          message: t(
            'quotaExceeded',
            "Quota d'emmagatzematge esgotada: {{used}} / {{limit}} ({{percent}}%). Allibera espai a Emmagatzematge.",
            { used: formatBytes(usedBytes), limit: formatBytes(capBytes), percent },
          ),
        },
      }
    }

    if (hasCap && ratio >= 0.85) {
      return {
        attachBlocked: false,
        attachBlockedReason: null,
        notice: {
          level: 'warning' as const,
          message: t(
            'quotaWarning',
            "Estàs a prop del límit d'emmagatzematge: {{used}} / {{limit}} ({{percent}}%).",
            { used: formatBytes(usedBytes), limit: formatBytes(capBytes), percent },
          ),
        },
      }
    }

    return {
      attachBlocked: false,
      attachBlockedReason: null,
      notice: null,
    }
  }, [storageUsage, t])

  useEffect(() => {
    activeConversationIdRef.current = activeConversationId
    if (activeConversationId) {
      setConsumedGeneratorKeys(loadConsumedGenerators(activeConversationId))
    } else {
      setConsumedGeneratorKeys(new Set())
    }
  }, [activeConversationId])

  useEffect(() => {
    sessionRestoredRef.current = false
  }, [tenantId])

  useEffect(() => {
    if (!tenantId || sessionRestoredRef.current || convLoading) return
    const saved = loadChatSession(tenantId)
    if (saved?.draft) setDraft(saved.draft)
    if (saved?.conversationId && conversations.some((c) => c.id === saved.conversationId)) {
      setActiveConversationId(saved.conversationId)
    }
    sessionRestoredRef.current = true
  }, [tenantId, convLoading, conversations])

  useEffect(() => {
    if (locationDraftAppliedRef.current) return
    const incoming = (location.state as { draft?: string } | null)?.draft
    if (typeof incoming === 'string' && incoming.trim()) {
      setDraft(incoming.trim())
      locationDraftAppliedRef.current = true
    }
  }, [location.state])

  useEffect(() => {
    if (!tenantId) return
    saveChatSession(tenantId, { conversationId: activeConversationId })
  }, [tenantId, activeConversationId])

  useEffect(() => {
    if (!tenantId) return
    const timer = window.setTimeout(() => {
      saveChatSession(tenantId, { draft })
    }, 250)
    return () => window.clearTimeout(timer)
  }, [tenantId, draft])

  useEffect(() => {
    if (!activeConversationId) {
      setSelectedPresetId(null)
    }
  }, [activeConversationId])

  useEffect(() => {
    if (!selectedPresetId || activeConversationId) return
    const preset = presets.find((p) => p.id === selectedPresetId)
    if (!preset) return
    modelSelection.setProvider(preset.provider as typeof modelSelection.provider)
    modelSelection.setModel(preset.model)
  }, [selectedPresetId, presets, activeConversationId])

  async function runChatTurn(input: {
    conversationId?: string | null
    content?: string
    attachments?: Array<{ fileId: string; mimeType: string; name?: string }>
    regenerate?: boolean
    presetId?: string | null
  }) {
    streamDisplayRef.current.reset()
    setStreamingContent('')
    setPendingUiBlocks(null)
    setEphemeralDocumentResult(null)

    const result = await sendMutation.mutateAsync({
      conversationId: input.conversationId ?? activeConversationId,
      content: input.content,
      attachments: input.attachments,
      provider: modelSelection.provider,
      model: modelSelection.model,
      presetId: input.presetId,
      regenerate: input.regenerate,
      stream: true,
      streamHandlers: {
        onMeta: ({ conversationId, regenerated }) => {
          setActiveConversationId((current) => current ?? conversationId)
          if (regenerated) {
            void queryClient.invalidateQueries({ queryKey: ['ai_messages', conversationId] })
            void queryClient.invalidateQueries({ queryKey: ['ai_proposals', conversationId] })
          }
        },
        onToken: (delta) => {
          streamDisplayRef.current.push(delta)
        },
      },
    })

    streamDisplayRef.current.flush()
    setActiveConversationId(result.conversationId)
    setStreamingContent(result.content ?? '')
    setPendingUiBlocks(result.uiBlocks?.length ? parseUiBlocks(result.uiBlocks) : null)
    setPendingAssistantCommit({
      conversationId: result.conversationId,
      content: result.content ?? '',
    })
    streamDisplayRef.current.reset({ silent: true })
    setLastToolTrace(result.toolTrace ?? [])

    if (result.warnings?.length) {
      toast({ variant: 'default', description: result.warnings.join(' ') })
    }
    if (result.proposals?.length) {
      toast({ description: t('proposalCreated', 'Hi ha una acció pendent de la teva confirmació.') })
    }
    if (result.uiBlocks?.some((b) => parseUiBlock(b)?.type === 'document_generator')) {
      toast({ description: t('documentGeneratorReady', 'Fes clic a «Obrir generador de documents» a sota.') })
    }
    if (result.autoTitlePending) {
      window.setTimeout(() => {
        void queryClient.invalidateQueries({ queryKey: ['ai_conversations'] })
      }, 2500)
    }

    return result
  }

  useEffect(() => {
    return () => {
      revokeAttachmentPreviews(attachments)
    }
  }, [attachments])

  useEffect(() => {
    if (!pendingAssistantCommit) return
    if (activeConversationId !== pendingAssistantCommit.conversationId) return

    const committed = messages.some(
      (m) => m.role === 'assistant' && (m.content ?? '').trim() === pendingAssistantCommit.content.trim(),
    )

    if (committed) {
      setStreamingContent(null)
      setPendingUiBlocks(null)
      setPendingAssistantCommit(null)
      streamDisplayRef.current.reset({ silent: true })
    }
  }, [messages, activeConversationId, pendingAssistantCommit])

  async function handleAttach(file: File) {
    if (!tenantId || attaching) return

    if (attachments.length >= CHAT_ATTACHMENTS_MAX) {
      toast({
        variant: 'destructive',
        description: t('attachmentsLimit', 'Màxim {{max}} adjunts per missatge', { max: CHAT_ATTACHMENTS_MAX }),
      })
      return
    }

    if (quotaUi.attachBlocked) {
      toast({
        variant: 'destructive',
        description: quotaUi.attachBlockedReason ?? t('quotaExceededAttachDisabled'),
      })
      return
    }

    if (!currentCapabilities.vision) {
      toast({
        variant: 'destructive',
        description: t(
          'visionNotSupported',
          'Aquest model no suporta adjunts multimodals. Tria un model amb visió.',
        ),
      })
      return
    }

    const attachmentLimits = {
      maxImageBytes: currentCapabilities.maxImageSizeMb * 1024 * 1024,
      maxFileBytes: currentCapabilities.maxFileSizeMb * 1024 * 1024,
      allowedImageMimes: currentCapabilities.supportedImageMimes,
      allowedFileMimes: currentCapabilities.supportedFileMimes,
    }
    const validationError = validateChatAttachmentFile(file, attachmentLimits)
    if (validationError) {
      toast({ variant: 'destructive', description: validationError })
      return
    }

    setAttaching(true)
    try {
      const uploaded = await uploadChatAttachment(tenantId, file, attachmentLimits)
      setAttachments((prev) => [...prev, uploaded])
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('errorAttach', 'No s\'ha pogut pujar la imatge'),
      })
    } finally {
      setAttaching(false)
    }
  }

  function handleRemoveAttachment(fileId: string) {
    setAttachments((prev) => {
      const removed = prev.find((a) => a.fileId === fileId)
      if (removed) revokeAttachmentPreviews([removed])
      return prev.filter((a) => a.fileId !== fileId)
    })
  }

  async function handleSend() {
    const text = draft.trim()
    if ((!text && attachments.length === 0) || !tenantId || sendMutation.isPending || attaching || sendingRef.current) {
      return
    }

    sendingRef.current = true

    const outgoingAttachments = attachments.map((a) => ({
      fileId: a.fileId,
      mimeType: a.mimeType,
      name: a.name,
    }))

    setDraft('')
    setPendingUser(buildPendingUserMessage(text, attachments))

    try {
      await runChatTurn({
        conversationId: activeConversationId,
        content: text,
        attachments: outgoingAttachments.length ? outgoingAttachments : undefined,
        presetId: !activeConversationId ? selectedPresetId : undefined,
      })

      revokeAttachmentPreviews(attachments)
      setAttachments([])
      setPendingUser(null)
      setSelectedPresetId(null)
    } catch (err) {
      setPendingUser(null)
      setPendingAssistantCommit(null)
      setPendingUiBlocks(null)
      streamDisplayRef.current.reset({ silent: true })
      setStreamingContent(null)
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('errorSend', 'No s\'ha pogut enviar el missatge'),
      })
    } finally {
      sendingRef.current = false
    }
  }

  async function handleRegenerate() {
    if (!activeConversationId || !tenantId || sendMutation.isPending || sendingRef.current) return

    sendingRef.current = true
    setRegenerating(true)

    try {
      await runChatTurn({ conversationId: activeConversationId, regenerate: true })
    } catch (err) {
      setPendingAssistantCommit(null)
      streamDisplayRef.current.reset({ silent: true })
      setStreamingContent(null)
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('errorRegenerate', 'No s\'ha pogut regenerar la resposta'),
      })
    } finally {
      setRegenerating(false)
      sendingRef.current = false
    }
  }

  async function handleSavePreset(input: {
    id?: string | null
    name: string
    provider: import('@/features/ai/types/rpc').AiProvider
    model: string
    systemPromptOverride?: string
    temperatureOverride?: number | null
    isTenantShared?: boolean
  }) {
    await upsertChatPreset({
      id: input.id,
      name: input.name,
      provider: input.provider,
      model: input.model,
      systemPromptOverride: input.systemPromptOverride,
      temperatureOverride: input.temperatureOverride,
      isTenantShared: input.isTenantShared,
    })
    await queryClient.invalidateQueries({ queryKey: ['ai_chat_presets'] })
    toast({ description: t('presetSaved', 'Preset desat') })
  }

  async function handleDeletePreset(presetId: string) {
    await deleteChatPreset(presetId)
    await queryClient.invalidateQueries({ queryKey: ['ai_chat_presets'] })
    toast({ description: t('presetDeleted', 'Preset eliminat') })
  }

  async function handleOpenDocumentGenerator(
    source: OrchestratorSource,
    entityContext?: { type: string; id: string; label?: string; email?: string },
    blockKey?: string,
  ) {
    setActiveGeneratorBlockKey(blockKey ?? null)
    void queryClient.prefetchQuery({
      queryKey: ['pdf_converter_config'],
      queryFn: fetchPdfConverterConfig,
    })
    setOrchestratorEntityContext(entityContext)
    setOrchestratorSource(source)
  }

  async function handleDocumentGenerationComplete(result: DocumentGenerationNotify) {
    const conversationId = activeConversationIdRef.current
    const blockKey = activeGeneratorBlockKey

    const uiBlock = {
      type: 'document_result' as const,
      success: result.success,
      ...(result.documentId ? { documentId: result.documentId } : {}),
      ...(result.documentTitle ? { documentTitle: result.documentTitle } : {}),
      ...(result.outputFormat ? { outputFormat: result.outputFormat } : {}),
      ...(result.templateName ? { templateName: result.templateName } : {}),
      ...(result.error ? { error: result.error } : {}),
    }

    const content = result.success
      ? t(
          'documentResultAssistantMessage',
          'Document generat correctament{{title}}.',
          { title: result.documentTitle ? `: ${result.documentTitle}` : '' },
        )
      : t(
          'documentResultAssistantError',
          'No s\'ha pogut generar el document{{detail}}.',
          { detail: result.error ? `: ${result.error}` : '' },
        )

    setEphemeralDocumentResult(uiBlock)
    setOrchestratorSource(null)
    setOrchestratorEntityContext(undefined)
    setActiveGeneratorBlockKey(null)

    if (result.success && conversationId && blockKey) {
      markConsumedGenerator(conversationId, blockKey)
      setConsumedGeneratorKeys((prev) => new Set(prev).add(blockKey))
    }

    if (!conversationId) return

    try {
      await appendAssistantChatMessage(conversationId, content, { ui_blocks: [uiBlock] })
      await queryClient.invalidateQueries({ queryKey: ['ai_messages', conversationId] })
      setEphemeralDocumentResult(null)
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : String(err),
      })
    }
  }

  function handleOrchestratorClose() {
    setOrchestratorSource(null)
    setOrchestratorEntityContext(undefined)
    setActiveGeneratorBlockKey(null)
  }

  async function handleOpenDocumentFromProposal(proposal: import('@/features/ai-chat/api/chatApi').AiChatProposal) {
    const source = await buildOrchestratorSourceFromProposalPreview(proposal.preview ?? {})
    if (!source) {
      throw new Error(t('documentGeneratorLoadError', 'No s\'ha pogut carregar la plantilla. Torna a demanar el document a l\'assistent.'))
    }
    await handleOpenDocumentGenerator(source)
  }

  function handleProposalError(message: string) {
    toast({ variant: 'destructive', description: message })
  }

  async function handleDelete(conversationId: string) {
    try {
      await deleteConversation(conversationId)
      await queryClient.invalidateQueries({ queryKey: ['ai_conversations'] })
      if (activeConversationId === conversationId) {
        setActiveConversationId(null)
        setLastToolTrace([])
        setPendingUser(null)
      }
      toast({ description: t('deleted', 'Conversa eliminada') })
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : String(err),
      })
    }
  }

  if (accessLoading) {
    return <div className="p-6 text-muted-foreground">…</div>
  }

  if (!canChat) {
    return (
      <div className="p-6 max-w-lg">
        <h1 className="text-2xl font-semibold flex items-center gap-2 mb-2">
          <Sparkles className="h-6 w-6" />
          {t('title', 'Assistent IA')}
        </h1>
        <p className="text-muted-foreground">
          {!access?.configured
            ? t('notConfigured', 'La IA no està configurada per a aquest tenant. Configura-la a Configuració → IA.')
            : t('noAccess', 'No tens accés a la IA. Contacta amb l\'administrador del tenant.')}
        </p>
      </div>
    )
  }

  return (
    <div className="flex h-[calc(100vh-4rem)] border-t">
      <ChatSidebar
        conversations={conversations}
        activeConversationId={activeConversationId}
        loading={convLoading}
        onSelect={setActiveConversationId}
        onDelete={(id) => void handleDelete(id)}
      />

      <main className="flex-1 flex flex-col min-w-0">
        <header className="border-b px-4 py-3 flex items-center justify-between gap-2">
          <div className="flex items-center gap-2 min-w-0">
            <Sparkles className="h-5 w-5 text-indigo-600 shrink-0" />
            <h1 className="font-semibold truncate">{t('title', 'Assistent IA')}</h1>
          </div>
          <div className="flex items-center gap-2 shrink-0">
            {activeConversationId && (
              <Button
                type="button"
                variant="outline"
                size="sm"
                className="gap-1.5"
                onClick={() => setShareOpen(true)}
                disabled={sendMutation.isPending}
              >
                <Share2 className="h-4 w-4" />
                {t('share', 'Compartir')}
              </Button>
            )}
            <ChatPresetSelector
              presets={presets}
              selectedPresetId={selectedPresetId}
              disabled={sendMutation.isPending}
              locked={modelSelection.locked}
              isLoading={presetsLoading}
              canManageShared={canManageSharedPresets}
              provider={modelSelection.provider}
              model={modelSelection.model}
              onSelect={setSelectedPresetId}
              onSave={handleSavePreset}
              onDelete={handleDeletePreset}
            />
            <ChatModelSelector
            provider={modelSelection.provider}
            model={modelSelection.model}
            modelOptions={modelSelection.modelOptions}
            suggestedModels={modelSelection.suggestedModels}
            capabilities={currentCapabilities}
            locked={modelSelection.locked}
            disabled={sendMutation.isPending}
            isLoading={modelSelection.isLoading || capsLoading}
            configuredProviders={modelSelection.configuredProviders}
            defaultProvider={modelSelection.defaultProvider}
            getProviderStatus={modelSelection.getProviderStatus}
            onProviderChange={modelSelection.setProvider}
            onModelChange={modelSelection.setModel}
          />
          </div>
        </header>

        <ChatThread
          messages={messages}
          loading={msgLoading && !!activeConversationId}
          thinking={sendMutation.isPending}
          streamingContent={streamingContent}
          pendingUser={pendingUser}
          hideLastAssistant={regenerating}
          canRegenerate={!!activeConversationId && messages.some((m) => m.role === 'assistant')}
          onRegenerate={() => void handleRegenerate()}
          proposals={proposals}
          onApplyProposal={async (token) => {
            try {
              const res = await applyMutation.mutateAsync(token)
              if (res.status === 'already_applied') {
                toast({ description: t('proposalAlreadyApplied', 'Ja s\'ha aplicat aquesta proposta.') })
              } else {
                toast({ description: t('proposalApplied', 'Acció aplicada') })
              }
            } catch (err) {
              const message = err instanceof Error ? err.message : String(err)
              handleProposalError(message)
              throw err
            }
          }}
          onOpenDocumentFromProposal={handleOpenDocumentFromProposal}
          onProposalError={handleProposalError}
          onOpenDocumentGenerator={(source, entityContext, blockKey) => void handleOpenDocumentGenerator(source, entityContext, blockKey)}
          consumedGeneratorKeys={consumedGeneratorKeys}
          ephemeralDocumentResult={ephemeralDocumentResult}
          pendingUiBlocks={pendingUiBlocks}
        />

        <ChatToolTrace trace={lastToolTrace} />

        {activeConversationId && (
          <ChatShareDialog
            open={shareOpen}
            onOpenChange={setShareOpen}
            conversationId={activeConversationId}
            conversationTitle={conversations.find((c) => c.id === activeConversationId)?.title}
          />
        )}

        <ChatComposer
          value={draft}
          onChange={setDraft}
          onSend={() => void handleSend()}
          attachments={attachments}
          onAttach={(file) => void handleAttach(file)}
          onRemoveAttachment={handleRemoveAttachment}
          attachDisabled={!currentCapabilities.vision || quotaUi.attachBlocked}
          attachDisabledReason={
            quotaUi.attachBlocked
              ? quotaUi.attachBlockedReason ?? undefined
              : !currentCapabilities.vision
                ? t('visionNotSupported', 'Aquest model no suporta adjunts multimodals. Tria un model amb visió.')
                : undefined
          }
          quotaNotice={quotaUi.notice}
          attaching={attaching}
          sending={sendMutation.isPending}
        />
      </main>

      {orchestratorSource && (
        <DocumentOrchestrator
          open
          onClose={handleOrchestratorClose}
          onGenerationComplete={(result) => void handleDocumentGenerationComplete(result)}
          initialSource={orchestratorSource}
          entityContext={orchestratorEntityContext}
        />
      )}
    </div>
  )
}
