import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'

export interface AuthSettings {
  google_oauth_enabled: boolean
  password_login_enabled: boolean
  magic_link_enabled: boolean
}

const AUTH_SETTINGS_DEFAULTS: AuthSettings = {
  google_oauth_enabled: true,
  password_login_enabled: true,
  magic_link_enabled: false,
}

export function useAuthSettings() {
  return useQuery({
    queryKey: ['auth-settings'],
    queryFn: async (): Promise<AuthSettings> => {
      const { data, error } = await supabase.rpc('get_auth_settings')
      if (error) throw error
      // Merge with defaults so missing keys never cause undefined access
      return { ...AUTH_SETTINGS_DEFAULTS, ...(data as Partial<AuthSettings>) }
    },
    // Cache aggressively — these settings change rarely and are read on every page load
    staleTime: 5 * 60 * 1000,
    gcTime: 15 * 60 * 1000,
    // No placeholderData: data is undefined while loading so LoginForm shows a spinner
    // instead of flashing providers that may need to be hidden.
  })
}
