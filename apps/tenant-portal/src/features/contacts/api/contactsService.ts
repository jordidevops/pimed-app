import { supabase } from '@/lib/supabase'
import type { Database, Json } from '@/types/database.types'
import {
  parseGeoCoordinates,
  formatAddressLine,
  googleMapsUrlFromGeo,
  type GeoCoordinates,
  type GeoProvider,
  type GeoSource,
  type StructuredAddress,
} from '@/lib/geo/geoCoordinates'

export type Contact = Database['api']['Views']['contacts']['Row']

// `database.types.ts` is stale for `contact_sites` — it is missing the
// street/street_number/province/geo_coordinates columns added in
// supabase/migrations/20261144000001_maps_geo_coordinates_core.sql and exposed
// via 20261148000001_maps_expose_sites_contact_sites_columns.sql. Extend the
// generated Row type locally rather than regenerating database.types.ts.
export type ContactSite = Database['api']['Views']['contact_sites']['Row'] & {
  street: string | null
  street_number: string | null
  province: string | null
  geo_coordinates: Json | null
}

export async function getContacts(opts?: { limit?: number }): Promise<Contact[]> {
  let query = supabase
    .from('contacts')
    .select('*')
    .eq('is_archived', false)
    .order('display_name', { ascending: true })
    .limit(opts?.limit ?? 200)

  const { data, error } = await query

  if (error) throw error
  return data ?? []
}

export async function getContact(contactId: string): Promise<Contact | null> {
  const { data, error } = await supabase
    .from('contacts')
    .select('*')
    .eq('id', contactId)
    .maybeSingle()

  if (error) throw error
  return data
}

export async function setContactPreferredLocale(
  contactId: string,
  locale: string | null,
): Promise<void> {
  const { error } = await supabase.rpc('set_contact_preferred_locale', {
    p_contact_id: contactId,
    p_locale: locale,
  })
  if (error) throw error
}

export async function getContactSites(contactId: string): Promise<ContactSite[]> {
  const { data, error } = await supabase
    .from('contact_sites')
    .select('*')
    .eq('contact_id', contactId)
    .eq('is_active', true)

  if (error) throw error
  return (data ?? []) as ContactSite[]
}

/** Active sites for the current tenant (list UX: counts + first address). */
export async function getActiveContactSitesForTenant(): Promise<ContactSite[]> {
  const { data, error } = await supabase
    .from('contact_sites')
    .select('*')
    .eq('is_active', true)
    .order('created_at', { ascending: true })

  if (error) throw error
  return (data ?? []) as ContactSite[]
}

/** Structured address + geo parsed from a contact_site row (see geoCoordinates.ts). */
export function contactSiteGeo(site: ContactSite): {
  point: { lat: number; lng: number } | null
  address: StructuredAddress
  provider: GeoProvider | null
  source: GeoSource | null
} {
  return parseGeoCoordinates(site.geo_coordinates)
}

export function formatContactSiteAddress(site: Pick<
  ContactSite,
  'address' | 'city' | 'postal_code' | 'name' | 'street' | 'street_number' | 'province' | 'geo_coordinates'
>): string {
  const geo = parseGeoCoordinates(site.geo_coordinates)
  if (geo.point || geo.address.street || geo.address.city) {
    const line = formatAddressLine(geo.address)
    if (line) return line
  }

  return (
    [site.street ?? undefined, site.street_number ?? undefined]
      .filter(Boolean)
      .join(' ')
      .trim() ||
    [site.address, site.city, site.postal_code].filter(Boolean).join(', ') ||
    (site.name ?? '')
  )
}

export function googleMapsUrlForSite(site: Pick<
  ContactSite,
  'address' | 'city' | 'postal_code' | 'name' | 'street' | 'street_number' | 'province' | 'geo_coordinates'
>): string | null {
  const geo = parseGeoCoordinates(site.geo_coordinates)
  const fromGeo = googleMapsUrlFromGeo(geo.point ? { ...geo.point, ...geo.address } : null)
  if (fromGeo) return fromGeo

  const q = formatContactSiteAddress(site).trim()
  if (!q) return null
  return `https://maps.google.com/?q=${encodeURIComponent(q)}`
}

export interface CreateContactParams {
  p_kind: string
  p_display_name: string
  p_given_name?: string
  p_family_name?: string
  p_legal_name?: string
  p_tax_id?: string
  p_email?: string
  p_phone?: string
  p_phone_alt?: string
  p_preferred_channel?: string
  p_tags?: string[]
  p_source?: string
}

export async function createContact(params: CreateContactParams): Promise<string> {
  const { data, error } = await supabase.rpc('create_contact', params)
  if (error) throw error
  return data as string
}

