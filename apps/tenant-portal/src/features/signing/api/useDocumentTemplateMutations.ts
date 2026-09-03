import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { signingKeys } from './signingKeys'
import { uploadTemplateLocaleFile, type VariablesSchema, type SigningRolesSchema } from './signingService'
import type { DocumentTemplate, DocumentTemplateLocale } from './signingService'
import type { Json } from '@/types/database.types'

// ─── Clone platform template → tenant template ───────────────────────────────

export function useCloneTemplateMutation(tenantId: string) {
  const qc = useQueryClient()
  return useMutation<{ template: DocumentTemplate; copiedLocales: number }, Error, DocumentTemplate>({
    mutationFn: async (source) => {
      const { data, error } = await supabase.rpc('create_document_template', {
        p_tenant_id:      tenantId,
        p_name:           source.name ?? '',
        p_description:    source.description ?? undefined,
        p_category:       source.category ?? undefined,
        p_cloned_from_id: source.id ?? undefined,
        p_template_type:  source.template_type ?? 'docx',
        p_target_archetypes: source.target_archetypes ?? undefined,
        p_target_verticals:  source.target_verticals ?? undefined,
      })
      if (error) throw error
      const newTemplate = (typeof data === 'string' ? JSON.parse(data) : data) as DocumentTemplate

      // Usa document_template_locale_detail per obtenir html_content
      const { data: sourceLocales } = await supabase
        .from('document_template_locale_detail')
        .select('locale, storage_path, variables_schema, signing_roles_schema, sample_values, is_active, mime_type, html_content')
        .eq('template_id', source.id!)

      let copiedLocales = 0
      if (sourceLocales?.length) {
        for (const loc of sourceLocales) {
          const { error: insErr } = await supabase.rpc('upsert_document_template_locale', {
            p_template_id:          newTemplate.id!,
            p_locale:               loc.locale ?? '',
            p_mime_type:            loc.mime_type ?? 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
            p_storage_path:         loc.storage_path ?? undefined,
            p_html_content:         loc.html_content ?? undefined,
            p_variables_schema:     (loc.variables_schema ?? {}) as unknown as Json,
            p_signing_roles_schema: (loc.signing_roles_schema ?? {}) as unknown as Json,
            p_sample_values:        (loc.sample_values ?? null) as unknown as Json,
            p_is_active:            loc.is_active ?? true,
          })
          if (!insErr) copiedLocales++
        }
      }

      return { template: newTemplate, copiedLocales }
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: signingKeys.templates(tenantId) })
      qc.invalidateQueries({ queryKey: signingKeys.localesBatch(tenantId) })
    },
  })
}

// ─── Create new tenant template ───────────────────────────────────────────────

export interface CreateTemplateInput {
  name:               string
  description:        string | null
  category:           string | null
  templateType:       'docx' | 'html'
  targetArchetypes?:  string[] | null
  targetVerticals?:   string[] | null
}

export function useCreateTemplateMutation(tenantId: string) {
  const qc = useQueryClient()
  return useMutation<DocumentTemplate, Error, CreateTemplateInput>({
    mutationFn: async (input) => {
      const { data, error } = await supabase.rpc('create_document_template', {
        p_tenant_id:           tenantId,
        p_name:                input.name,
        p_description:         input.description ?? undefined,
        p_category:            input.category ?? undefined,
        p_template_type:       input.templateType,
        p_target_archetypes:   input.targetArchetypes ?? undefined,
        p_target_verticals:    input.targetVerticals ?? undefined,
      })
      if (error) throw error
      return (typeof data === 'string' ? JSON.parse(data) : data) as DocumentTemplate
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: signingKeys.templates(tenantId) }),
  })
}

// ─── Add / upsert a locale to a template ──────────────────────────────────────

