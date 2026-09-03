import { createBrowserClient } from '@supabase/ssr'

/**
 * Supabase client for use in Client Components ('use client').
 * Uses browser cookies managed by @supabase/ssr.
 */
export function createSupabaseClient() {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY!,
  )
}
