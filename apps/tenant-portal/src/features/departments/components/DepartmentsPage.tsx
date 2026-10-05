import { useState, useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { Plus, Home, ChevronRight, Building2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { PageShell } from '@/components/layout/PageShell'
import { useTenant } from '@/contexts/TenantContext'
import { useToast } from '@/hooks/use-toast'
import { useDepartments } from '../api/useDepartments'
import { useUpdateDepartment } from '../api/useUpdateDepartment'
import { getAncestors, normalizeDeptError } from '../api/departmentsService'
import type { Department } from '../api/departmentsService'
import { DepartmentRow } from './DepartmentRow'
import { DepartmentForm } from './DepartmentForm'

export function DepartmentsPage() {
  const { t } = useTranslation('departments')
  const { activeTenant, tenants, tenantsLoading } = useTenant()
  const { toast } = useToast()

  const { data: allDepts = [], isLoading, error } = useDepartments()
  const updateMutation = useUpdateDepartment()

  // ─── Drill-down navigation state ──────────────────────────────────────────
  const [currentParentId, setCurrentParentId] = useState<string | null>(null)
  const [formOpen, setFormOpen] = useState(false)
  const [editTarget, setEditTarget] = useState<Department | null>(null)
  const [formDefaultParentId, setFormDefaultParentId] = useState<string | null>(null)

  // ─── Derived data ──────────────────────────────────────────────────────────
  const ancestors = useMemo(
    () => getAncestors(allDepts, currentParentId),
    [allDepts, currentParentId],
  )

  const visibleDepts = useMemo(
    () => allDepts.filter((d) => d.parent_id === currentParentId),
    [allDepts, currentParentId],
  )

  const childrenCountMap = useMemo(() => {
    const map: Record<string, number> = {}
    for (const d of allDepts) {
      if (d.parent_id) {
        map[d.parent_id] = (map[d.parent_id] ?? 0) + 1
      }
    }
    return map
  }, [allDepts])

  // ─── Handlers ──────────────────────────────────────────────────────────────
  function handleDrillIn(dept: Department) {
    setCurrentParentId(dept.id ?? null)
  }

  function handleBreadcrumbClick(id: string | null) {
    setCurrentParentId(id)
  }

  function handleOpenCreate() {
    setEditTarget(null)
    setFormDefaultParentId(currentParentId)
    setFormOpen(true)
  }

  function handleEdit(dept: Department) {
    setEditTarget(dept)
    setFormDefaultParentId(null)
    setFormOpen(true)
  }

  function handleAddChild(dept: Department) {
    setEditTarget(null)
    setFormDefaultParentId(dept.id ?? null)
    setFormOpen(true)
  }

  async function handleToggleActive(dept: Department) {
    const newActive = dept.is_active === false
    try {
      await updateMutation.mutateAsync({ id: dept.id!, params: { is_active: newActive } })
      toast({
        description: newActive
          ? t('departments.toast.activated', 'Departament activat')
          : t('departments.toast.deactivated', 'Departament desactivat'),
      })
    } catch (err) {
      const kind = normalizeDeptError(err)
      toast({
        variant: 'destructive',
        description:
          kind === 'unauthorized'
            ? t('departments.errors.unauthorized', 'No tens permís per fer aquesta acció')
            : t('departments.errors.toggle_failed', "Error en canviar l'estat"),
      })
    }
  }

  // ─── Guards ────────────────────────────────────────────────────────────────
  if (tenantsLoading || isLoading) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary" />
      </div>
    )
  }

  // Multi-tenant amb cap tenant seleccionat — patró coherent amb ContactsPage
  if (!activeTenant && tenants.length > 1) {
    return (
      <PageShell
        title={t('departments.title', 'Departaments')}
        icon={<Building2 className="h-5 w-5" aria-hidden />}
      >
        <div className="rounded-2xl border border-amber-200 bg-amber-50 p-6 text-center">
          <p className="text-sm font-medium text-amber-800">
            {t('departments.errors.no_tenant', 'Selecciona una organització per veure els departaments')}
          </p>
        </div>
      </PageShell>
    )
  }

  if (!activeTenant) return null

  if (error) {
    return (
      <PageShell
        title={t('departments.title', 'Departaments')}
        icon={<Building2 className="h-5 w-5" aria-hidden />}
      >
        <div className="rounded-2xl border border-destructive/30 bg-destructive/10 p-6 text-center">
          <p className="text-sm font-medium text-destructive">
            {t('departments.errors.load_failed', 'Error en carregar els departaments')}
          </p>
        </div>
      </PageShell>
    )
  }

  // ─── Render ────────────────────────────────────────────────────────────────
  return (
    <PageShell
      title={t('departments.title', 'Departaments')}
      subtitle={t('departments.subtitle', 'Estructura organitzativa')}
      icon={<Building2 className="h-5 w-5" aria-hidden />}
      actions={
        <Button onClick={handleOpenCreate}>
          <Plus className="h-4 w-4 mr-1.5" />
          {t('departments.new_department', 'Nou departament')}
        </Button>
      }
    >
      <div className="space-y-5">
      {/* Breadcrumbs */}
      <nav aria-label="breadcrumb" className="flex items-center gap-1 text-sm text-muted-foreground flex-wrap">
        <button
          type="button"
          onClick={() => handleBreadcrumbClick(null)}
          className="flex items-center gap-1 hover:text-foreground transition-colors"
        >
          <Home className="h-3.5 w-3.5" />
          <span>{t('departments.breadcrumb_root', 'Tots els departaments')}</span>
        </button>
        {ancestors.map((a) => (
          <span key={a.id} className="flex items-center gap-1">
            <ChevronRight className="h-3.5 w-3.5 shrink-0 text-muted-foreground/50" aria-hidden />
            <button
              type="button"
              onClick={() => handleBreadcrumbClick(a.id ?? null)}
              className="hover:text-foreground transition-colors"
            >
              {a.name}
            </button>
          </span>
        ))}
      </nav>

      {/* Department list */}
      {visibleDepts.length === 0 ? (
        <div className="flex flex-col items-center justify-center py-16 text-center rounded-2xl border border-dashed border-border">
          <Building2 className="h-10 w-10 text-muted-foreground/40 mb-3" aria-hidden />
          <p className="text-sm font-semibold text-muted-foreground">
            {t('departments.empty.title', 'Sense departaments')}
          </p>
          <p className="text-xs text-muted-foreground/60 mt-1 max-w-xs">
            {currentParentId
              ? t('departments.empty.description_sub', 'Aquest departament no té subdepartaments')
              : t('departments.empty.description', 'Crea el primer departament prement el botó de dalt')}
          </p>
          <Button className="mt-4" size="sm" onClick={handleOpenCreate}>
            <Plus className="h-3.5 w-3.5 mr-1.5" />
            {t('departments.new_department', 'Nou departament')}
          </Button>
        </div>
      ) : (
        <div className="space-y-2">
          {visibleDepts.map((dept) => (
            <DepartmentRow
              key={dept.id}
              department={dept}
              childrenCount={childrenCountMap[dept.id!] ?? 0}
              onDrillIn={handleDrillIn}
              onEdit={handleEdit}
              onAddChild={handleAddChild}
              onToggleActive={handleToggleActive}
            />
          ))}
        </div>
      )}

      <DepartmentForm
        open={formOpen}
        onClose={() => setFormOpen(false)}
        editDepartment={editTarget}
        defaultParentId={formDefaultParentId}
        allDepartments={allDepts}
      />
      </div>
    </PageShell>
  )
}
