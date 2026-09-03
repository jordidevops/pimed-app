import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { signingKeys } from './signingKeys'
import type { BlockType, BlockFormat, ContentBlock } from './useContentBlocks'

// ─── Create ──────────────────────────────────────────────────────────────────

interface CreateBlockInput {
  tenantId:  string
  name:      string
  blockType: BlockType
  format:    BlockFormat
  content:   string
}

export function useCreateContentBlockMutation(tenantId: string) {
  const qc = useQueryClient()
  return useMutation<ContentBlock, Error, CreateBlockInput>({
    mutationFn: async (input) => {
      const { data, error } = await supabase.rpc('create_content_block', {
        p_tenant_id:  input.tenantId,
        p_name:       input.name,
        p_block_type: input.blockType,
        p_format:     input.format,
        p_content:    input.content,
      })
      if (error) throw error
      return (typeof data === 'string' ? JSON.parse(data) : data) as ContentBlock
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: signingKeys.contentBlocks(tenantId) })
    },
  })
}

// ─── Update ──────────────────────────────────────────────────────────────────

interface UpdateBlockInput {
  blockId:  string
  tenantId: string
  name?:    string
  content?: string
  format?:  BlockFormat
  isActive?: boolean
}

export function useUpdateContentBlockMutation(tenantId: string) {
  const qc = useQueryClient()
  return useMutation<ContentBlock, Error, UpdateBlockInput>({
    mutationFn: async (input) => {
      const { data, error } = await supabase.rpc('update_content_block', {
        p_block_id:  input.blockId,
        p_tenant_id: input.tenantId,
        p_name:      input.name,
        p_content:   input.content,
        p_format:    input.format,
        p_is_active: input.isActive,
      })
      if (error) throw error
      return (typeof data === 'string' ? JSON.parse(data) : data) as ContentBlock
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: signingKeys.contentBlocks(tenantId) })
    },
  })
}

// ─── Delete ──────────────────────────────────────────────────────────────────

interface DeleteBlockInput {
  blockId:  string
  tenantId: string
}

export function useDeleteContentBlockMutation(tenantId: string) {
  const qc = useQueryClient()
  return useMutation<void, Error, DeleteBlockInput>({
    mutationFn: async (input) => {
      const { error } = await supabase.rpc('delete_content_block', {
        p_block_id:  input.blockId,
        p_tenant_id: input.tenantId,
      })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: signingKeys.contentBlocks(tenantId) })
    },
  })
}

// ─── Clone platform block → tenant block ─────────────────────────────────────

interface CloneBlockInput {
  sourceBlockId: string
  tenantId:      string
  newName?:      string
}

export function useCloneContentBlockMutation(tenantId: string) {
  const qc = useQueryClient()
  return useMutation<ContentBlock, Error, CloneBlockInput>({
    mutationFn: async (input) => {
      const { data, error } = await supabase.rpc('clone_content_block', {
        p_source_block_id: input.sourceBlockId,
        p_tenant_id:       input.tenantId,
        p_name:            input.newName,
      })
      if (error) throw error
      return (typeof data === 'string' ? JSON.parse(data) : data) as ContentBlock
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: signingKeys.contentBlocks(tenantId) })
    },
  })
}

// ─── Update template block mapping ───────────────────────────────────────────

interface UpdateMappingInput {
  templateId:   string
  tenantId:     string
  blockMapping: Record<string, string>
}

export function useUpdateTemplateMappingMutation(tenantId: string) {
  const qc = useQueryClient()
  return useMutation<void, Error, UpdateMappingInput>({
    mutationFn: async (input) => {
      const { error } = await supabase.rpc('update_template_block_mapping', {
        p_template_id:   input.templateId,
        p_tenant_id:     input.tenantId,
        p_block_mapping: input.blockMapping as unknown as never,
      })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: signingKeys.templates(tenantId) })
    },
  })
}
