import type { TenantContentFormState, TenantContentItem } from '../api/tenantContentTypes'

export function itemToFormState(item: TenantContentItem): TenantContentFormState {
  const rawTranslations = (item.translations ?? {}) as Record<
    string,
    { title?: string; seoTitle?: string; seoDescription?: string; content?: { html?: string }; contentHtml?: string }
  >

  const translations = Object.fromEntries(
    Object.entries(rawTranslations).map(([locale, t]) => {
      const { content, ...rest } = t
      return [locale, { ...rest, contentHtml: content?.html ?? rest.contentHtml ?? '' }]
    }),
  )

  return {
    id: item.id,
    content_type: item.content_type,
    slug: item.slug,
    title: item.title,
    excerpt: item.excerpt ?? '',
    contentHtml: item.content?.html ?? '',
    translations,
    status: item.status,
    publish_start_at: item.publish_start_at?.slice(0, 16) ?? '',
    publish_end_at: item.publish_end_at?.slice(0, 16) ?? '',
    is_sticky: item.is_sticky,
    sort_order: item.sort_order,
    employee_channel_enabled: item.employee_channel_enabled,
    employee_audience_scope: item.employee_audience_scope,
    employee_audience_site_id: item.employee_audience_site_id ?? '',
    employee_audience_department_ids: item.employee_audience_department_ids ?? [],
    public_channel_enabled: item.public_channel_enabled,
    public_site_id: item.public_site_id ?? '',
    public_show_in_nav: item.public_show_in_nav,
    public_show_lead_form: item.public_show_lead_form,
    seo_title: item.seo_title ?? '',
    seo_description: item.seo_description ?? '',
  }
}

export function formStateToPayload(form: TenantContentFormState): Record<string, unknown> {
  const translationsForRpc = Object.fromEntries(
    Object.entries(form.translations).map(([locale, t]) => {
      const { contentHtml, ...rest } = t
      return [locale, contentHtml ? { ...rest, content: { html: contentHtml } } : rest]
    }),
  )

  return {
    id: form.id,
    content_type: form.content_type,
    slug: form.slug.trim(),
    title: form.title.trim(),
    excerpt: form.excerpt.trim() || null,
    content: { html: form.contentHtml },
    translations: translationsForRpc,
    publish_start_at: form.publish_start_at || null,
    publish_end_at: form.publish_end_at || null,
    is_sticky: form.is_sticky,
    sort_order: form.sort_order,
    employee_channel_enabled: form.employee_channel_enabled,
    employee_audience_scope: form.employee_audience_scope,
    employee_audience_site_id: form.employee_audience_site_id || null,
    employee_audience_department_ids: form.employee_audience_department_ids,
    public_channel_enabled: form.public_channel_enabled,
    public_site_id: form.public_site_id || null,
    public_show_in_nav: form.public_show_in_nav,
    public_show_lead_form: form.public_show_lead_form,
    seo_title: form.seo_title.trim() || null,
    seo_description: form.seo_description.trim() || null,
  }
}

export function defaultFormState(
  entry: 'employee' | 'public',
  contentType: 'page' | 'announcement' = 'page',
  publicSiteId?: string,
): TenantContentFormState {
  const employeeOn = contentType === 'announcement' || entry === 'employee'
  const publicOn = contentType === 'page' && entry === 'public'

  return {
    content_type: contentType,
    slug: '',
    title: '',
    excerpt: '',
    contentHtml: '',
    translations: {},
    status: 'draft',
    publish_start_at: '',
    publish_end_at: '',
    is_sticky: false,
    sort_order: 0,
    employee_channel_enabled: employeeOn,
    employee_audience_scope: 'tenant',
    employee_audience_site_id: '',
    employee_audience_department_ids: [],
    public_channel_enabled: publicOn,
    public_site_id: publicSiteId ?? '',
    public_show_in_nav: true,
    public_show_lead_form: false,
    seo_title: '',
    seo_description: '',
  }
}

export function channelBadge(item: Pick<TenantContentItem, 'employee_channel_enabled' | 'public_channel_enabled'>) {
  if (item.employee_channel_enabled && item.public_channel_enabled) return 'dual' as const
  if (item.public_channel_enabled) return 'public' as const
  return 'employee' as const
}
