import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'
import { emailKeys } from './emailKeys'
import type { EmailTemplate, EmailTemplateUpdate, TemplateTranslations } from '../types'
import type { Database, Json } from '../../../types/database.types'

type EmailTemplateInsert = Database['api']['Views']['email_templates']['Insert']
type EmailTemplatePatch = Database['api']['Views']['email_templates']['Update']

export interface EmailTemplateCreate {
  name: string
  slug: string | null
  event_type: string | null
  subject_template: string
  html_body_template: string | null
  text_body_template: string | null
  variables_schema: Record<string, unknown> | null
  is_layout: boolean
  layout_id: string | null
  use_layout: boolean
  is_draft: boolean
  translations: TemplateTranslations
}

export function useEmailTemplateMutations(tenantId: string) {
  const qc = useQueryClient()

  const invalidate = () => {
    qc.invalidateQueries({ queryKey: emailKeys.templates(tenantId) })
    qc.invalidateQueries({ queryKey: emailKeys.layouts(tenantId) })
  }

  /**
   * Copy-on-Write: clona una plantilla de plataforma assignant el tenant.
   * La nova plantilla es crea com a publicada (is_draft=false) per defecte,
   * així l'override és efectiu de seguida. L'usuari pot canviar a esborrany.
   */
  const cloneFromPlatform = useMutation({
    mutationFn: async (source: EmailTemplate): Promise<EmailTemplate> => {
      const payload: EmailTemplateInsert = {
        tenant_id: tenantId,
        name: source.name,
        slug: source.slug,
        event_type: source.event_type,
        subject_template: source.subject_template,
        html_body_template: source.html_body_template,
        text_body_template: source.text_body_template,
        variables_schema: (source.variables_schema ?? null) as Json | null,
        is_layout: source.is_layout,
        layout_id: source.layout_id,
        use_layout: source.use_layout,
        is_platform_default: false,
        is_active: true,
        is_draft: false,
        translations: (source.translations ?? {}) as Json,
      }

      const { data, error } = await supabase
        .from('email_templates')
        .insert(payload)
        .select()
        .single()

      if (error) throw error
      return data as EmailTemplate
    },
    onSuccess: invalidate,
  })

  /** Actualitza camps d'una plantilla pròpia del tenant. */
  const updateTemplate = useMutation({
    mutationFn: async ({
      id,
      updates,
    }: {
      id: string
      updates: EmailTemplateUpdate
    }): Promise<EmailTemplate> => {
      const patch: EmailTemplatePatch = {
        ...updates,
        variables_schema: updates.variables_schema as Json | null | undefined,
        translations: updates.translations as Json | null | undefined,
      }

      const { data, error } = await supabase
        .from('email_templates')
        .update(patch)
        .eq('id', id)
        .select()
        .single()

      if (error) throw error
      return data as EmailTemplate
    },
    onSuccess: invalidate,
  })

  /**
   * Restaurar valors per defecte: elimina la plantilla pròpia del tenant
   * perquè el sistema torni a usar el fallback de plataforma.
   */
  const deleteTemplate = useMutation({
    mutationFn: async (id: string): Promise<void> => {
      const { error } = await supabase
        .from('email_templates')
        .delete()
        .eq('id', id)

      if (error) throw error
    },
    onSuccess: invalidate,
  })

  /**
   * Crea una plantilla nova pròpia del tenant (Clone-on-Save).
   * Usat quan l'usuari guarda per primera vegada una plantilla de plataforma.
   */
  const createTemplate = useMutation({
    mutationFn: async (payload: EmailTemplateCreate): Promise<EmailTemplate> => {
      const insertPayload: EmailTemplateInsert = {
        ...payload,
        variables_schema: (payload.variables_schema ?? null) as Json | null,
        translations: (payload.translations ?? {}) as Json,
        tenant_id: tenantId,
        is_platform_default: false,
        is_active: true,
      }

      const { data, error } = await supabase
        .from('email_templates')
        .insert(insertPayload)
        .select()
        .single()

      if (error) throw error
      return data as EmailTemplate
    },
    onSuccess: invalidate,
  })

  return { cloneFromPlatform, createTemplate, updateTemplate, deleteTemplate }
}
