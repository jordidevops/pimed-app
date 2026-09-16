export const SESSION_COOKIE = 'cp_share_session'
export const ACTOR_COOKIE = 'cp_actor_type'
export const COOKIE_PATH = '/'
export const HEX_64_RE = /^[0-9a-f]{64}$/
/** Grant sessions reuse SESSION_COOKIE with actor `grant`. */
export const GRANT_SESSION_COOKIE = SESSION_COOKIE

export type ActorType = 'share' | 'staff' | 'grant'

export type AccessActivityPrincipal = {
  principal_kind?: string
  email_normalized?: string
  display_name?: string
  created_at?: string
  last_seen_at?: string | null
}

export type AccessActivitySupportSession = {
  kind?: string
  created_at?: string
  last_seen_at?: string | null
  expires_at?: string
  active?: boolean
}

export type TenantPublicProfile = {
  display_name?: string | null
  support_email?: string | null
  support_phone?: string | null
  address?: string | null
  website_url?: string | null
  privacy_url?: string | null
}

export type AccessActivity = {
  tenant_display_name?: string | null
  tenant_profile?: TenantPublicProfile | null
  principals?: AccessActivityPrincipal[]
  support_sessions?: AccessActivitySupportSession[]
}

export type ResolveOk = {
  ok: true
  session_token?: string
  expires_at?: string
  locale?: string
  content_digest?: string
  projection?: Record<string, unknown>
  media_manifest?: unknown
  actor_type?: ActorType
  staff_user_id?: string
  bulletins?: unknown
  report_version_id?: string
  grant_id?: string
  tenant_id?: string
  scope_mode?: 'report_version' | 'client_account' | string
  client_account_contact_id?: string
  requires_report_version_id?: boolean
  preferred_locale?: string | null
  supported_locales?: string[]
  default_locale?: string | null
  allow_client_locale_change?: boolean
  content_locale?: string | null
  access_activity?: AccessActivity | null
  tenant_profile?: TenantPublicProfile | null
  /** Same title shown in the bulletin list (OS / project name). */
  title?: string
}

export type ResolveFail = {
  ok: false
  error: string
  status: number
}

export type BulletinListItem = {
  report_version_id: string
  report_id?: string
  project_id?: string
  version_number?: number
  content_digest?: string
  locale?: string
  published_at?: string
  title?: string
  media_count?: number
}