export async function archiveContact(contactId: string): Promise<void> {
  const { error } = await supabase.rpc('archive_contact', { p_contact_id: contactId })
  if (error) throw error
}

export async function getContactSite(siteId: string): Promise<ContactSite | null> {
  const { data, error } = await supabase
    .from('contact_sites')
    .select('*')
    .eq('id', siteId)
    .maybeSingle()

  if (error) throw error
  return data as ContactSite | null
}

export interface ContactSiteInput {
  tenant_id: string
  contact_id: string
  name?: string | null
  address?: string | null
  street?: string | null
  street_number?: string | null
  city?: string | null
  province?: string | null
  postal_code?: string | null
  country_code?: string | null
  geo_coordinates?: GeoCoordinates | null
  notes?: string | null
}

function contactSiteWritePayload(input: Omit<ContactSiteInput, 'tenant_id' | 'contact_id'>) {
  return {
    address: input.address ?? null,
    street: input.street ?? null,
    street_number: input.street_number ?? null,
    city: input.city ?? null,
    province: input.province ?? null,
    postal_code: input.postal_code ?? null,
    country_code: input.country_code ?? null,
    geo_coordinates: input.geo_coordinates ?? null,
    notes: input.notes || null,
  }
}

export async function createContactSite(input: ContactSiteInput): Promise<string> {
  const name =
    (input.name?.trim() ||
      [input.street, input.street_number].filter(Boolean).join(' ').trim() ||
      [input.address, input.city].filter(Boolean).join(', ').trim() ||
      'Adreça')

  // `contact_sites` view Insert type is stale (missing street/street_number/
  // province/geo_coordinates — see supabase/migrations/20261144000001 and
  // 20261148000001_maps_expose_sites_contact_sites_columns.sql).
  const { data, error } = await supabase
    .from('contact_sites')
    .insert({
      tenant_id: input.tenant_id,
      contact_id: input.contact_id,
      name,
      ...contactSiteWritePayload(input),
      is_active: true,
    } as any)
    .select('id')
    .single()

  if (error) throw error
  if (!data?.id) throw new Error('contact_site_created_without_id')
  return data.id
}

export async function updateContactSite(
  siteId: string,
  patch: Omit<ContactSiteInput, 'tenant_id' | 'contact_id'>,
): Promise<void> {
  const { error } = await supabase
    .from('contact_sites')
    .update({
      name: patch.name ?? null,
      ...contactSiteWritePayload(patch),
    } as any)
    .eq('id', siteId)

  if (error) throw error
}

export async function deleteContactSite(siteId: string): Promise<void> {
  const { error } = await supabase
    .from('contact_sites')
    .update({ is_active: false })
    .eq('id', siteId)

  if (error) throw error
}

/** CP-C — types locals fins a regenerar database.types.ts */
export type ContactRelationshipRole =
  | 'primary'
  | 'billing'
  | 'operations'
  | 'other'

export type ContactRelationship = {
  id: string
  tenant_id: string
  organization_contact_id: string
  person_contact_id: string
  role: ContactRelationshipRole
  starts_at: string
  ends_at: string | null
  revoked_at: string | null
  revoke_reason: string | null
  source: string
  organization_display_name: string | null
  person_display_name: string | null
  is_active: boolean | null
}

export type ContactDeliveryChannel = {
  id: string
  tenant_id: string
  contact_id: string
  channel_type: 'email' | 'phone'
  value_raw: string
  value_normalized: string
  verified_at: string | null
  verification_method: string | null
  disabled_at: string | null
  is_active: boolean | null
  is_verified: boolean | null
  contact_display_name: string | null
}

export type ContactDeliveryPurpose = 'bulletin' | 'invoice'
export type ContactDeliveryPolicy = 'manual' | 'on_publish'

export type ContactDeliveryRule = {
  id: string
  tenant_id: string
  client_account_contact_id: string
  contact_point_id: string
  purpose: ContactDeliveryPurpose
  policy: ContactDeliveryPolicy
  disabled_at: string | null
  created_at: string
  updated_at: string
}

export async function listContactRelationships(opts: {
  organizationContactId?: string
  personContactId?: string
  activeOnly?: boolean
}): Promise<ContactRelationship[]> {
  let query = supabase.from('contact_relationships' as any).select('*')

  if (opts.organizationContactId) {
    query = query.eq('organization_contact_id', opts.organizationContactId)
  }
  if (opts.personContactId) {
    query = query.eq('person_contact_id', opts.personContactId)
  }
  if (opts.activeOnly !== false) {
    query = query.is('revoked_at', null)
  }

  const { data, error } = await query.order('created_at', { ascending: false })
  if (error) throw error
  return (data ?? []) as ContactRelationship[]
}

