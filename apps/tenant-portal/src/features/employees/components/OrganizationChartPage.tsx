import { useEffect, useMemo, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import {
  ArrowDownFromLine,
  ArrowRightFromLine,
  ChevronDown,
  ChevronRight,
  GitBranch,
  Layers,
  LayoutGrid,
  Loader2,
  Network,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'
import { useTenant } from '@/contexts/TenantContext'
import { useDepartments } from '@/features/departments/api/useDepartments'
import { useEmployees } from '../api/useEmployees'
import { useEmployeeOrgTree } from '../api/useOrganization'
import type { OrgTreeNode } from '../api/organizationService'
import { useJobPositions } from '../api/useJobPositions'
import { jobPlaceName } from '../utils/jobPlaceName'
import { EmployeeAvatar } from './EmployeePhotoUploader'

type OrgViewMode = 'hierarchy' | 'departments' | 'dept_hierarchy'
type OrgOrientation = 'vertical' | 'horizontal'

const VIEW_STORAGE_KEY = 'employees.org.viewMode'
const ORIENTATION_STORAGE_KEY = 'employees.org.orientation'

interface OrgNode extends OrgTreeNode {
  children: OrgNode[]
}

function displayName(n: { preferred_name?: string | null; full_name?: string | null }) {
  return n.preferred_name?.trim() || n.full_name || '—'
}

function readStoredView(): OrgViewMode {
  try {
    const v = localStorage.getItem(VIEW_STORAGE_KEY)
    if (v === 'hierarchy' || v === 'departments' || v === 'dept_hierarchy') return v
  } catch {
    /* ignore */
  }
  return 'hierarchy'
}

function readStoredOrientation(): OrgOrientation {
  try {
    const v = localStorage.getItem(ORIENTATION_STORAGE_KEY)
    if (v === 'vertical' || v === 'horizontal') return v
  } catch {
    /* ignore */
  }
  return 'vertical'
}

/** Converteix la llista plana (ORDER BY path) en un arbre nidificat. */
export function buildOrgForest(nodes: OrgTreeNode[]): OrgNode[] {
  const byId = new Map<string, OrgNode>()
  for (const n of nodes) {
    byId.set(n.id, { ...n, children: [] })
  }
  const roots: OrgNode[] = []
  for (const n of nodes) {
    const node = byId.get(n.id)!
    const parentId = n.manager_employee_id
    if (parentId && byId.has(parentId)) {
      byId.get(parentId)!.children.push(node)
    } else {
      roots.push(node)
    }
  }
  const sortRec = (list: OrgNode[]) => {
    list.sort((a, b) =>
      displayName(a).localeCompare(displayName(b), undefined, { sensitivity: 'base' }),
    )
    list.forEach((c) => sortRec(c.children))
  }
  sortRec(roots)
  return roots
}

function OrgPersonCard({
  node,
  compact,
}: {
  node: Pick<
    OrgTreeNode,
    'id' | 'full_name' | 'preferred_name' | 'job_position_name' | 'photo_object_path' | 'status'
  >
  compact?: boolean
}) {
  const name = displayName(node)
  return (
    <Link
      to={`/employees/${node.id}`}
      className={cn(
        'group flex flex-col items-center rounded-xl border border-border bg-card text-center shadow-sm transition-shadow hover:border-primary/40 hover:shadow-md',
        compact ? 'w-36 gap-1.5 px-2 py-3' : 'w-44 gap-2 px-3 py-4',
      )}
      data-testid="org-person-card"
    >
      <EmployeeAvatar
        fullName={node.full_name}
        preferredName={node.preferred_name}
        photoObjectPath={node.photo_object_path}
        size={compact ? 'md' : 'lg'}
      />
      <div className="min-w-0 w-full space-y-0.5">
        <p className="truncate text-sm font-semibold text-foreground group-hover:text-primary">
          {name}
        </p>
        {node.job_position_name ? (
          <p className="line-clamp-2 text-[11px] leading-snug text-muted-foreground">
            {node.job_position_name}
          </p>
        ) : null}
      </div>
    </Link>
  )
}

function OrgTreeNodeView({
  node,
  depth = 0,
  orientation,
}: {
  node: OrgNode
  depth?: number
  orientation: OrgOrientation
}) {
  const { t } = useTranslation('employees')
  const [expanded, setExpanded] = useState(depth < 2)
  const hasChildren = node.children.length > 0

  const expandBtn = hasChildren ? (
    <Button
      type="button"
      variant="outline"
      size="sm"
      className="h-7 gap-1 rounded-full px-2 text-[11px]"
      onClick={() => setExpanded((v) => !v)}
      aria-expanded={expanded}
    >
      {expanded ? <ChevronDown className="h-3.5 w-3.5" /> : <ChevronRight className="h-3.5 w-3.5" />}
      {t('employees.org.reports_count', '{{count}} a càrrec', { count: node.children.length })}
    </Button>
  ) : null

  if (orientation === 'horizontal') {
    return (
      <li className="relative flex flex-row items-center py-2">
        {depth > 0 ? (
          <div className="mr-0 h-px w-5 shrink-0 bg-border" aria-hidden />
        ) : null}
        <div className="relative z-[1] flex shrink-0 flex-col items-center gap-1">
          <OrgPersonCard node={node} compact={depth > 0} />
          {expandBtn}
        </div>

        {hasChildren && expanded ? (
          <>
            <div className="h-px w-5 shrink-0 bg-border" aria-hidden />
            <ul
              className={cn(
                'relative flex flex-col justify-center gap-1 py-1 pl-0',
                'before:absolute before:bottom-[12%] before:left-0 before:top-[12%] before:w-px before:bg-border',
              )}
            >
              {node.children.map((child) => (
                <OrgTreeNodeView
                  key={child.id}
                  node={child}
                  depth={depth + 1}
                  orientation="horizontal"
                />
              ))}
            </ul>
          </>
        ) : null}
      </li>
    )
  }

  return (
    <li className="relative flex flex-col items-center pt-5">
      {depth > 0 ? (
        <div className="absolute left-1/2 top-0 h-5 w-px -translate-x-1/2 bg-border" aria-hidden />
      ) : null}
      <div className="relative z-[1] flex flex-col items-center gap-1">
        <OrgPersonCard node={node} />
        {expandBtn}
      </div>

      {hasChildren && expanded ? (
        <>
          <div className="h-5 w-px bg-border" aria-hidden />
          <ul
            className={cn(
              'relative flex flex-row flex-wrap justify-center gap-x-6 gap-y-8',
              'before:absolute before:left-[8%] before:right-[8%] before:top-0 before:h-px before:bg-border',
            )}
          >
            {node.children.map((child) => (
              <OrgTreeNodeView
                key={child.id}
                node={child}
                depth={depth + 1}
                orientation="vertical"
              />
            ))}
          </ul>
        </>
      ) : null}
    </li>
  )
}

function HierarchyForest({
  forest,
  orientation,
}: {
  forest: OrgNode[]
  orientation: OrgOrientation
}) {
  const { t } = useTranslation('employees')
  if (forest.length === 0) return null

  const treeList = (root: OrgNode) => (
    <ul
      className={cn(
        orientation === 'horizontal'
          ? 'flex items-center overflow-x-auto pb-2 pt-1'
          : 'flex justify-center overflow-x-auto pb-4 pt-2',
      )}
    >
      <OrgTreeNodeView node={root} orientation={orientation} />
    </ul>
  )

  if (forest.length === 1) {
    return treeList(forest[0])
  }

  return (
    <div className="space-y-10">
      <p className="text-center text-sm text-muted-foreground">
        {t(
          'employees.org.multiple_roots_hint',
          'Hi ha {{count}} arrels (sense manager). Cada arbre és una línia de reporting.',
          { count: forest.length },
        )}
      </p>
      <div className="flex flex-col gap-12">
        {forest.map((root) => (
          <div
            key={root.id}
            className="overflow-x-auto rounded-2xl border border-dashed border-border/80 bg-muted/20 px-4 py-6"
          >
            {treeList(root)}
          </div>
        ))}
      </div>
    </div>
  )
}

function DepartmentsView({ siteId }: { siteId?: string | null }) {
  const { t } = useTranslation('employees')
  const { sites } = useTenant()
  const { data: employees = [], isLoading, error } = useEmployees()
  const { data: departments = [] } = useDepartments()
  const { data: jobPositions = [] } = useJobPositions(true)

  const deptName = useMemo(() => {
    const map: Record<string, string> = {}
    for (const d of departments) {
      if (d.id) map[d.id] = d.name ?? d.id
    }
    return map
  }, [departments])

  const siteName = useMemo(() => {
    const map: Record<string, string> = {}
    for (const s of sites) map[s.id] = s.name
    return map
  }, [sites])

  const positionsById = useMemo(() => {
    const map: Record<string, { name?: string | null }> = {}
    for (const p of jobPositions) {
      if (p.id) map[p.id] = p
    }
    return map
  }, [jobPositions])

  const scopedEmployees = useMemo(() => {
    if (!siteId) return employees
    return employees.filter((e) => e.site_id === siteId)
  }, [employees, siteId])

  const groups = useMemo(() => {
    const buckets = new Map<string, typeof scopedEmployees>()
    for (const e of scopedEmployees) {
      const key = e.department_id || '__none__'
      const list = buckets.get(key) ?? []
      list.push(e)
      buckets.set(key, list)
    }
    const entries = Array.from(buckets.entries()).map(([key, list]) => ({
      key,
      label:
        key === '__none__'
          ? t('employees.org.no_department', 'Sense departament')
          : deptName[key] || t('employees.org.unknown_department', 'Departament'),
      people: list.sort((a, b) =>
        displayName(a).localeCompare(displayName(b), undefined, { sensitivity: 'base' }),
      ),
    }))
    entries.sort((a, b) => {
      if (a.key === '__none__') return 1
      if (b.key === '__none__') return -1
      return a.label.localeCompare(b.label, undefined, { sensitivity: 'base' })
    })
    return entries
  }, [scopedEmployees, deptName, t])

  if (isLoading) {
    return (
      <div className="flex justify-center py-10">
        <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
      </div>
    )
  }
  if (error) {
    return (
      <p className="text-sm text-destructive">
        {t('employees.org.chart_error', "No s'ha pogut carregar l'organigrama")}
      </p>
    )
  }
  if (groups.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        {t('employees.org.chart_empty', 'No hi ha nodes visibles')}
      </p>
    )
  }

  return (
    <div className="space-y-8" data-testid="org-departments-view">
      {groups.map((g) => (
        <section key={g.key} className="space-y-3">
          <div className="flex items-baseline gap-2 border-b border-border pb-2">
            <h2 className="text-base font-semibold text-foreground">{g.label}</h2>
            <span className="text-xs text-muted-foreground">
              {t('employees.org.people_count', '{{count}} persones', { count: g.people.length })}
            </span>
          </div>
          <div className="flex flex-wrap gap-3">
            {g.people.map((p) => (
              <div key={p.id!} className="relative">
                <OrgPersonCard
                  node={{
                    id: p.id!,
                    full_name: p.full_name,
                    preferred_name: p.preferred_name,
                    job_position_name: jobPlaceName(p.job_position_id, positionsById) ?? null,
                    photo_object_path: p.photo_object_path,
                    status: p.status,
                  }}
                  compact
                />
                {p.site_id && siteName[p.site_id] ? (
                  <p className="mt-1 max-w-[9rem] truncate text-center text-[10px] text-muted-foreground/80">
                    {siteName[p.site_id]}
                  </p>
                ) : null}
              </div>
            ))}
          </div>
        </section>
      ))}
    </div>
  )
}

/** Departaments amb jerarquia de reporting dins de cada grup. */
function DeptHierarchyView({
  nodes,
  orientation,
}: {
  nodes: OrgTreeNode[]
  orientation: OrgOrientation
}) {
  const { t } = useTranslation('employees')
  const { data: departments = [] } = useDepartments()

  const deptName = useMemo(() => {
    const map: Record<string, string> = {}
    for (const d of departments) {
      if (d.id) map[d.id] = d.name ?? d.id
    }
    return map
  }, [departments])

  const groups = useMemo(() => {
    const buckets = new Map<string, OrgTreeNode[]>()
    for (const n of nodes) {
      const key = n.department_id || '__none__'
      const list = buckets.get(key) ?? []
      list.push(n)
      buckets.set(key, list)
    }
    const entries = Array.from(buckets.entries()).map(([key, list]) => ({
      key,
      label:
        key === '__none__'
          ? t('employees.org.no_department', 'Sense departament')
          : deptName[key] || t('employees.org.unknown_department', 'Departament'),
      forest: buildOrgForest(list),
      count: list.length,
    }))
    entries.sort((a, b) => {
      if (a.key === '__none__') return 1
      if (b.key === '__none__') return -1
      return a.label.localeCompare(b.label, undefined, { sensitivity: 'base' })
    })
    return entries
  }, [nodes, deptName, t])

  if (groups.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        {t('employees.org.chart_empty', 'No hi ha nodes visibles')}
      </p>
    )
  }

  return (
    <div className="space-y-10" data-testid="org-dept-hierarchy-view">
      <p className="text-sm text-muted-foreground">
        {t(
          'employees.org.dept_hierarchy_hint',
          'Dins de cada departament es mostra qui reporta a qui. Si el manager és d’un altre departament, la persona apareix com a arrel del grup.',
        )}
      </p>
      {groups.map((g) => (
        <section
          key={g.key}
          className="space-y-4 rounded-2xl border border-border/80 bg-muted/15 px-4 py-5"
        >
          <div className="flex items-baseline gap-2 border-b border-border/70 pb-2">
            <h2 className="text-base font-semibold text-foreground">{g.label}</h2>
            <span className="text-xs text-muted-foreground">
              {t('employees.org.people_count', '{{count}} persones', { count: g.count })}
            </span>
          </div>
          {g.forest.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {t('employees.org.chart_empty', 'No hi ha nodes visibles')}
            </p>
          ) : (
            <HierarchyForest forest={g.forest} orientation={orientation} />
          )}
        </section>
      ))}
    </div>
  )
}

