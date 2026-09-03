import { useMutation } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'
import type { LoginFormValues } from '../schemas/auth.schema'

/**
 * Mutación para autenticar al usuario con email y contraseña.
 * React Query gestiona el estado de loading/error; el componente
 * solo llama a mutateAsync() y reacciona al resultado.
 */
export function useSignIn() {
  return useMutation({
    mutationFn: async (credentials: LoginFormValues) => {
      const { data, error } = await supabase.auth.signInWithPassword(credentials)
      if (error) throw error
      return data
    },
  })
}
