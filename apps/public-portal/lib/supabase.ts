import { createClient } from '@supabase/supabase-js'
import type { Database } from '@/types/database.types'

/**
 * Client de Supabase per al portal públic (anon key, schema api).
 * Funciona tant en Server Components com en Client Components.
 * No requereix autenticació: totes les operacions del portal
 * s'executen com a usuari anònim via RLS i SECURITY DEFINER RPCs.
 */
export function createPortalClient() {
  return createClient<Database, 'api'>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY!,
    { db: { schema: 'api' } },
  )
}
