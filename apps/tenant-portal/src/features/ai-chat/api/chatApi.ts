import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { Json } from '@/types/database.types'
import { getFunctionErrorMessage, getResponseErrorMessage } from '@/lib/functionErrors'
import type { AiProvider } from '@/features/ai/types/rpc'
import type { AiChatUiBlock } from '@/features/ai-chat/schemas/chartBlock'
import { parseUiBlocksFromPayload } from '@/features/ai-chat/schemas/chartBlock'

const FUNCTIONS_BASE = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1`

export type AiConversationRow = {
  id: string
  title: string | null
  provider: string
  model: string
  updated_at: string
}

export type AiMessageRow = {
  id: string
  conversation_id: string
  sequence: number
  role: string
  content: string | null
  tool_name: string | null
  payload: Record<string, unknown> | null
  created_at: string
}

export type AiChatProposal = {
  id: string
  proposalToken: string
  toolName: string
  status: 'pending' | 'applied' | 'rejected' | 'expired'
  preview: Record<string, unknown>
  expiresAt?: string | null
}

export async function fetchConversations(): Promise<AiConversationRow[]> {
  const { data, error } = await supabase
    .from('ai_conversations')
    .select('id, title, provider, model, updated_at')
    .order('updated_at', { ascending: false })
  if (error) throw new Error(error.message)
  return (data ?? []) as AiConversationRow[]
}

export async function fetchMessages(conversationId: string): Promise<AiMessageRow[]> {
  const { data, error } = await supabase
    .from('ai_conversation_messages')
    .select('id, conversation_id, sequence, role, content, tool_name, payload, created_at')
    .eq('conversation_id', conversationId)
    .order('sequence', { ascending: true })
  if (error) throw new Error(error.message)
  return (data ?? []) as AiMessageRow[]
}

export async function fetchConversationProposals(conversationId: string): Promise<AiChatProposal[]> {
  const { data, error } = await supabase
    .from('ai_action_proposals')
    .select('id, tool_name, proposal_token, payload, status, created_at')
    .eq('conversation_id', conversationId)
    .in('status', ['pending', 'applied'])
    .order('created_at', { ascending: true })
  if (error) throw new Error(error.message)

  return (data ?? []).map((row) => ({
    id: row.id as string,
    proposalToken: row.proposal_token as string,
    toolName: row.tool_name as string,
    status: row.status as AiChatProposal['status'],
    preview: buildPreviewFromPayload(row.tool_name as string, row.payload as Record<string, unknown>),
    expiresAt: null,
  }))
}

function buildPreviewFromPayload(
  toolName: string,
  payload: Record<string, unknown>,
): Record<string, unknown> {
  if (toolName === 'propose_update_employee') {
    return {
      employeeId: payload.employeeId,
      employeeName: payload.employeeName ?? payload.employeeId,
      before: payload.before,
      after: payload.after,
    }
  }
  if (toolName === 'propose_create_contact') {
    return (payload.preview as Record<string, unknown>) ?? {
      displayName: payload.displayName,
      kind: payload.kind,
      email: payload.email,
      phone: payload.phone,
      taxId: payload.taxId,
    }
  }
  if (toolName === 'propose_extract_structured_data') {
    return (payload.preview as Record<string, unknown>) ?? {
      targetType: payload.targetType,
      displayName: (payload.contact as Record<string, unknown> | undefined)?.displayName,
      kind: (payload.contact as Record<string, unknown> | undefined)?.kind,
      email: (payload.contact as Record<string, unknown> | undefined)?.email,
      phone: (payload.contact as Record<string, unknown> | undefined)?.phone,
      taxId: (payload.contact as Record<string, unknown> | undefined)?.taxId,
      confidence: payload.confidence,
      sourceHint: payload.sourceHint,
      uncertainFields: payload.uncertainFields,
    }
  }
  if (toolName === 'propose_generate_document') {
    return (payload.preview as Record<string, unknown>) ?? {
      templateName: payload.templateName,
      templateLocaleId: payload.templateLocaleId,
      documentTitle: payload.documentTitle,
      locale: payload.locale,
      variables: payload.variables,
      roleAssignments: payload.roleAssignments,
    }
  }
  if (toolName === 'propose_price_sheet') {
    return (payload.preview as Record<string, unknown>) ?? {
      projectId: payload.projectId,
      mode: payload.mode,
      lineCount: Array.isArray(payload.lines) ? payload.lines.length : 0,
      lines: payload.lines,
      checklistTemplateId: payload.checklistTemplateId,
    }
  }
  return payload
}

export function parseProposalsFromToolMessage(row: AiMessageRow): AiChatProposal[] {
  if (row.role !== 'tool' || !row.tool_name?.startsWith('propose_') || !row.content) {
    return []
  }
  try {
    const parsed = JSON.parse(row.content) as { proposals?: AiChatProposal[] }
    return (parsed.proposals ?? []).map((p) => ({
      ...p,
      status: p.status ?? 'pending',
    }))
  } catch {
    return []
  }
}

export async function deleteConversation(conversationId: string): Promise<void> {
  const { error } = await supabase.rpc('delete_ai_conversation', {
    p_conversation_id: conversationId,
  })
  if (error) throw new Error(error.message)
}

export type AiConversationShareStatus = {
  enabled: boolean
  share_token: string | null
  share_enabled_at?: string | null
  share_expires_at?: string | null
}

export type AiSharedConversation = {
  conversation: {
    id: string
    title: string | null
    provider: string
    model: string
    owner_user_id: string
    owner_name: string | null
    created_at: string
    updated_at: string
    share_expires_at?: string | null
    read_only: boolean
  }
  messages: AiMessageRow[]
  page?: {
    limit: number
    offset: number
    total: number
    has_more: boolean
    next_offset: number | null
  }
}

export async function fetchConversationShareStatus(
  conversationId: string,
): Promise<AiConversationShareStatus> {
  const { data, error } = await supabase.rpc('get_ai_conversation_share_status', {
    p_conversation_id: conversationId,
  })
  if (error) throw new Error(error.message)
  return data as AiConversationShareStatus
}

export async function enableConversationShare(
  conversationId: string,
  expirySeconds = 7 * 24 * 3600,
): Promise<{ enabled: boolean; share_token: string; share_expires_at?: string | null }> {
  const { data, error } = await supabase.rpc('enable_ai_conversation_share', {
    p_conversation_id: conversationId,
    p_expiry_seconds: expirySeconds,
  })
  if (error) throw new Error(error.message)
  return data as { enabled: boolean; share_token: string; share_expires_at?: string | null }
}

export async function disableConversationShare(
  conversationId: string,
): Promise<{ enabled: boolean }> {
  const { data, error } = await supabase.rpc('disable_ai_conversation_share', {
    p_conversation_id: conversationId,
  })
  if (error) throw new Error(error.message)
  return data as { enabled: boolean }
}

export async function fetchSharedConversation(
  shareToken: string,
  options?: { limit?: number; offset?: number },
): Promise<AiSharedConversation> {
  const { data, error } = await supabase.rpc('get_ai_shared_conversation', {
    p_share_token: shareToken,
    p_limit: options?.limit ?? 100,
    p_offset: options?.offset ?? 0,
  })
  if (error) throw new Error(error.message)
  return data as AiSharedConversation
}

export type SendChatTurnInput = {
  tenantId: string
  conversationId?: string | null
  content?: string
  attachments?: Array<{
    fileId: string
    mimeType: string
    name?: string
  }>
  provider?: string
  model?: string
  stream?: boolean
  regenerate?: boolean
  presetId?: string | null
  siteId?: string | null
  entityContext?: {
    projectId?: string
    clientId?: string
    tab?: string
  } | null
}

export type SendChatTurnResult = {
  conversationId: string
  content: string
  toolTrace?: Array<{ name: string; ok: boolean }>
  proposals?: AiChatProposal[] | null
  uiBlocks?: AiChatUiBlock[] | null
  toolsAvailable?: string[]
  toolsEnabled?: boolean
  warnings?: string[] | null
  autoTitlePending?: boolean
  latencyMs?: number
  regenerated?: boolean
}

export type AiChatPresetRow = {
  id: string
  tenant_id: string
  created_by: string
  name: string
  provider: string
  model: string
  system_prompt_override: string | null
  temperature_override: number | null
  is_tenant_shared: boolean
  created_at: string
  updated_at: string
}

export type ChatStreamHandlers = {
  onToken: (delta: string) => void
  onMeta?: (meta: { conversationId: string; regenerated?: boolean }) => void
  onToolStart?: (name: string) => void
  onToolEnd?: (name: string, ok: boolean) => void
}

function parseSseBlocks(buffer: string): { events: Array<{ event: string; data: string }>; rest: string } {
  const events: Array<{ event: string; data: string }> = []
  const normalized = buffer.replace(/\r\n/g, '\n')
  const parts = normalized.split('\n\n')
  const rest = parts.pop() ?? ''

  for (const block of parts) {
    if (!block.trim()) continue
    let event = 'message'
    let data = ''
    for (const line of block.split('\n')) {
      if (line.startsWith('event:')) event = line.slice(6).trim()
      else if (line.startsWith('data:')) data += line.slice(5).trim()
    }
    if (data) events.push({ event, data })
  }

  return { events, rest }
}

function handleStreamEvents(
  events: Array<{ event: string; data: string }>,
  handlers: ChatStreamHandlers,
): SendChatTurnResult | null {
  let result: SendChatTurnResult | null = null

  for (const chunk of events) {
    const payload = JSON.parse(chunk.data) as Record<string, unknown>
    if (chunk.event === 'meta') {
      const conversationId = payload.conversationId
      if (typeof conversationId === 'string') {
        handlers.onMeta?.({ conversationId })
      }
    } else if (chunk.event === 'token') {
      const delta = payload.delta
      if (typeof delta === 'string' && delta.length > 0) {
        handlers.onToken(delta)
      }
    } else if (chunk.event === 'tool_start') {
      const name = payload.name
      if (typeof name === 'string') handlers.onToolStart?.(name)
    } else if (chunk.event === 'tool_end') {
      const name = payload.name
      const ok = payload.ok
      if (typeof name === 'string') handlers.onToolEnd?.(name, ok === true)
    } else if (chunk.event === 'done') {
      result = payload as unknown as SendChatTurnResult
    } else if (chunk.event === 'error') {
      const message = payload.message
      throw new Error(typeof message === 'string' ? message : 'Error de streaming')
    }
  }

  return result
}

async function readChatTurnStream(
  res: Response,
  handlers: ChatStreamHandlers,
): Promise<SendChatTurnResult> {
  if (!res.body) throw new Error('Resposta buida del servidor')

  const reader = res.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''
  let result: SendChatTurnResult | null = null
  let recoveredConversationId: string | null = null
  let recoveredContent = ''

  const wrappedHandlers: ChatStreamHandlers = {
    ...handlers,
    onMeta: (meta) => {
      recoveredConversationId = meta.conversationId
      handlers.onMeta?.(meta)
    },
    onToken: (delta) => {
      recoveredContent += delta
      handlers.onToken(delta)
    },
  }

  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      buffer += decoder.decode(value, { stream: true })
      const parsed = parseSseBlocks(buffer)
      buffer = parsed.rest

      const chunkResult = handleStreamEvents(parsed.events, wrappedHandlers)
      if (chunkResult) result = chunkResult
    }

    if (buffer.trim()) {
      const parsed = parseSseBlocks(`${buffer}\n\n`)
      const chunkResult = handleStreamEvents(parsed.events, wrappedHandlers)
      if (chunkResult) result = chunkResult
    }
  } catch (err) {
    if (!result && recoveredConversationId && recoveredContent.trim()) {
      return {
        conversationId: recoveredConversationId,
        content: recoveredContent,
      }
    }
    throw err
  } finally {
    reader.releaseLock()
  }

  if (!result) {
    if (recoveredConversationId && recoveredContent.trim()) {
      return {
        conversationId: recoveredConversationId,
        content: recoveredContent,
      }
    }
    throw new Error('El flux s\'ha tancat abans de rebre la resposta final')
  }
  return result
}

export async function sendChatTurn(
  input: SendChatTurnInput,
  streamHandlers?: ChatStreamHandlers,
): Promise<SendChatTurnResult> {
  const useStream = input.stream === true && !!streamHandlers

  if (useStream) {
    const { data: { session } } = await supabase.auth.getSession()
    if (!session) throw new Error('No estàs autenticat')

    const res = await fetch(`${FUNCTIONS_BASE}/ai-chat-turn`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${session.access_token}`,
        'x-tenant-id': input.tenantId,
      },
      body: JSON.stringify({
        conversationId: input.conversationId ?? null,
        content: input.content ?? '',
        attachments: input.attachments?.length ? input.attachments : undefined,
        provider: input.provider,
        model: input.model,
        stream: true,
        regenerate: input.regenerate === true ? true : undefined,
        presetId: input.presetId ?? undefined,
        siteId: input.siteId ?? undefined,
        entityContext: input.entityContext ?? undefined,
      }),
    })

    if (!res.ok) {
      const json = await res.json().catch(() => null) as { error?: string | { code?: string; message?: string }; message?: string } | null
      const nested = typeof json?.error === 'object' ? json.error : null
      throw new Error(
        json?.message
        ?? nested?.message
        ?? (typeof json?.error === 'string' ? json.error : null)
        ?? `HTTP ${res.status}`,
      )
    }

    const contentType = res.headers.get('content-type') ?? ''
    if (!contentType.includes('text/event-stream')) {
      const json = await res.json() as SendChatTurnResult & { error?: { message?: string } }
      if (json && typeof json === 'object' && 'error' in json && json.error) {
        throw new Error(getResponseErrorMessage(json) ?? 'Error del servidor')
      }
      return json
    }

    try {
      return await readChatTurnStream(res, streamHandlers)
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      const isNetworkFailure = /network error|failed to fetch|incomplete|chunked/i.test(message)
      if (isNetworkFailure) {
        throw new Error('La connexió s\'ha interromput abans de tancar el flux. La resposta pot haver-se desat; refresca la conversa.')
      }
      throw err
    }
  }

  const { data, error } = await supabase.functions.invoke('ai-chat-turn', {
    headers: { 'x-tenant-id': input.tenantId },
    body: {
      conversationId: input.conversationId ?? null,
      content: input.content ?? '',
      attachments: input.attachments?.length ? input.attachments : undefined,
      provider: input.provider,
      model: input.model,
      regenerate: input.regenerate === true ? true : undefined,
      presetId: input.presetId ?? undefined,
      siteId: input.siteId ?? undefined,
      entityContext: input.entityContext ?? undefined,
    },
  })

  if (error) {
    const detailed = await getFunctionErrorMessage(error)
    throw new Error(detailed ?? error.message)
  }
  const responseError = getResponseErrorMessage(data)
  if (responseError) throw new Error(responseError)

  return data as SendChatTurnResult
}