export async function createContactRelationship(params: {
  organizationContactId: string
  personContactId: string
  role?: ContactRelationshipRole
  source?: string
}): Promise<string> {
  const { data, error } = await supabase.rpc('create_contact_relationship' as any, {
    p_organization_contact_id: params.organizationContactId,
    p_person_contact_id: params.personContactId,
    p_role: params.role ?? 'other',
    p_source: params.source ?? 'manual',
  })
  if (error) throw error
  return data as string
}

export async function revokeContactRelationship(
  relationshipId: string,
  reason?: string,
): Promise<void> {
  const { error } = await supabase.rpc('revoke_contact_relationship' as any, {
    p_relationship_id: relationshipId,
    p_reason: reason ?? null,
  })
  if (error) throw error
}

export async function listContactDeliveryChannels(
  contactId: string,
  opts?: { activeOnly?: boolean },
): Promise<ContactDeliveryChannel[]> {
  let query = supabase
    .from('contact_delivery_channels' as any)
    .select('*')
    .eq('contact_id', contactId)

  if (opts?.activeOnly !== false) {
    query = query.is('disabled_at', null)
  }

  const { data, error } = await query.order('created_at', { ascending: false })
  if (error) throw error
  return (data ?? []) as ContactDeliveryChannel[]
}

export async function createContactDeliveryChannel(params: {
  contactId: string
  channelType: 'email' | 'phone'
  value: string
  markVerified?: boolean
}): Promise<string> {
  const { data, error } = await supabase.rpc('create_contact_delivery_channel' as any, {
    p_contact_id: params.contactId,
    p_channel_type: params.channelType,
    p_value: params.value,
    p_mark_verified: params.markVerified ?? false,
    p_verification_method: 'staff_confirmed',
  })
  if (error) throw error
  return data as string
}

export async function verifyContactDeliveryChannel(channelId: string): Promise<void> {
  const { error } = await supabase.rpc('verify_contact_delivery_channel' as any, {
    p_channel_id: channelId,
    p_verification_method: 'staff_confirmed',
  })
  if (error) throw error
}

export async function disableContactDeliveryChannel(
  channelId: string,
  reason?: string,
): Promise<void> {
  const { error } = await supabase.rpc('disable_contact_delivery_channel' as any, {
    p_channel_id: channelId,
    p_reason: reason ?? null,
  })
  if (error) throw error
}

export async function listContactDeliveryRules(
  clientAccountContactId: string,
  opts?: { activeOnly?: boolean; purpose?: ContactDeliveryPurpose },
): Promise<ContactDeliveryRule[]> {
  let query = supabase
    .from('contact_delivery_rules' as any)
    .select('*')
    .eq('client_account_contact_id', clientAccountContactId)

  if (opts?.activeOnly !== false) {
    query = query.is('disabled_at', null)
  }
  if (opts?.purpose) {
    query = query.eq('purpose', opts.purpose)
  }

  const { data, error } = await query.order('created_at', { ascending: false })
  if (error) throw error
  return (data ?? []) as ContactDeliveryRule[]
}

export async function createContactDeliveryRule(params: {
  clientAccountContactId: string
  contactPointId: string
  purpose: ContactDeliveryPurpose
  policy?: ContactDeliveryPolicy
}): Promise<string> {
  const { data, error } = await supabase.rpc('create_contact_delivery_rule' as any, {
    p_client_account_contact_id: params.clientAccountContactId,
    p_contact_point_id: params.contactPointId,
    p_purpose: params.purpose,
    p_policy: params.policy ?? 'manual',
  })
  if (error) throw error
  return data as string
}

export async function disableContactDeliveryRule(
  ruleId: string,
  reason?: string,
): Promise<void> {
  const { error } = await supabase.rpc('disable_contact_delivery_rule' as any, {
    p_rule_id: ruleId,
    p_reason: reason ?? null,
  })
  if (error) throw error
}

/** Search contacts by kind + query for combobox pickers. */
export async function searchContacts(opts: {
  kind?: 'person' | 'company'
  q?: string
  limit?: number
}): Promise<Contact[]> {
  const all = await getContacts({ limit: opts.limit ?? 100 })
  let result = all
  if (opts.kind) {
    result = result.filter((c) => c.kind === opts.kind)
  }
  const q = opts.q?.trim().toLowerCase()
  if (q) {
    result = result.filter(
      (c) =>
        c.display_name?.toLowerCase().includes(q) ||
        c.email?.toLowerCase().includes(q) ||
        c.phone?.includes(q),
    )
  }
  return result.slice(0, opts.limit ?? 50)
}
