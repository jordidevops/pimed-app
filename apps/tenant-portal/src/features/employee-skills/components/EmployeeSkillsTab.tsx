import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Loader2, Plus, Trash2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import {
  useDeleteEmployeeSkill,
  useEmployeeSkills,
  useSkillLevels,
  useSkillLevelsByTypeIds,
  useSkills,
  useSkillTypes,
  useUpsertEmployeeSkill,
} from '../api/useSkills'

export function EmployeeSkillsTab({
  employeeId,
  canManage,
}: {
  employeeId: string
  canManage: boolean
}) {
  const { t } = useTranslation('employees')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const { data: assignments = [], isLoading } = useEmployeeSkills(employeeId)
  const { data: types = [] } = useSkillTypes(true)
  const [typeId, setTypeId] = useState('')
  const { data: skills = [] } = useSkills(typeId || null, true)
  const { data: levels = [] } = useSkillLevels(typeId || null)
  const upsert = useUpsertEmployeeSkill()
  const remove = useDeleteEmployeeSkill()

  const [skillId, setSkillId] = useState('')
  const [levelId, setLevelId] = useState('')

  const skillMap = useSkills(null, false).data ?? []

  const assignedTypeIds = useMemo(() => {
    const ids = new Set<string>()
    for (const a of assignments) {
      const sk = skillMap.find((s) => s.id === a.skill_id)
      if (sk?.skill_type_id) ids.add(sk.skill_type_id)
    }
    return [...ids]
  }, [assignments, skillMap])

  const { data: levelsForAssigned = [] } = useSkillLevelsByTypeIds(assignedTypeIds)

  const assignedSkillIds = new Set(assignments.map((a) => a.skill_id))
  const availableSkills = skills.filter((s) => s.id && !assignedSkillIds.has(s.id))

  const skillNameById = useMemo(() => {
    const m = new Map<string, string>()
    for (const s of skillMap) {
      if (s.id) m.set(s.id, s.name ?? s.id)
    }
    return m
  }, [skillMap])

  const levelNameById = useMemo(() => {
    const m = new Map<string, string>()
    for (const lv of levelsForAssigned) {
      if (lv.id) m.set(lv.id, lv.name ?? lv.id)
    }
    return m
  }, [levelsForAssigned])

  async function onAdd() {
    if (!activeTenant?.id || !skillId) return
    try {
      await upsert.mutateAsync({
        tenant_id: activeTenant.id,
        employee_id: employeeId,
        skill_id: skillId,
        level_id: levelId || null,
      })
      setSkillId('')
      setLevelId('')
      toast({ title: t('employees.skills.assigned', 'Skill assignada') })
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.skills.assign_failed', "No s'ha pogut assignar"),
        description: e instanceof Error ? e.message : undefined,
      })
    }
  }

  if (isLoading) {
    return (
      <div className="flex justify-center py-10">
        <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
      </div>
    )
  }

  return (
    <div className="space-y-4 max-w-2xl">
      <div className="flex items-center justify-between gap-2">
        <div>
          <h3 className="text-sm font-semibold">{t('employees.skills.tab_title', 'Skills i talent')}</h3>
          <p className="text-xs text-muted-foreground">
            {t('employees.skills.tab_hint', 'Capacitats internes. Independent del compliment.')}
          </p>
        </div>
        <Link to="/employees/skills" className="text-xs text-primary hover:underline">
          {t('employees.skills.open_catalog', 'Obrir catàleg')}
        </Link>
      </div>

      <ul className="space-y-2">
        {assignments.length === 0 ? (
          <li className="text-sm text-muted-foreground">{t('employees.skills.none', 'Sense skills assignades')}</li>
        ) : (
          assignments.map((a) => (
            <li
              key={a.id!}
              className="flex items-center justify-between gap-2 rounded-lg border px-3 py-2 text-sm"
            >
              <span>
                {skillNameById.get(a.skill_id!) ?? a.skill_id}
                {a.level_id && levelNameById.get(a.level_id) ? (
                  <span className="text-muted-foreground"> · {levelNameById.get(a.level_id)}</span>
                ) : null}
                {a.notes ? <span className="text-muted-foreground"> — {a.notes}</span> : null}
              </span>
              {canManage ? (
                <Button
                  type="button"
                  variant="ghost"
                  size="icon"
                  className="h-8 w-8"
                  onClick={async () => {
                    try {
                      await remove.mutateAsync(a.id!)
                      toast({ title: t('employees.skills.removed', 'Skill treta') })
                    } catch (e) {
                      toast({
                        variant: 'destructive',
                        title: t('employees.skills.remove_failed', "No s'ha pogut treure"),
                        description: e instanceof Error ? e.message : undefined,
                      })
                    }
                  }}
                >
                  <Trash2 className="h-4 w-4" />
                </Button>
              ) : null}
            </li>
          ))
        )}
      </ul>

      {canManage ? (
        <div className="rounded-lg border p-3 space-y-2">
          <select
            className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
            value={typeId}
            onChange={(e) => {
              setTypeId(e.target.value)
              setSkillId('')
              setLevelId('')
            }}
          >
            <option value="">{t('employees.skills.select_type', 'Selecciona un tipus')}</option>
            {types.map((ty) => (
              <option key={ty.id!} value={ty.id!}>
                {ty.name}
              </option>
            ))}
          </select>
          <select
            className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
            value={skillId}
            disabled={!typeId}
            onChange={(e) => setSkillId(e.target.value)}
          >
            <option value="">{t('employees.skills.select_skill', 'Selecciona skill')}</option>
            {availableSkills.map((sk) => (
              <option key={sk.id!} value={sk.id!}>
                {sk.name}
              </option>
            ))}
          </select>
          <select
            className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
            value={levelId}
            disabled={!typeId}
            onChange={(e) => setLevelId(e.target.value)}
          >
            <option value="">{t('employees.skills.select_level', 'Nivell (opcional)')}</option>
            {levels.map((lv) => (
              <option key={lv.id!} value={lv.id!}>
                {lv.rank}. {lv.name}
              </option>
            ))}
          </select>
          <Button type="button" size="sm" disabled={!skillId || upsert.isPending} onClick={() => void onAdd()}>
            {upsert.isPending ? <Loader2 className="h-4 w-4 animate-spin mr-1" /> : <Plus className="h-4 w-4 mr-1" />}
            {t('employees.skills.assign', 'Assignar')}
          </Button>
        </div>
      ) : null}
    </div>
  )
}