export function getMessageUiBlocks(row: AiMessageRow): AiChatUiBlock[] {
  return parseUiBlocksFromPayload(row.payload)
}

export function getMessageLatencyMs(row: AiMessageRow): number | null {
  const ms = row.payload?.latency_ms
  return typeof ms === 'number' && Number.isFinite(ms) && ms >= 0 ? Math.round(ms) : null
}

export function formatMessageLatency(ms: number): string {
  if (ms < 1000) return `${ms} ms`
  return `${(ms / 1000).toFixed(1)} s`
}

export async function appendAssistantChatMessage(
  conversationId: string,
  content: string,
  payload?: Record<string, unknown>,
): Promise<void> {
  const { error } = await supabase.rpc('append_ai_chat_assistant_message', {
    p_conversation_id: conversationId,
    p_content: content,
    p_payload: (payload ?? {}) as Json,
  })
  if (error) throw new Error(error.message)
}

export type ApplyProposalResult = {
  status: string
  appliedAt: string | null
  toolName: string | null
  result: unknown
}

export async function applyChatProposal(
  tenantId: string,
  proposalToken: string,
): Promise<ApplyProposalResult> {
  const { data, error } = await supabase.functions.invoke('ai-chat-apply-proposal', {
    headers: { 'x-tenant-id': tenantId },
    body: { proposalToken },
  })
  if (error) {
    const detailed = await getFunctionErrorMessage(error)
    throw new Error(detailed ?? error.message)
  }
  const responseError = getResponseErrorMessage(data)
  if (responseError) throw new Error(responseError)
  return data as ApplyProposalResult
}

