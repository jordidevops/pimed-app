import type { SigningRolesSchema, VariablesSchema } from '../../api/signingService'

export interface CopyFromLocaleResult {
  htmlContent: string
  variablesSchema: VariablesSchema | null
  rolesSchema: SigningRolesSchema
}

/** Duplica roles, variables i contingut d'un locale origen (punt de partida per traduir). */
export function copyLocaleData(
  source: {
    html_content?: string | null
    variables_schema?: unknown
    signing_roles_schema?: unknown
  },
): CopyFromLocaleResult {
  return {
    htmlContent: source.html_content ?? '',
    variablesSchema: source.variables_schema
      ? structuredClone(source.variables_schema as VariablesSchema)
      : null,
    rolesSchema: source.signing_roles_schema
      ? structuredClone(source.signing_roles_schema as SigningRolesSchema)
      : {},
  }
}
