type VarDef = {
  type?: string;
  label?: string;
  required?: boolean;
  order?: number;
};

type RoleDef = {
  entity_type?: string;
  label?: string;
  order?: number;
  auto_assign_current_user?: boolean;
};

export type TemplateVariableInfo = {
  key: string;
  label: string;
  type: string;
  required: boolean;
};

export type TemplateRoleInfo = {
  role: string;
  label: string;
  entityType: string;
  autoAssignCurrentUser: boolean;
};

export function parseVariablesSchema(schema: unknown): TemplateVariableInfo[] {
  if (!schema || typeof schema !== "object") return [];
  const entries = Object.entries(schema as Record<string, VarDef>);
  entries.sort(([, a], [, b]) => (a.order ?? 0) - (b.order ?? 0));
  return entries.map(([key, def]) => ({
    key,
    label: def.label ?? key,
    type: def.type ?? "string",
    required: def.required === true,
  }));
}

export function parseSigningRoles(schema: unknown): TemplateRoleInfo[] {
  if (!schema || typeof schema !== "object") return [];
  const entries = Object.entries(schema as Record<string, RoleDef>);
  entries.sort(([, a], [, b]) => (a.order ?? 0) - (b.order ?? 0));
  return entries.map(([role, def]) => ({
    role,
    label: def.label ?? role,
    entityType: def.entity_type ?? "employee",
    autoAssignCurrentUser: def.auto_assign_current_user === true,
  }));
}

export function getMissingRequiredInputs(params: {
  variablesSchema: unknown;
  signingRolesSchema: unknown;
  variableValues?: Record<string, string>;
  roleAssignments?: Array<{ role: string; entityId?: string }>;
  requireOutputAction?: boolean;
  outputAction?: string | null;
}): string[] {
  const missing: string[] = [];
  const values = params.variableValues ?? {};
  const roles = params.roleAssignments ?? [];

  for (const v of parseVariablesSchema(params.variablesSchema)) {
    if (!v.required) continue;
    if (!values[v.key]?.trim()) {
      missing.push(`${v.label} (${v.key})`);
    }
  }

  for (const r of parseSigningRoles(params.signingRolesSchema)) {
    if (r.autoAssignCurrentUser) continue;
    const assigned = roles.find((ra) => ra.role === r.role);
    if (!assigned?.entityId?.trim()) {
      missing.push(`Rol: ${r.label} (${r.role})`);
    }
  }

  if (params.requireOutputAction && !params.outputAction?.trim()) {
    missing.push("Acció de sortida (HTML, DOCX, PDF o firma)");
  }

  return missing;
}

export function enrichTemplateLocaleForAi(
  tpl: Record<string, unknown>,
  options?: { pdfEnabled?: boolean; nativeSignEnabled?: boolean },
): Record<string, unknown> {
  const variables = parseVariablesSchema(tpl.variablesSchema);
  const roles = parseSigningRoles(tpl.signingRolesSchema);
  const mimeType = String(tpl.mimeType ?? "");
  const isHtml = mimeType.includes("html");
  const pdfEnabled = options?.pdfEnabled === true;
  const nativeSignEnabled = options?.nativeSignEnabled === true;

  const availableOutputActions: Array<{ code: string; label: string }> = [];
  if (isHtml) {
    availableOutputActions.push({ code: "generate_html", label: "Generar HTML al DMS" });
  } else {
    availableOutputActions.push({ code: "generate_docx", label: "Generar Word (DOCX) al DMS" });
  }
  if (pdfEnabled) {
    availableOutputActions.push({ code: "generate_pdf", label: "Generar PDF al DMS" });
  }
  availableOutputActions.push({ code: "sign_docuseal", label: "Enviar a signar (DocuSeal)" });
  if (nativeSignEnabled) {
    availableOutputActions.push(
      { code: "sign_native_presential", label: "Firma pròpia (presencial)" },
      { code: "sign_native_remote", label: "Firma pròpia (remota per email)" },
    );
  }

  return {
    ...tpl,
    variables,
    requiredVariables: variables.filter((v) => v.required),
    optionalVariables: variables.filter((v) => !v.required),
    signingRoles: roles,
    availableOutputActions,
    checklistForUser: [
      ...variables.filter((v) => v.required).map((v) => `Variable obligatòria: ${v.label} (${v.key})`),
      ...roles.filter((r) => !r.autoAssignCurrentUser).map((r) => `Assignar rol: ${r.label} (${r.role})`),
      "Preguntar acció de sortida oferint availableOutputActions (usa label, mai els codis interns)",
    ],
  };
}
