import type { QueryClient } from '@tanstack/react-query'

/** Config de gestors (settings/ai). */
export function aiConfigQueryKey(tenantId: string) {
  return ['ai_config', tenantId] as const
}

/** Accés efectiu de l'usuari (xat, skills, generació). */
export function aiUserAccessQueryKey(tenantId: string) {
  return ['ai_user_access', tenantId] as const
}

/** Invalida config i accés IA després d'activar/canviar claus o proveïdor. */
export async function invalidateAiTenantQueries(
  queryClient: QueryClient,
  tenantId: string | null | undefined,
): Promise<void> {
  if (!tenantId) return
  await Promise.all([
    queryClient.invalidateQueries({ queryKey: aiConfigQueryKey(tenantId) }),
    queryClient.invalidateQueries({ queryKey: aiUserAccessQueryKey(tenantId) }),
  ])
}