export interface UpsertLocaleInput {
  tenantId:              string
  templateId:            string
  locale:                string
  file?:                 File
  htmlContent?:          string
  existingStoragePath?:  string          // DOCX: manté storage_path existent si no hi ha nou fitxer
  variablesSchema:       VariablesSchema | null
  signingRolesSchema?:   SigningRolesSchema | null
  sampleValues:          Record<string, string> | null
  existingId?:           string
}

export function useUpsertLocaleMutation(tenantId: string) {
  const qc = useQueryClient()
  return useMutation<DocumentTemplateLocale, Error, UpsertLocaleInput>({
    mutationFn: async (input) => {
      if (!input.file && !input.htmlContent && !input.existingStoragePath) {
        throw new Error('file, htmlContent o existingStoragePath és obligatori per a un locale nou')
      }

      // Branca HTML: usa RPC api.upsert_document_template_locale
      if (input.htmlContent !== undefined) {
        const { data, error } = await supabase.rpc('upsert_document_template_locale', {
          p_template_id:          input.templateId,
          p_locale:               input.locale,
          p_mime_type:            'text/html',
          p_html_content:         input.htmlContent,
          p_variables_schema:     (input.variablesSchema ?? {}) as unknown as Json,
          p_signing_roles_schema: (input.signingRolesSchema ?? {}) as unknown as Json,
          p_sample_values:        (input.sampleValues ?? null) as unknown as Json,
          p_is_active:            true,
        })
        if (error) throw new Error(error.message)
        return (typeof data === 'string' ? JSON.parse(data) : data) as DocumentTemplateLocale
      }

      // Branca DOCX: puja nou fitxer o reutilitza storage_path existent
      const storagePath = input.file
        ? await uploadTemplateLocaleFile(input.tenantId, input.templateId, input.locale, input.file)
        : input.existingStoragePath!

      const mimeType = input.file
        ? (input.file.type || 'application/vnd.openxmlformats-officedocument.wordprocessingml.document')
        : 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'

      const { data, error } = await supabase.rpc('upsert_document_template_locale', {
        p_template_id:          input.templateId,
        p_locale:               input.locale,
        p_mime_type:            mimeType,
        p_storage_path:         storagePath,
        p_variables_schema:     (input.variablesSchema ?? {}) as unknown as Json,
        p_signing_roles_schema: (input.signingRolesSchema ?? {}) as unknown as Json,
        p_sample_values:        (input.sampleValues ?? null) as unknown as Json,
        p_is_active:            true,
      })
      if (error) throw new Error(error.message)
      return (typeof data === 'string' ? JSON.parse(data) : data) as DocumentTemplateLocale
    },
    onSuccess: (_, vars) => {
      qc.invalidateQueries({ queryKey: signingKeys.locales(vars.templateId) })
      qc.invalidateQueries({ queryKey: signingKeys.templates(tenantId) })
      qc.invalidateQueries({ queryKey: signingKeys.localesBatch(tenantId) })
    },
  })
}

// ─── Delete template locale ───────────────────────────────────────────────────

export function useDeleteLocaleMutation(tenantId: string, templateId: string) {
  const qc = useQueryClient()
  return useMutation<void, Error, string>({
    mutationFn: async (localeId) => {
      const { error } = await supabase
        .from('document_template_locales')
        .delete()
        .eq('id', localeId)
      if (error) throw new Error(error.message)
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: signingKeys.locales(templateId) })
      qc.invalidateQueries({ queryKey: signingKeys.templates(tenantId) })
      qc.invalidateQueries({ queryKey: signingKeys.localesBatch(tenantId) })
    },
  })
}

// ─── Delete tenant template ───────────────────────────────────────────────────

export function useDeleteTemplateMutation(tenantId: string) {
  const qc = useQueryClient()
  return useMutation<void, Error, string>({
    mutationFn: async (templateId) => {
      const { error } = await supabase
        .from('document_templates')
        .delete()
        .eq('id', templateId)
      if (error) throw new Error(error.message)
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: signingKeys.templates(tenantId) }),
  })
}