export function OrganizationChartPage() {
  const { t } = useTranslation('employees')
  const [params] = useSearchParams()
  const root = params.get('root')
  const { selectedSiteId, sites } = useTenant()
  const [viewMode, setViewMode] = useState<OrgViewMode>(readStoredView)
  const [orientation, setOrientation] = useState<OrgOrientation>(readStoredOrientation)

  const needsTree = viewMode === 'hierarchy' || viewMode === 'dept_hierarchy'
  const { data: nodes = [], isLoading, error } = useEmployeeOrgTree(
    needsTree ? root : null,
    10,
    needsTree,
  )

  useEffect(() => {
    try {
      localStorage.setItem(VIEW_STORAGE_KEY, viewMode)
    } catch {
      /* ignore */
    }
  }, [viewMode])

  useEffect(() => {
    try {
      localStorage.setItem(ORIENTATION_STORAGE_KEY, orientation)
    } catch {
      /* ignore */
    }
  }, [orientation])

  const selectedSiteName = useMemo(
    () => (selectedSiteId ? sites.find((s) => s.id === selectedSiteId)?.name : null),
    [selectedSiteId, sites],
  )

  const scopedNodes = useMemo(() => {
    if (!selectedSiteId) return nodes
    return nodes.filter((n) => n.site_id === selectedSiteId)
  }, [nodes, selectedSiteId])

  const forest = useMemo(() => buildOrgForest(scopedNodes), [scopedNodes])

  const subtitle =
    viewMode === 'departments'
      ? t('employees.org.chart_by_department', 'Persones agrupades per departament')
      : viewMode === 'dept_hierarchy'
        ? t(
            'employees.org.chart_dept_hierarchy',
            'Departaments amb jerarquia de reporting a dins',
          )
        : root
          ? t('employees.org.chart_subtree', 'Equip a partir de l’empleat seleccionat')
          : t(
              'employees.org.chart_hierarchy_hint',
              'Jerarquia de reporting (qui reporta a qui)',
            )

  return (
    <div className="mx-auto w-full max-w-7xl space-y-6 px-4 py-8">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="flex items-center gap-3">
          <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-primary/10">
            <GitBranch className="h-5 w-5 text-primary" />
          </div>
          <div>
            <h1 className="text-xl font-bold" data-testid="org-chart-title">
              {t('employees.org.chart_title', 'Organigrama')}
            </h1>
            <p className="text-sm text-muted-foreground">
              {subtitle}
              {selectedSiteName
                ? ` · ${t('employees.org.scoped_site', 'Centre: {{name}}', {
                    name: selectedSiteName,
                  })}`
                : ''}
            </p>
          </div>
        </div>

        <div className="flex flex-wrap items-center gap-2">
          <div
            className="inline-flex rounded-lg border border-border bg-muted/40 p-0.5"
            role="group"
            aria-label={t('employees.org.view_toggle', "Vista de l'organigrama")}
          >
            <Button
              type="button"
              size="sm"
              variant={viewMode === 'hierarchy' ? 'secondary' : 'ghost'}
              className="h-8 gap-1.5"
              onClick={() => setViewMode('hierarchy')}
              data-testid="org-view-hierarchy"
            >
              <Network className="h-4 w-4" />
              <span className="hidden sm:inline">
                {t('employees.org.view_hierarchy', 'Jerarquia')}
              </span>
            </Button>
            <Button
              type="button"
              size="sm"
              variant={viewMode === 'departments' ? 'secondary' : 'ghost'}
              className="h-8 gap-1.5"
              onClick={() => setViewMode('departments')}
              data-testid="org-view-departments"
            >
              <LayoutGrid className="h-4 w-4" />
              <span className="hidden sm:inline">
                {t('employees.org.view_departments', 'Departaments')}
              </span>
            </Button>
            <Button
              type="button"
              size="sm"
              variant={viewMode === 'dept_hierarchy' ? 'secondary' : 'ghost'}
              className="h-8 gap-1.5"
              onClick={() => setViewMode('dept_hierarchy')}
              data-testid="org-view-dept-hierarchy"
            >
              <Layers className="h-4 w-4" />
              <span className="hidden sm:inline">
                {t('employees.org.view_dept_hierarchy', 'Combinada')}
              </span>
            </Button>
          </div>

          {needsTree ? (
            <div
              className="inline-flex rounded-lg border border-border bg-muted/40 p-0.5"
              role="group"
              aria-label={t('employees.org.orientation_toggle', 'Orientació')}
            >
              <Button
                type="button"
                size="sm"
                variant={orientation === 'vertical' ? 'secondary' : 'ghost'}
                className="h-8 gap-1.5"
                onClick={() => setOrientation('vertical')}
                data-testid="org-orientation-vertical"
                title={t('employees.org.orientation_vertical', 'Vertical')}
              >
                <ArrowDownFromLine className="h-4 w-4" />
                <span className="hidden md:inline">
                  {t('employees.org.orientation_vertical', 'Vertical')}
                </span>
              </Button>
              <Button
                type="button"
                size="sm"
                variant={orientation === 'horizontal' ? 'secondary' : 'ghost'}
                className="h-8 gap-1.5"
                onClick={() => setOrientation('horizontal')}
                data-testid="org-orientation-horizontal"
                title={t('employees.org.orientation_horizontal', 'Horitzontal')}
              >
                <ArrowRightFromLine className="h-4 w-4" />
                <span className="hidden md:inline">
                  {t('employees.org.orientation_horizontal', 'Horitzontal')}
                </span>
              </Button>
            </div>
          ) : null}
        </div>
      </div>

      {viewMode === 'departments' ? (
        <DepartmentsView siteId={selectedSiteId} />
      ) : isLoading ? (
        <div className="flex justify-center py-10">
          <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
        </div>
      ) : error ? (
        <p className="text-sm text-destructive">
          {t('employees.org.chart_error', "No s'ha pogut carregar l'organigrama")}
        </p>
      ) : scopedNodes.length === 0 ? (
        <div className="rounded-2xl border border-dashed border-border bg-muted/20 px-6 py-12 text-center">
          <p className="text-sm text-muted-foreground">
            {selectedSiteId
              ? t(
                  'employees.org.chart_empty_hierarchy_site',
                  'Cap jerarquia visible per a aquest centre. Assigna managers o canvia el filtre de centre.',
                )
              : t(
                  'employees.org.chart_empty_hierarchy',
                  'Encara no hi ha jerarquia de reporting. Assigna un manager als empleats des del seu detall.',
                )}
          </p>
          <Button asChild variant="outline" size="sm" className="mt-4">
            <Link to="/employees">{t('employees.org.back', 'Tornar a empleats')}</Link>
          </Button>
        </div>
      ) : viewMode === 'dept_hierarchy' ? (
        <DeptHierarchyView nodes={scopedNodes} orientation={orientation} />
      ) : (
        <div data-testid="org-hierarchy-view">
          <HierarchyForest forest={forest} orientation={orientation} />
        </div>
      )}

      <div className="flex flex-wrap gap-3 text-sm">
        {root && needsTree ? (
          <Link to="/employees/organization" className="text-primary hover:underline">
            {t('employees.org.chart_all_roots', 'Veure tot l’organigrama')}
          </Link>
        ) : null}
        <Link to="/employees" className="text-muted-foreground hover:text-foreground hover:underline">
          {t('employees.org.back', 'Tornar a empleats')}
        </Link>
      </div>
    </div>
  )
}