export function useSendChatTurn(tenantId: string | null) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (input: Omit<SendChatTurnInput, 'tenantId'> & { streamHandlers?: ChatStreamHandlers }) => {
      if (!tenantId) throw new Error('No tenant')
      const { streamHandlers, ...rest } = input
      return sendChatTurn(
        { tenantId, ...rest, stream: rest.stream ?? !!streamHandlers },
        streamHandlers,
      )
    },
    onSuccess: async (result) => {
      // Persistència async al edge: el refetch pot arribar abans que l'assistant
      // estigui a la BD. Omplim la cache perquè no desaparegui en navegar.
      if (result.content?.trim()) {
        queryClient.setQueryData<AiMessageRow[]>(
          ['ai_messages', result.conversationId],
          (prev) => {
            const list = prev ?? []
            const trimmed = result.content.trim()
            if (list.some((m) => m.role === 'assistant' && (m.content ?? '').trim() === trimmed)) {
              return list
            }
            const maxSeq = list.reduce((max, row) => Math.max(max, row.sequence ?? 0), 0)
            return [
              ...list,
              {
                id: `local-${result.conversationId}-${Date.now()}`,
                conversation_id: result.conversationId,
                sequence: maxSeq + 1,
                role: 'assistant',
                content: result.content,
                tool_name: null,
                payload: null,
                created_at: new Date().toISOString(),
              },
            ]
          },
        )
      }
      await queryClient.invalidateQueries({ queryKey: ['ai_conversations'] })
      await queryClient.invalidateQueries({ queryKey: ['ai_messages', result.conversationId] })
      await queryClient.invalidateQueries({ queryKey: ['ai_proposals', result.conversationId] })
    },
  })
}

