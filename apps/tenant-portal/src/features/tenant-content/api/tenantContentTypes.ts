export type ContentType = 'page' | 'announcement'
export type ContentStatus = 'draft' | 'published' | 'archived'
export type ContentEntryContext = 'employee' | 'public'
export type EmployeeAudienceScope = 'tenant' | 'site' | 'departments'

export type TenantContentItem = {
  id: string
  tenant_id: string
  content_type: ContentType
  slug: string
  title: string
  excerpt: string | null
  content: { html?: string; show_lead_form?: boolean }
  translations: Record<string, unknown>
  status: ContentStatus
  publish_start_at: string | null
  publish_end_at: string | null
  published_at: string | null
  is_sticky: boolean
  sort_order: number
  featured_image_url: string | null
  employee_channel_enabled: boolean
  employee_audience_scope: EmployeeAudienceScope
  employee_audience_site_id: string | null
  employee_audience_department_ids: string[]
  public_channel_enabled: boolean
  public_site_id: string | null
  public_show_in_nav: boolean
  public_show_lead_form: boolean
  seo_title: string | null
  seo_description: string | null
  public_page_id: string | null
  created_at: string
  updated_at: string
}

export type TenantContentFormState = {
  id?: string
  content_type: ContentType
  slug: string
  title: string
  excerpt: string
  contentHtml: string
  translations: Record<string, { title?: string; seoTitle?: string; seoDescription?: string; contentHtml?: string }>
  status: ContentStatus
  publish_start_at: string
  publish_end_at: string
  is_sticky: boolean
  sort_order: number
  employee_channel_enabled: boolean
  employee_audience_scope: EmployeeAudienceScope
  employee_audience_site_id: string
  employee_audience_department_ids: string[]
  public_channel_enabled: boolean
  public_site_id: string
  public_show_in_nav: boolean
  public_show_lead_form: boolean
  seo_title: string
  seo_description: string
}

export type RpcOk<T> = { ok: true } & T
export type RpcErr = { ok: false; code: string; message?: string }

export type UpsertContentResult = RpcOk<{ item: TenantContentItem }> | RpcErr
export type PublishContentResult =
  | RpcOk<{ item: TenantContentItem; public_page_id?: string; revalidate?: { public_site_id?: string; slug?: string } }>
  | RpcErr

export type ContentListFilters = {
  status?: ContentStatus
  content_type?: ContentType
  channel?: 'employee' | 'public' | 'dual'
  public_site_id?: string
  search?: string
}
