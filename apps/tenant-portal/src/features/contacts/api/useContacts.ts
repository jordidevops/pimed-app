import { useQuery } from '@tanstack/react-query'
import { getContacts, type Contact } from './contactsService'
import { useTenant } from '@/contexts/TenantContext'

export const contactsKeys = {
  all:  (tenantId: string) => ['contacts', tenantId] as const,
  list: (tenantId: string) => [...contactsKeys.all(tenantId), 'list'] as const,
}

export function useContacts() {
  const { activeTenant } = useTenant()
  return useQuery<Contact[]>({
    queryKey: contactsKeys.list(activeTenant?.id ?? ''),
    queryFn:  () => getContacts(),
    enabled:  !!activeTenant,
  })
}
