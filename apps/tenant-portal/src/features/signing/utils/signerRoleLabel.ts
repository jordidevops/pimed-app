/** Etiquetes de rol per a la UI de firma nativa (alineat amb signing-field-map.ts). */
export const NATIVE_SIGNER_ROLE_LABELS: Record<string, string> = {
  worker:  'Treballador/a',
  manager: 'Responsable',
  client_accept: 'Acceptació',
  client_reject: 'Refús',
  client_delivery: 'Conformitat de lliurament',
}

export function nativeSignerRoleLabel(role: string | null | undefined, name?: string | null): string {
  if (!role?.trim()) return name?.trim() || 'Signant'
  const key = role.trim().toLowerCase()
  return NATIVE_SIGNER_ROLE_LABELS[key] ?? name?.trim() ?? role
}
