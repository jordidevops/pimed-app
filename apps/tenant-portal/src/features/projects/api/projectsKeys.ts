export const projectsKeys = {
  all: (tenantId: string) => ['projects', tenantId] as const,
  list: (
    tenantId: string,
    params: {
      page: number
      pageSize: number
      q: string
      status: string
      type: string
      siteId: string
      departmentId: string
      plannedStartFrom: string
      plannedStartTo: string
      sortField: string
      sortDirection: 'asc' | 'desc'
    },
  ) => [...projectsKeys.all(tenantId), 'list', params] as const,
  detail: (id: string) => ['projects', 'detail', id] as const,
}
