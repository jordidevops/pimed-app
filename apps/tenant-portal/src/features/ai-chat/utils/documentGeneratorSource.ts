import { supabase } from '@/lib/supabase'
import type { OrchestratorSource } from '@/features/signing'
import type { SigningRolesSchema } from '@/features/signing/api/signingService'
import type { RoleAssignment } from '@/features/signing/utils/roleAssignmentUtils'

type TemplateLocaleRow = {
  id: string
  locale: string | null
  mime_type: string | null
  storage_path: string | null
  html_content: string | null
  variables_schema: unknown
  signing_roles_schema: unknown
  template_id: string
  document_templates: {
    id: string
    name: string
    category: string | null
    default_block_mapping: unknown
    template_type: string | null
  } | null
}

export async function buildOrchestratorSourceFromLocaleId(
  templateLocaleId: string,
  prefill?: {
    documentTitle?: string
    variables?: Record<string, unknown>
    roleAssignments?: Array<{ role: string; entityType: string; entityId?: string; name?: string; email?: string }>
    outputAction?: string
  },
): Promise<OrchestratorSource | null> {
  const { data: loc, error } = await supabase
    .from('document_template_locales')
    .select(`
      id, locale, mime_type, storage_path, html_content,
      variables_schema, signing_roles_schema, template_id,
      document_templates ( id, name, category, default_block_mapping, template_type )
    `)
    .eq('id', templateLocaleId)
    .maybeSingle()

  if (error || !loc) return null

  const row = loc as unknown as TemplateLocaleRow
  const tpl = row.document_templates
  const mimeType = row.mime_type ?? ''
  const isHtml = mimeType.includes('html')

  const variableValues: Record<string, string> = {}
  if (prefill?.variables) {
    for (const [k, v] of Object.entries(prefill.variables)) {
      if (v != null && String(v).trim()) variableValues[k] = String(v)
    }
  }

  const prefillRoleAssignments: RoleAssignment[] = (prefill?.roleAssignments ?? []).map((ra) => ({
    roleName: ra.role,
    entity_type: ra.entityType,
    entity_id: ra.entityId,
    name: ra.name ?? '',
    email: ra.email ?? '',
    inputMode: ra.entityId ? 'entity' : 'manual',
  }))

  return {
    kind: 'template_locale',
    localeId: row.id,
    localeName: row.locale ?? '',
    variablesSchema: (row.variables_schema as Record<string, unknown> | null) ?? null,
    signingRolesSchema: (row.signing_roles_schema as SigningRolesSchema | null) ?? null,
    templateType: isHtml ? 'html' : 'docx',
    templateCategory: tpl?.category ?? null,
    htmlContent: isHtml ? row.html_content : null,
    templateName: tpl?.name ?? null,
    storagePath: !isHtml ? row.storage_path : null,
    templateId: tpl?.id ?? row.template_id,
    blockMapping: (tpl?.default_block_mapping as Record<string, string> | null) ?? null,
    documentTitle: prefill?.documentTitle ?? tpl?.name ?? 'Document',
    prefillVariableValues: Object.keys(variableValues).length ? variableValues : undefined,
    prefillRoleAssignments: prefillRoleAssignments.length ? prefillRoleAssignments : undefined,
    prefillOutputAction: prefill?.outputAction as OrchestratorSource extends { kind: 'template_locale' }
      ? OrchestratorSource['prefillOutputAction']
      : undefined,
  }
}

export async function buildOrchestratorSourceFromProposalPreview(
  preview: Record<string, unknown>,
): Promise<OrchestratorSource | null> {
  const templateLocaleId = String(preview.templateLocaleId ?? '')
  if (!templateLocaleId) return null

  const roleAssignments = preview.roleAssignments as Array<{
    role: string
    entityType: string
    entityId?: string
    name?: string
    email?: string
  }> | undefined

  return buildOrchestratorSourceFromLocaleId(templateLocaleId, {
    documentTitle: preview.documentTitle as string | undefined,
    variables: preview.variables as Record<string, unknown> | undefined,
    roleAssignments,
  })
}
