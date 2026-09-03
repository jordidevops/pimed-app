import { useMutation } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'

/**
 * Mutación para cerrar la sesión del usuario actual.
 */
export function useSignOut() {
  return useMutation({
    mutationFn: () => supabase.auth.signOut().then(({ error }) => {
      if (error) throw error
    }),
  })
}
