export const signingKeys = {
  templates:     (tenantId: string)                                 => ['signing', 'templates',      tenantId]             as const,
  locales:       (templateId: string)                               => ['signing', 'locales',        templateId]           as const,
  localesBatch:  (tenantId: string)                                 => ['signing', 'locales_batch',  tenantId]             as const,
  config:        (tenantId: string)                                 => ['signing', 'config',         tenantId]             as const,
  roleDefaults:  (tenantId: string)                                 => ['signing', 'role_defaults',  tenantId]             as const,
  submissions:   (tenantId: string, page: number, filters: object)  => ['signing', 'submissions',    tenantId, page, filters] as const,
  submission:    (id: string)                                       => ['signing', 'submission',     id]                   as const,
  events:        (submissionId: string)                             => ['signing', 'events',         submissionId]         as const,
  contentBlocks: (tenantId: string)                                 => ['signing', 'content_blocks', tenantId]             as const,
}
