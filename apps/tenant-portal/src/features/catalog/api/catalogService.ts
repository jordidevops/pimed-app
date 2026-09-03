import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'

export type CatalogItem = Database['api']['Views']['catalog_items']['Row']

// ─── Read ─────────────────────────────────────────────────────────────────────

export async function getCatalogItems(): Promise<CatalogItem[]> {
  const { data, error } = await supabase
    .from('catalog_items')
    .select('*')
    .eq('is_active', true)
    .order('name', { ascending: true })

  if (error) throw error
  return data ?? []
}

// ─── Create ───────────────────────────────────────────────────────────────────

export interface CreateCatalogItemParams {
  p_kind: 'service' | 'product'
  p_name: string
  p_description?: string
  p_sku?: string
  p_unit?: string
  p_unit_price: number
  p_tax_rate: number
  p_category?: string
}

export async function createCatalogItem(params: CreateCatalogItemParams): Promise<string> {
  const { data, error } = await supabase.rpc('create_catalog_item', params)
  if (error) throw error
  return data as string
}

// ─── Update ───────────────────────────────────────────────────────────────────

export interface UpdateCatalogItemParams {
  kind: 'service' | 'product'
  name: string
  description?: string | null
  sku?: string | null
  unit?: string | null
  unit_price?: number
  tax_rate?: number
  category?: string | null
}

export async function updateCatalogItem(
  id: string,
  params: UpdateCatalogItemParams,
): Promise<void> {
  const { error } = await supabase.rpc('update_catalog_item', {
    p_id:          id,
    p_kind:        params.kind,
    p_name:        params.name,
    p_description: params.description ?? undefined,
    p_sku:         params.sku ?? undefined,
    p_unit:        params.unit ?? undefined,
    p_unit_price:  params.unit_price ?? 0,
    p_tax_rate:    params.tax_rate ?? 21,
    p_category:    params.category ?? undefined,
  })
  if (error) throw error
}

// ─── Deactivate ───────────────────────────────────────────────────────────────

export async function deactivateCatalogItem(id: string): Promise<void> {
  const { error } = await supabase.rpc('deactivate_catalog_item', { p_id: id })
  if (error) throw error
}