export function useApplyChatProposal(tenantId: string | null, conversationId: string | null) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (proposalToken: string) => {
      if (!tenantId) throw new Error('No tenant')
      return applyChatProposal(tenantId, proposalToken)
    },
    onSuccess: async () => {
      if (conversationId) {
        await queryClient.invalidateQueries({ queryKey: ['ai_proposals', conversationId] })
        await queryClient.invalidateQueries({ queryKey: ['ai_messages', conversationId] })
      }
    },
  })
}

export function useAiConversations(enabled: boolean) {
  return useQuery({
    queryKey: ['ai_conversations'],
    enabled,
    queryFn: fetchConversations,
  })
}

export function useAiMessages(conversationId: string | null) {
  return useQuery({
    queryKey: ['ai_messages', conversationId],
    enabled: !!conversationId,
    queryFn: () => fetchMessages(conversationId!),
    staleTime: 0,
    refetchOnMount: 'always',
  })
}

export function useAiProposals(conversationId: string | null) {
  return useQuery({
    queryKey: ['ai_proposals', conversationId],
    enabled: !!conversationId,
    queryFn: () => fetchConversationProposals(conversationId!),
  })
}

export async function fetchChatPresets(): Promise<AiChatPresetRow[]> {
  const { data, error } = await supabase
    .from('ai_chat_presets')
    .select('id, tenant_id, created_by, name, provider, model, system_prompt_override, temperature_override, is_tenant_shared, created_at, updated_at')
    .order('updated_at', { ascending: false })
  if (error) throw new Error(error.message)
  return (data ?? []) as AiChatPresetRow[]
}

export async function upsertChatPreset(input: {
  id?: string | null
  name: string
  provider: string
  model: string
  systemPromptOverride?: string
  temperatureOverride?: number | null
  isTenantShared?: boolean
}): Promise<string> {
  const { data, error } = await supabase.rpc('upsert_ai_chat_preset', {
    p_id: input.id ?? '',
    p_name: input.name,
    p_provider: input.provider as AiProvider,
    p_model: input.model,
    p_system_prompt_override: input.systemPromptOverride ?? undefined,
    p_temperature_override: input.temperatureOverride ?? undefined,
    p_is_tenant_shared: input.isTenantShared ?? false,
  })
  if (error) throw new Error(error.message)
  return data as string
}

export async function deleteChatPreset(presetId: string): Promise<void> {
  const { error } = await supabase.rpc('delete_ai_chat_preset', { p_id: presetId })
  if (error) throw new Error(error.message)
}

export function useAiChatPresets(enabled: boolean) {
  return useQuery({
    queryKey: ['ai_chat_presets'],
    enabled,
    queryFn: fetchChatPresets,
  })
}
