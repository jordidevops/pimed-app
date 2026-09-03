export type DocumentProposalPayload = {
  templateLocaleId: string;
  documentTitle?: string;
  variables?: Record<string, unknown>;
  roleAssignments?: Array<{
    role: string;
    entityType: string;
    entityId: string;
  }>;
};

export function buildContextRefs(
  roleAssignments?: DocumentProposalPayload["roleAssignments"],
): Record<string, { entity_type: string; entity_id: string }> | undefined {
  if (!roleAssignments?.length) return undefined;

  const refs: Record<string, { entity_type: string; entity_id: string }> = {};
  for (const assignment of roleAssignments) {
    refs[assignment.role] = {
      entity_type: assignment.entityType,
      entity_id: assignment.entityId,
    };
  }
  return refs;
}

export async function invokeGenerateDocumentFromProposal(
  req: Request,
  tenantId: string,
  payload: DocumentProposalPayload,
): Promise<Record<string, unknown>> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    throw new Error("Authorization header required");
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")?.replace(/\/$/, "");
  if (!supabaseUrl) {
    throw new Error("SUPABASE_URL not configured");
  }

  const contextRefs = buildContextRefs(payload.roleAssignments);
  const manualVariables = payload.variables ?? {};
  const body: Record<string, unknown> = {
    tenant_id: tenantId,
    action: "generate_only",
    source_type: "template_locale",
    source_template_locale_id: payload.templateLocaleId,
    document_title: payload.documentTitle,
  };

  if (Object.keys(manualVariables).length > 0) {
    body.context = { input: manualVariables };
  }
  if (contextRefs) {
    body.context_refs = contextRefs;
  }

  const response = await fetch(`${supabaseUrl}/functions/v1/sign-document-router`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: authHeader,
      "x-tenant-id": tenantId,
    },
    body: JSON.stringify(body),
  });

  const json = await response.json().catch(() => ({})) as Record<string, unknown>;
  if (!response.ok) {
    const nested = json.error as Record<string, unknown> | undefined;
    const message = typeof nested?.message === "string"
      ? nested.message
      : typeof json.error === "string"
      ? json.error
      : typeof json.message === "string"
      ? json.message
      : `Document generation failed (${response.status})`;
    throw new Error(message);
  }

  return json;
}
