export interface SenderProfile {
  id: string
  label: string
  from_name: string
  reply_to: string
}

export interface EmailConfigMetadata {
  sender_profiles?: SenderProfile[]
}

export interface EmailConfig {
  tenant_id: string
  default_provider: 'resend' | 'sendgrid' | null
  default_from_name: string | null
  default_reply_to: string | null
  default_layout_id: string | null
  layout_variables: Record<string, string> | null
  rate_limit_per_hour: number
  rate_limit_per_day: number
  max_retries: number
  retention_days: number
  custom_domains_enabled: boolean
  max_custom_domains: number
  metadata: EmailConfigMetadata | null
  logo_url: string | null
  tenant_name_fallback: string | null
  created_at: string
  updated_at: string
}

export type EmailConfigUpsert = Omit<EmailConfig, 'tenant_id' | 'created_at' | 'updated_at'>

export interface SiteEmailConfig {
  id: string
  tenant_id: string
  email_from_name: string | null
  email_reply_to: string | null
  email_logo_url: string | null
  email_tenant_name_fallback: string | null
  default_email_layout_id: string | null
}

export interface SiteEmailConfigUpdate {
  email_from_name?: string | null
  email_reply_to?: string | null
  email_logo_url?: string | null
  email_tenant_name_fallback?: string | null
  default_email_layout_id?: string | null
}

export type DomainVerificationStatus = 'pending' | 'verified' | 'failed'

export interface DnsRecord {
  type: string
  name: string
  value: string
  ttl?: number
}

export interface EmailDomain {
  id: string
  tenant_id: string
  domain: string
  verification_status: DomainVerificationStatus
  dns_records: DnsRecord[] | null
  provider_domain_id: string | null
  verified_at: string | null
  is_primary: boolean
  default_from_email: string | null
  default_from_name: string | null
  default_reply_to: string | null
  created_at: string
  updated_at: string
}

export interface EmailDomainUpdate {
  is_primary?: boolean
  default_from_email?: string | null
  default_from_name?: string | null
  default_reply_to?: string | null
}

export type TemplateTranslations = Record<
  string,
  { subject?: string; html?: string; text?: string }
>

export interface EmailTemplate {
  id: string
  tenant_id: string | null
  name: string
  slug: string
  event_type: string | null
  subject_template: string
  html_body_template: string | null
  text_body_template: string | null
  variables_schema: Record<string, unknown> | null
  is_layout: boolean
  layout_id: string | null
  use_layout: boolean
  is_platform_default: boolean
  is_active: boolean
  is_draft: boolean
  translations: TemplateTranslations
  created_at: string
  updated_at: string
}

export type EmailTemplateUpdate = Partial<
  Pick<
    EmailTemplate,
    | 'name'
    | 'slug'
    | 'event_type'
    | 'subject_template'
    | 'html_body_template'
    | 'text_body_template'
    | 'variables_schema'
    | 'layout_id'
    | 'use_layout'
    | 'is_active'
    | 'is_draft'
    | 'translations'
  >
>

export type EmailLogStatus =
  | 'queued'
  | 'processing'
  | 'sent'
  | 'delivered'
  | 'bounced'
  | 'failed'

export interface EmailLog {
  id: string
  to_emails: string[]
  cc_emails: string[] | null
  bcc_emails: string[] | null
  subject: string | null
  status: EmailLogStatus
  from_email: string | null
  from_name: string | null
  reply_to: string | null
  attempt_count: number
  is_dead_letter: boolean
  site_id: string | null
  created_at: string
  sent_at: string | null
  delivered_at: string | null
  last_error: string | null
  error_history: Array<{ attempt: number; error: string; at: string }> | null
  html_body: string | null
  text_body: string | null
}


