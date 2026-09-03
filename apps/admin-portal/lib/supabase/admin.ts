import { createClient } from '@supabase/supabase-js'

/**
 * Client de Supabase amb clau secreta (service_role).
 * NOMÉS per a ús server-side (Server Actions, Route Handlers, pàgines server).
 * Mai exposar al client.
 *
 * `db.schema: 'api'` — les RPCs BYOK/admin viuen a `api.*` (PostgREST no exposa `public`).
 */
export function createSupabaseAdminClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY

  if (!url || !key) {
    throw new Error('Falten NEXT_PUBLIC_SUPABASE_URL o SUPABASE_SERVICE_ROLE_KEY')
  }

  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
    db: { schema: 'api' },
  })
}
