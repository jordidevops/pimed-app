import { createClient } from '@supabase/supabase-js'
import type { Database } from '../types/database.types'

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL as string
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_PUBLISHABLE_DEFAULT_KEY as string

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error(
    'Faltan variables de entorno VITE_SUPABASE_URL o VITE_SUPABASE_PUBLISHABLE_DEFAULT_KEY. ' +
      'Copia .env.example a .env.local y rellena los valores.',
  )
}

/**
 * Client Supabase únic per a tota l'aplicació.
 * `db.schema: 'api'` fa que totes les crides .from() usin el schema `api`
 * (envia `Accept-Profile: api` automàticament) en lloc del `public` per defecte.
 */
export const supabase = createClient<Database, 'api'>(supabaseUrl, supabaseAnonKey, {
  db: { schema: 'api' },
})

/**
 * Injecta (o elimina) el header `x-tenant-id` al client Supabase globalment.
 * PostgREST el transmet a PostgreSQL, on `data.active_tenant_id()` el llegeix
 * per aplicar el filtre de tenant a totes les RLS policies i RPCs que l'usen.
 *
 * ⚠️ `@supabase/postgrest-js` emmagatzema headers com a instàncies de `Headers`
 * (Fetch API). Cal usar `.set()` i `.delete()`, NO assignació directa de propietat.
 */
export function setActiveTenantId(id: string | null): void {
  const restHeaders = (supabase as any).rest?.headers as Headers | undefined
  if (!restHeaders || typeof restHeaders.set !== 'function') return

  if (id) restHeaders.set('x-tenant-id', id)
  else restHeaders.delete('x-tenant-id')
}
