import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Briefcase, Loader2, Plus, Trash2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useDepartments } from '@/features/departments/api/useDepartments'
import {
  useCreateJobPosition,
  useDeleteJobPosition,
  useJobPositions,
  useUpdateJobPosition,
} from '../api/useJobPositions'

export function JobPositionsPage() {
  const { t } = useTranslation('employees')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const { data: positions = [], isLoading } = useJobPositions(false)
  const { data: departments = [] } = useDepartments()
  const createMutation = useCreateJobPosition()
  const updateMutation = useUpdateJobPosition()
  const deleteMutation = useDeleteJobPosition()

  const [name, setName] = useState('')
  const [code, setCode] = useState('')
  const [departmentId, setDepartmentId] = useState('')

  async function onCreate() {
    if (!activeTenant?.id || !name.trim()) return
    try {
      await createMutation.mutateAsync({
        tenant_id: activeTenant.id,
        name: name.trim(),
        code: code.trim() || null,
        description: null,
        department_id: departmentId || null,
        is_active: true,
      })
      setName('')
      setCode('')
      setDepartmentId('')
      toast({ title: t('employees.positions.created', 'Lloc de treball creat') })
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.positions.create_failed', "No s'ha pogut crear el lloc de treball"),
        description: e instanceof Error ? e.message : undefined,
      })
    }
  }

  return (
    <div className="max-w-3xl mx-auto px-4 py-8 space-y-6">
      <div className="flex items-center gap-3">
        <div className="h-10 w-10 rounded-xl bg-primary/10 flex items-center justify-center">
          <Briefcase className="h-5 w-5 text-primary" />
        </div>
        <div>
          <h1 className="text-xl font-bold">{t('employees.positions.title', 'Llocs de treball')}</h1>
          <p className="text-sm text-muted-foreground">
            {t('employees.positions.subtitle', 'Catàleg de llocs de treball estructurats')}
          </p>
        </div>
      </div>

      <div className="rounded-xl border p-4 space-y-3">
        <h2 className="text-sm font-medium">{t('employees.positions.new', 'Nou lloc de treball')}</h2>
        <div className="grid gap-2 sm:grid-cols-3">
          <Input
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder={t('employees.positions.name_placeholder', 'Nom')}
          />
          <Input
            value={code}
            onChange={(e) => setCode(e.target.value)}
            placeholder={t('employees.positions.code_placeholder', 'Codi (opcional)')}
          />
          <select
            className="rounded-md border border-input bg-background px-3 py-2 text-sm"
            value={departmentId}
            onChange={(e) => setDepartmentId(e.target.value)}
          >
            <option value="">{t('employees.positions.no_department', 'Sense departament')}</option>
            {departments.map((d) => (
              <option key={d.id!} value={d.id!}>
                {d.name}
              </option>
            ))}
          </select>
        </div>
        <Button type="button" size="sm" disabled={!name.trim() || createMutation.isPending} onClick={() => void onCreate()}>
          {createMutation.isPending ? <Loader2 className="h-4 w-4 animate-spin mr-1" /> : <Plus className="h-4 w-4 mr-1" />}
          {t('employees.positions.add', 'Afegir')}
        </Button>
      </div>

      {isLoading ? (
        <div className="flex justify-center py-10">
          <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
        </div>
      ) : positions.length === 0 ? (
        <p className="text-sm text-muted-foreground">{t('employees.positions.empty', 'Encara no hi ha llocs de treball')}</p>
      ) : (
        <ul className="space-y-2">
          {positions.map((p) => (
            <li key={p.id!} className="flex items-center gap-3 rounded-xl border px-4 py-3">
              <div className="flex-1 min-w-0">
                <p className="text-sm font-medium truncate">
                  {p.name}
                  {p.code ? <span className="text-muted-foreground font-normal"> · {p.code}</span> : null}
                </p>
                <p className="text-xs text-muted-foreground">
                  {p.is_active
                    ? t('employees.positions.active', 'Activa')
                    : t('employees.positions.inactive', 'Inactiva')}
                </p>
              </div>
              <Button
                type="button"
                variant="ghost"
                size="sm"
                onClick={async () => {
                  try {
                    await updateMutation.mutateAsync({
                      id: p.id!,
                      params: { is_active: !p.is_active },
                    })
                  } catch (e) {
                    toast({
                      variant: 'destructive',
                      title: t('employees.positions.update_failed', "No s'ha pogut actualitzar"),
                      description: e instanceof Error ? e.message : undefined,
                    })
                  }
                }}
              >
                {p.is_active
                  ? t('employees.positions.deactivate', 'Desactivar')
                  : t('employees.positions.activate', 'Activar')}
              </Button>
              <Button
                type="button"
                variant="ghost"
                size="icon"
                className="h-8 w-8"
                onClick={async () => {
                  try {
                    await deleteMutation.mutateAsync(p.id!)
                    toast({ title: t('employees.positions.deleted', 'Lloc de treball eliminat') })
                  } catch (e) {
                    toast({
                      variant: 'destructive',
                      title: t('employees.positions.delete_failed', "No s'ha pogut eliminar"),
                      description: e instanceof Error ? e.message : undefined,
                    })
                  }
                }}
              >
                <Trash2 className="h-4 w-4" />
              </Button>
            </li>
          ))}
        </ul>
      )}

      <Link to="/employees" className="text-sm text-primary hover:underline">
        {t('employees.positions.back', 'Tornar a empleats')}
      </Link>
    </div>
  )
}
