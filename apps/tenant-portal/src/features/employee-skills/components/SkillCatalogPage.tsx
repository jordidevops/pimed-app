import { useEffect, useMemo, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useQuery } from '@tanstack/react-query'
import {
  AlertTriangle,
  BarChart3,
  Check,
  Loader2,
  Pencil,
  Plus,
  Search,
  Sparkles,
  Trash2,
  X,
} from 'lucide-react'
import {
  Bar,
  BarChart,
  CartesianGrid,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { usePermission } from '@/hooks/usePermission'
import { fetchAiUserAccess } from '@/features/ai/api/aiRpc'
import { aiUserAccessQueryKey } from '@/features/ai/api/aiQueryKeys'
import { EmployeeAvatar } from '@/features/employees/components/EmployeePhotoUploader'
import {
  useCreateSkill,
  useCreateSkillLevel,
  useCreateSkillType,
  useDeleteSkill,
  useDeleteSkillLevel,
  useDeleteSkillType,
  useEmployeeSkillsSummary,
  useSearchEmployeesBySkills,
  useSkillLevels,
  useSkills,
  useSkillTypes,
  useUpdateSkill,
  useUpdateSkillLevel,
  useUpdateSkillType,
} from '../api/useSkills'
import type { SkillSearchCriterion, SkillSearchHit, SkillSearchMatchMode } from '../api/skillsService'
import {
  clearSkillsSearchSession,
  loadSkillsSearchSession,
  saveSkillsSearchSession,
} from '../utils/skillsSearchSession'

type PageTab = 'search' | 'catalog' | 'overview'

type DeleteTarget =
  | { kind: 'type'; id: string; name: string | null }
  | { kind: 'skill'; id: string; name: string | null }
  | { kind: 'level'; id: string; name: string | null }

type DraftCriterion = {
  key: string
  skillId: string
  minLevelRank: string
}

function newDraftCriterion(): DraftCriterion {
  return { key: crypto.randomUUID(), skillId: '', minLevelRank: '' }
}

function TalentHitCard({ hit }: { hit: SkillSearchHit }) {
  const name = hit.preferred_name?.trim() || hit.full_name || '—'
  return (
    <Link
      to={`/employees/${hit.employee_id}`}
      className="group flex flex-col gap-3 rounded-xl border bg-card p-4 hover:border-primary/40 hover:shadow-sm transition-all"
    >
      <div className="flex items-start gap-3">
        <EmployeeAvatar
          fullName={hit.full_name}
          preferredName={hit.preferred_name}
          photoObjectPath={hit.photo_object_path}
          size="lg"
        />
        <div className="min-w-0 flex-1">
          <p className="font-semibold text-foreground truncate group-hover:text-primary">{name}</p>
          {hit.job_position_name ? (
            <p className="text-sm text-muted-foreground truncate">{hit.job_position_name}</p>
          ) : null}
          {hit.site_name ? (
            <p className="text-xs text-muted-foreground truncate mt-0.5">{hit.site_name}</p>
          ) : null}
        </div>
      </div>
      <div className="flex flex-wrap gap-1.5">
        {(hit.matched_skills ?? []).map((ms) => (
          <span
            key={ms.skill_id}
            className="inline-flex items-center rounded-md bg-primary/10 text-primary px-2 py-0.5 text-xs font-medium"
          >
            {ms.skill_name}
            {ms.level_name ? (
              <span className="text-primary/70 font-normal"> · {ms.level_name}</span>
            ) : null}
          </span>
        ))}
      </div>
    </Link>
  )
}

function KpiTile({ label, value, hint }: { label: string; value: string | number; hint?: string }) {
  return (
    <div className="min-w-[7.5rem] flex-1 rounded-xl border px-4 py-3">
      <p className="text-xs font-medium text-muted-foreground">{label}</p>
      <p className="text-2xl font-semibold tabular-nums text-foreground mt-0.5">{value}</p>
      {hint ? <p className="text-xs text-muted-foreground mt-1">{hint}</p> : null}
    </div>
  )
}

export function SkillCatalogPage() {
  const { t } = useTranslation('employees')
  const navigate = useNavigate()
  const { toast } = useToast()
  const { activeTenant, sites = [] } = useTenant()
  const canManage = usePermission('employees.skills.manage')
  const canUseAi = usePermission('ai.use')

  const [tab, setTab] = useState<PageTab>('search')
  const [matchMode, setMatchMode] = useState<SkillSearchMatchMode>('and')
  const [siteFilter, setSiteFilter] = useState('')
  const [drafts, setDrafts] = useState<DraftCriterion[]>([newDraftCriterion()])
  const [searchArmed, setSearchArmed] = useState(false)
  const [searchSessionReady, setSearchSessionReady] = useState(false)

  useEffect(() => {
    if (!activeTenant?.id) {
      setSearchSessionReady(false)
      return
    }
    const saved = loadSkillsSearchSession(activeTenant.id)
    if (saved) {
      setDrafts(saved.drafts)
      setMatchMode(saved.matchMode)
      setSiteFilter(saved.siteFilter)
      setSearchArmed(saved.searchArmed)
    } else {
      setDrafts([newDraftCriterion()])
      setMatchMode('and')
      setSiteFilter('')
      setSearchArmed(false)
    }
    setSearchSessionReady(true)
  }, [activeTenant?.id])

  useEffect(() => {
    if (!activeTenant?.id || !searchSessionReady) return
    saveSkillsSearchSession(activeTenant.id, {
      drafts,
      matchMode,
      siteFilter,
      searchArmed,
    })
  }, [activeTenant?.id, drafts, matchMode, siteFilter, searchArmed, searchSessionReady])

  function clearSearch() {
    setDrafts([newDraftCriterion()])
    setMatchMode('and')
    setSiteFilter('')
    setSearchArmed(false)
    if (activeTenant?.id) clearSkillsSearchSession(activeTenant.id)
  }

  const { data: types = [], isLoading: typesLoading, error: typesError } = useSkillTypes(false)
  const { data: allSkills = [], error: skillsError } = useSkills(null, true)

  const criteria: SkillSearchCriterion[] = useMemo(() => {
    const map = new Map<string, SkillSearchCriterion>()
    for (const d of drafts) {
      if (!d.skillId) continue
      map.set(d.skillId, {
        skill_id: d.skillId,
        min_level_rank: d.minLevelRank === '' ? null : Number(d.minLevelRank),
      })
    }
    return [...map.values()]
  }, [drafts])

  const {
    data: hits = [],
    isFetching: searching,
    isError: searchError,
    error: searchErr,
    refetch: refetchSearch,
  } = useSearchEmployeesBySkills({
    criteria,
    matchMode,
    siteId: siteFilter || null,
    enabled: searchArmed && criteria.length > 0,
  })

  const { data: summary, isLoading: summaryLoading, error: summaryError } = useEmployeeSkillsSummary(
    siteFilter || null,
  )

  const { data: aiAccess } = useQuery({
    queryKey: aiUserAccessQueryKey(activeTenant?.id ?? ''),
    queryFn: () => fetchAiUserAccess(activeTenant!.id),
    enabled: !!activeTenant?.id && canUseAi,
  })
  const showAi = canUseAi && !!aiAccess && !aiAccess.blocked && aiAccess.configured

  const [selectedTypeId, setSelectedTypeId] = useState('')
  const { data: catalogSkills = [] } = useSkills(selectedTypeId || null, false)
  const { data: catalogLevels = [] } = useSkillLevels(selectedTypeId || null)
  const createType = useCreateSkillType()
  const updateType = useUpdateSkillType()
  const deleteType = useDeleteSkillType()
  const createSkill = useCreateSkill()
  const updateSkillMut = useUpdateSkill()
  const deleteSkillMut = useDeleteSkill()
  const createLevel = useCreateSkillLevel()
  const updateLevel = useUpdateSkillLevel()
  const deleteLevel = useDeleteSkillLevel()
  const [typeName, setTypeName] = useState('')
  const [skillName, setSkillName] = useState('')
  const [levelName, setLevelName] = useState('')
  const [levelRank, setLevelRank] = useState('1')
  const [editingTypeId, setEditingTypeId] = useState<string | null>(null)
  const [editingTypeName, setEditingTypeName] = useState('')
  const [editingSkillId, setEditingSkillId] = useState<string | null>(null)
  const [editingSkillName, setEditingSkillName] = useState('')
  const [editingLevelId, setEditingLevelId] = useState<string | null>(null)
  const [editingLevelName, setEditingLevelName] = useState('')
  const [editingLevelRank, setEditingLevelRank] = useState('')
  const [deleteTarget, setDeleteTarget] = useState<DeleteTarget | null>(null)
  const [deletePending, setDeletePending] = useState(false)

  const selectedType = useMemo(
    () => types.find((x) => x.id === selectedTypeId) ?? null,
    [types, selectedTypeId],
  )

  const skillById = useMemo(() => {
    const m = new Map<string, (typeof allSkills)[number]>()
    for (const s of allSkills) {
      if (s.id) m.set(s.id, s)
    }
    return m
  }, [allSkills])

  const coverageChart = useMemo(() => {
    const rows = summary?.coverage_by_skill ?? []
    return rows
      .slice()
      .sort((a, b) => b.employee_count - a.employee_count)
      .slice(0, 12)
      .map((r) => ({ label: r.skill_name, count: r.employee_count }))
  }, [summary])

  function runSearch() {
    if (criteria.length === 0) {
      toast({
        variant: 'destructive',
        title: t('employees.skills.search_need_criteria', 'Afegeix almenys una skill'),
      })
      return
    }
    setSearchArmed(true)
    void refetchSearch()
  }

  function openAiPrompt(prompt: string) {
    navigate('/ai/chat', { state: { draft: prompt } })
  }

  async function onCreateType() {
    if (!activeTenant?.id || !typeName.trim()) return
    try {
      const row = await createType.mutateAsync({
        tenant_id: activeTenant.id,
        name: typeName.trim(),
      })
      setTypeName('')
      if (row.id) setSelectedTypeId(row.id)
      toast({ title: t('employees.skills.type_created', 'Tipus creat') })
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.skills.save_failed', "No s'ha pogut desar"),
        description: e instanceof Error ? e.message : undefined,
      })
    }
  }

  async function onCreateSkill() {
    if (!activeTenant?.id || !selectedTypeId || !skillName.trim()) return
    try {
      await createSkill.mutateAsync({
        tenant_id: activeTenant.id,
        skill_type_id: selectedTypeId,
        name: skillName.trim(),
      })
      setSkillName('')
      toast({ title: t('employees.skills.skill_created', 'Skill creada') })
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.skills.save_failed', "No s'ha pogut desar"),
        description: e instanceof Error ? e.message : undefined,
      })
    }
  }

  async function onCreateLevel() {
    if (!selectedTypeId || !levelName.trim()) return
    try {
      await createLevel.mutateAsync({
        skill_type_id: selectedTypeId,
        name: levelName.trim(),
        rank: Number(levelRank) || 0,
        is_default: catalogLevels.length === 0,
      })
      setLevelName('')
      toast({ title: t('employees.skills.level_created', 'Nivell creat') })
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.skills.save_failed', "No s'ha pogut desar"),
        description: e instanceof Error ? e.message : undefined,
      })
    }
  }

  async function onSaveType(id: string) {
    if (!editingTypeName.trim()) return
    try {
      await updateType.mutateAsync({ id, name: editingTypeName.trim() })
      setEditingTypeId(null)
      toast({ title: t('employees.skills.type_updated', 'Tipus actualitzat') })
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.skills.save_failed', "No s'ha pogut desar"),
        description: e instanceof Error ? e.message : undefined,
      })
    }
  }

  async function onSaveSkill(id: string) {
    if (!editingSkillName.trim()) return
    try {
      await updateSkillMut.mutateAsync({ id, name: editingSkillName.trim() })
      setEditingSkillId(null)
      toast({ title: t('employees.skills.skill_updated', 'Skill actualitzada') })
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.skills.save_failed', "No s'ha pogut desar"),
        description: e instanceof Error ? e.message : undefined,
      })
    }
  }

  async function onSaveLevel(id: string) {
    if (!editingLevelName.trim()) return
    try {
      await updateLevel.mutateAsync({
        id,
        name: editingLevelName.trim(),
        rank: Number(editingLevelRank) || 0,
      })
      setEditingLevelId(null)
      toast({ title: t('employees.skills.level_updated', 'Nivell actualitzat') })
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.skills.save_failed', "No s'ha pogut desar"),
        description: e instanceof Error ? e.message : undefined,
      })
    }
  }

  async function onDeleteType(id: string, name: string | null) {
    setDeleteTarget({ kind: 'type', id, name })
  }

  async function onDeleteSkill(id: string, name: string | null) {
    setDeleteTarget({ kind: 'skill', id, name })
  }

  async function onDeleteLevel(id: string, name: string | null) {
    setDeleteTarget({ kind: 'level', id, name })
  }

  async function confirmDelete() {
    if (!deleteTarget) return
    setDeletePending(true)
    try {
      if (deleteTarget.kind === 'type') {
        await deleteType.mutateAsync(deleteTarget.id)
        if (selectedTypeId === deleteTarget.id) setSelectedTypeId('')
        toast({ title: t('employees.skills.type_deleted', 'Tipus eliminat') })
      } else if (deleteTarget.kind === 'skill') {
        await deleteSkillMut.mutateAsync(deleteTarget.id)
        toast({ title: t('employees.skills.skill_deleted', 'Skill eliminada') })
      } else {
        await deleteLevel.mutateAsync(deleteTarget.id)
        toast({ title: t('employees.skills.level_deleted', 'Nivell eliminat') })
      }
      setDeleteTarget(null)
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.skills.delete_failed', "No s'ha pogut eliminar"),
        description: e instanceof Error ? e.message : undefined,
      })
    } finally {
      setDeletePending(false)
    }
  }

  const deleteConfirmCopy = (() => {
    const name = deleteTarget?.name ?? deleteTarget?.id ?? ''
    if (deleteTarget?.kind === 'type') {
      return {
        title: t('employees.skills.type_delete_title', 'Eliminar tipus?'),
        body: t(
          'employees.skills.type_delete_confirm',
          'Eliminar el tipus «{{name}}»? També s’eliminaran skills, nivells i assignacions relacionades.',
          { name },
        ),
      }
    }
    if (deleteTarget?.kind === 'skill') {
      return {
        title: t('employees.skills.skill_delete_title', 'Eliminar skill?'),
        body: t(
          'employees.skills.skill_delete_confirm',
          'Eliminar la skill «{{name}}»? També s’eliminaran les assignacions als empleats.',
          { name },
        ),
      }
    }
    return {
      title: t('employees.skills.level_delete_title', 'Eliminar nivell?'),
      body: t(
        'employees.skills.level_delete_confirm',
        'Eliminar el nivell «{{name}}»? Les assignacions que l’usaven quedaran sense nivell.',
        { name },
      ),
    }
  })()

  const tabs: { id: PageTab; label: string }[] = [
    { id: 'search', label: t('employees.skills.tab_search', 'Cerca de talent') },
    { id: 'catalog', label: t('employees.skills.tab_catalog', 'Catàleg') },
    { id: 'overview', label: t('employees.skills.tab_overview', 'Overview') },
  ]

  return (
    <div className="max-w-5xl mx-auto px-4 py-8 space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="flex items-start gap-3">
          <div className="h-11 w-11 rounded-2xl bg-primary/10 flex items-center justify-center shrink-0">
            <Sparkles className="h-5 w-5 text-primary" />
          </div>
          <div>
            <h1 className="text-2xl font-bold tracking-tight">
              {t('employees.skills.catalog_title', 'Skills (talent)')}
            </h1>
            <p className="text-sm text-muted-foreground mt-1 max-w-xl">
              {t(
                'employees.skills.catalog_subtitle',
                'Catàleg intern de capacitats. No afecta compliment ni Readiness.',
              )}
            </p>
          </div>
        </div>
        <Link to="/employees" className="text-sm text-primary hover:underline">
          {t('employees.skills.back', 'Tornar a empleats')}
        </Link>
      </div>

      <div className="flex gap-1 border-b">
        {tabs.map((tb) => (
          <button
            key={tb.id}
            type="button"
            onClick={() => setTab(tb.id)}
            className={`px-4 py-2.5 text-sm font-medium border-b-2 -mb-px transition-colors ${
              tab === tb.id
                ? 'border-primary text-primary'
                : 'border-transparent text-muted-foreground hover:text-foreground'
            }`}
          >
            {tb.label}
          </button>
        ))}
      </div>

      {tab === 'search' ? (
        <div className="space-y-5">
          <section className="rounded-2xl border bg-card/50 p-5 space-y-4">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div>
                <h2 className="text-sm font-semibold flex items-center gap-2">
                  <Search className="h-4 w-4" />
                  {t('employees.skills.search_builder_title', 'Qui pot fer la tasca?')}
                </h2>
                <p className="text-xs text-muted-foreground mt-0.5">
                  {t(
                    'employees.skills.search_builder_hint',
                    'Combina skills i nivell mínim. AND = totes; OR = qualsevol.',
                  )}
                </p>
              </div>
              <div className="flex flex-wrap items-center gap-2">
                <div className="inline-flex rounded-lg border p-0.5">
                  <button
                    type="button"
                    className={`px-3 py-1 text-xs font-medium rounded-md ${
                      matchMode === 'and' ? 'bg-primary text-primary-foreground' : 'text-muted-foreground'
                    }`}
                    onClick={() => setMatchMode('and')}
                  >
                    AND
                  </button>
                  <button
                    type="button"
                    className={`px-3 py-1 text-xs font-medium rounded-md ${
                      matchMode === 'or' ? 'bg-primary text-primary-foreground' : 'text-muted-foreground'
                    }`}
                    onClick={() => setMatchMode('or')}
                  >
                    OR
                  </button>
                </div>
                <select
                  className="rounded-md border border-input bg-background px-3 py-1.5 text-sm"
                  value={siteFilter}
                  onChange={(e) => setSiteFilter(e.target.value)}
                >
                  <option value="">{t('employees.skills.all_sites', 'Tots els sites')}</option>
                  {sites.map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.name}
                    </option>
                  ))}
                </select>
              </div>
            </div>

            <div className="space-y-2">
              {drafts.map((d) => (
                <SkillCriterionRow
                  key={d.key}
                  draft={d}
                  allSkills={allSkills}
                  skillById={skillById}
                  onChange={(next) =>
                    setDrafts((prev) => prev.map((x) => (x.key === d.key ? next : x)))
                  }
                  onRemove={() =>
                    setDrafts((prev) => (prev.length <= 1 ? prev : prev.filter((x) => x.key !== d.key)))
                  }
                  canRemove={drafts.length > 1}
                />
              ))}
            </div>

            <div className="flex flex-wrap gap-2">
              <Button
                type="button"
                variant="outline"
                size="sm"
                onClick={() => setDrafts((prev) => [...prev, newDraftCriterion()])}
              >
                <Plus className="h-4 w-4 mr-1" />
                {t('employees.skills.add_criterion', 'Afegir criteri')}
              </Button>
              <Button type="button" size="sm" onClick={runSearch} disabled={searching}>
                {searching ? (
                  <Loader2 className="h-4 w-4 animate-spin mr-1" />
                ) : (
                  <Search className="h-4 w-4 mr-1" />
                )}
                {t('employees.skills.run_search', 'Cercar')}
              </Button>
              <Button
                type="button"
                variant="ghost"
                size="sm"
                onClick={clearSearch}
                disabled={
                  drafts.length === 1 &&
                  !drafts[0]?.skillId &&
                  !siteFilter &&
                  matchMode === 'and' &&
                  !searchArmed
                }
              >
                <X className="h-4 w-4 mr-1" />
                {t('employees.skills.clear_search', 'Netejar')}
              </Button>
            </div>
          </section>

          <section
            className={`rounded-xl border border-dashed p-4 space-y-2 ${showAi ? '' : 'opacity-70'}`}
          >
            <p className="text-xs font-medium text-muted-foreground flex items-center gap-1.5">
              <Sparkles className="h-3.5 w-3.5" />
              {t('employees.skills.ai_prompts', 'Assistència IA')}
            </p>
            {!showAi && (!canUseAi || aiAccess) ? (
              <p className="text-xs text-muted-foreground">
                {!canUseAi || aiAccess?.blocked
                  ? t(
                      'employees.skills.ai_unavailable_no_access',
                      "No tens accés a la IA. Contacta amb l'administrador.",
                    )
                  : t(
                      'employees.skills.ai_unavailable_not_configured',
                      'La IA no està configurada. Activa-la a Configuració → IA.',
                    )}
              </p>
            ) : null}
            <div className="flex flex-wrap gap-2">
              <Button
                type="button"
                variant="secondary"
                size="sm"
                disabled={!showAi}
                onClick={() =>
                  openAiPrompt(
                    t(
                      'employees.skills.ai_prompt_who',
                      'Qui dels empleats actius té millor combinació de skills tècniques per una tasca d’instal·lació elèctrica amb lectura de plànols?',
                    ),
                  )
                }
              >
                {t('employees.skills.ai_btn_who', 'Qui pot fer X? (exemple)')}
              </Button>
              <Button
                type="button"
                variant="secondary"
                size="sm"
                disabled={!showAi}
                onClick={() =>
                  openAiPrompt(
                    t(
                      'employees.skills.ai_prompt_gaps',
                      'Quines skills del catàleg de talent tenen baixa cobertura o nivell mitjà baix? Què hauríem de potenciar?',
                    ),
                  )
                }
              >
                {t('employees.skills.ai_btn_gaps', 'Skills febles')}
              </Button>
            </div>
          </section>

          {searchError ? (
            <div className="rounded-lg border border-destructive/40 bg-destructive/5 px-4 py-3 text-sm text-destructive flex gap-2">
              <AlertTriangle className="h-4 w-4 shrink-0 mt-0.5" />
              <span>
                {t('employees.skills.search_error', 'Error a la cerca')}
                {searchErr instanceof Error ? `: ${searchErr.message}` : ''}
              </span>
            </div>
          ) : null}

          {searchArmed && !searching && !searchError ? (
            hits.length === 0 ? (
              <p className="text-sm text-muted-foreground py-6 text-center">
                {t('employees.skills.search_empty', 'Cap empleat amb aquests criteris')}
              </p>
            ) : (
              <div className="grid gap-3 sm:grid-cols-2">
                {hits.map((h) => (
                  <TalentHitCard key={h.employee_id} hit={h} />
                ))}
              </div>
            )
          ) : null}
        </div>
      ) : null}

      {tab === 'catalog' ? (
        typesLoading ? (
          <div className="flex justify-center py-10">
            <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
          </div>
        ) : typesError || skillsError ? (
          <div className="rounded-lg border border-destructive/40 bg-destructive/5 px-4 py-3 text-sm text-destructive">
            {t('employees.skills.load_error', 'No s’ha pogut carregar el catàleg.')}
            {typesError instanceof Error ? ` ${typesError.message}` : ''}
          </div>
        ) : (
          <div className="grid gap-6 lg:grid-cols-2">
            <section className="space-y-3 rounded-xl border p-4">
              <h2 className="text-sm font-semibold">{t('employees.skills.types', 'Tipus')}</h2>
              <ul className="space-y-1 max-h-56 overflow-y-auto">
                {types.map((ty) => (
                  <li key={ty.id!} className="group flex items-center gap-1">
                    {editingTypeId === ty.id ? (
                      <>
                        <Input
                          className="h-8 text-sm flex-1"
                          value={editingTypeName}
                          onChange={(e) => setEditingTypeName(e.target.value)}
                          onKeyDown={(e) => {
                            if (e.key === 'Enter') void onSaveType(ty.id!)
                            if (e.key === 'Escape') setEditingTypeId(null)
                          }}
                          autoFocus
                        />
                        <Button
                          type="button"
                          variant="ghost"
                          size="icon"
                          className="h-8 w-8 shrink-0"
                          onClick={() => void onSaveType(ty.id!)}
                        >
                          <Check className="h-4 w-4" />
                        </Button>
                      </>
                    ) : (
                      <>
                        <button
                          type="button"
                          className={`flex-1 min-w-0 text-left text-sm rounded-md px-2 py-1.5 ${
                            selectedTypeId === ty.id ? 'bg-primary/10 text-primary' : 'hover:bg-muted'
                          }`}
                          onClick={() => setSelectedTypeId(ty.id!)}
                        >
                          {ty.name}
                          {!ty.is_active ? (
                            <span className="text-xs text-muted-foreground"> · inactiu</span>
                          ) : null}
                        </button>
                        {canManage ? (
                          <div className="flex shrink-0 opacity-70 group-hover:opacity-100">
                            <Button
                              type="button"
                              variant="ghost"
                              size="icon"
                              className="h-8 w-8"
                              onClick={() => {
                                setEditingTypeId(ty.id!)
                                setEditingTypeName(ty.name ?? '')
                              }}
                            >
                              <Pencil className="h-3.5 w-3.5" />
                            </Button>
                            <Button
                              type="button"
                              variant="ghost"
                              size="icon"
                              className="h-8 w-8 text-destructive"
                              onClick={() => void onDeleteType(ty.id!, ty.name)}
                            >
                              <Trash2 className="h-3.5 w-3.5" />
                            </Button>
                          </div>
                        ) : null}
                      </>
                    )}
                  </li>
                ))}
                {types.length === 0 ? (
                  <li className="text-xs text-muted-foreground">
                    {t('employees.skills.empty_types', 'Cap tipus')}
                  </li>
                ) : null}
              </ul>
              {canManage ? (
                <div className="flex gap-2">
                  <Input
                    value={typeName}
                    onChange={(e) => setTypeName(e.target.value)}
                    placeholder={t('employees.skills.type_placeholder', 'Nou tipus')}
                  />
                  <Button type="button" size="sm" disabled={!typeName.trim()} onClick={() => void onCreateType()}>
                    <Plus className="h-4 w-4" />
                  </Button>
                </div>
              ) : null}
            </section>

            <section className="space-y-3 rounded-xl border p-4">
              <h2 className="text-sm font-semibold">
                {selectedType
                  ? t('employees.skills.for_type', 'Catàleg: {{name}}', { name: selectedType.name })
                  : t('employees.skills.select_type', 'Selecciona un tipus')}
              </h2>
              {selectedTypeId ? (
                <>
                  <div>
                    <p className="text-xs text-muted-foreground mb-1">{t('employees.skills.levels', 'Nivells')}</p>
                    <ul className="text-sm space-y-1 mb-2">
                      {catalogLevels.map((lv) => (
                        <li key={lv.id!} className="group flex items-center gap-1">
                          {editingLevelId === lv.id ? (
                            <>
                              <Input
                                className="w-16 h-8"
                                value={editingLevelRank}
                                onChange={(e) => setEditingLevelRank(e.target.value)}
                                placeholder="rank"
                              />
                              <Input
                                className="h-8 text-sm flex-1"
                                value={editingLevelName}
                                onChange={(e) => setEditingLevelName(e.target.value)}
                                onKeyDown={(e) => {
                                  if (e.key === 'Enter') void onSaveLevel(lv.id!)
                                  if (e.key === 'Escape') setEditingLevelId(null)
                                }}
                                autoFocus
                              />
                              <Button
                                type="button"
                                variant="ghost"
                                size="icon"
                                className="h-8 w-8"
                                onClick={() => void onSaveLevel(lv.id!)}
                              >
                                <Check className="h-4 w-4" />
                              </Button>
                            </>
                          ) : (
                            <>
                              <span className="flex-1 px-1 py-0.5">
                                {lv.rank}. {lv.name}
                                {lv.is_default ? ' ★' : ''}
                              </span>
                              {canManage ? (
                                <div className="flex shrink-0 opacity-70 group-hover:opacity-100">
                                  <Button
                                    type="button"
                                    variant="ghost"
                                    size="icon"
                                    className="h-8 w-8"
                                    onClick={() => {
                                      setEditingLevelId(lv.id!)
                                      setEditingLevelName(lv.name ?? '')
                                      setEditingLevelRank(String(lv.rank ?? 0))
                                    }}
                                  >
                                    <Pencil className="h-3.5 w-3.5" />
                                  </Button>
                                  <Button
                                    type="button"
                                    variant="ghost"
                                    size="icon"
                                    className="h-8 w-8 text-destructive"
                                    onClick={() => void onDeleteLevel(lv.id!, lv.name)}
                                  >
                                    <Trash2 className="h-3.5 w-3.5" />
                                  </Button>
                                </div>
                              ) : null}
                            </>
                          )}
                        </li>
                      ))}
                    </ul>
                    {canManage ? (
                      <div className="flex gap-2 mb-3">
                        <Input
                          value={levelName}
                          onChange={(e) => setLevelName(e.target.value)}
                          placeholder={t('employees.skills.level_placeholder', 'Nivell')}
                        />
                        <Input
                          className="w-20"
                          value={levelRank}
                          onChange={(e) => setLevelRank(e.target.value)}
                          placeholder="rank"
                        />
                        <Button
                          type="button"
                          size="sm"
                          disabled={!levelName.trim()}
                          onClick={() => void onCreateLevel()}
                        >
                          <Plus className="h-4 w-4" />
                        </Button>
                      </div>
                    ) : null}
                  </div>
                  <div>
                    <p className="text-xs text-muted-foreground mb-1">{t('employees.skills.skills', 'Skills')}</p>
                    <ul className="text-sm space-y-1 mb-2">
                      {catalogSkills.map((sk) => (
                        <li key={sk.id!} className="group flex items-center gap-1">
                          {editingSkillId === sk.id ? (
                            <>
                              <Input
                                className="h-8 text-sm flex-1"
                                value={editingSkillName}
                                onChange={(e) => setEditingSkillName(e.target.value)}
                                onKeyDown={(e) => {
                                  if (e.key === 'Enter') void onSaveSkill(sk.id!)
                                  if (e.key === 'Escape') setEditingSkillId(null)
                                }}
                                autoFocus
                              />
                              <Button
                                type="button"
                                variant="ghost"
                                size="icon"
                                className="h-8 w-8"
                                onClick={() => void onSaveSkill(sk.id!)}
                              >
                                <Check className="h-4 w-4" />
                              </Button>
                            </>
                          ) : (
                            <>
                              <span className="flex-1 px-1 py-0.5">{sk.name}</span>
                              {canManage ? (
                                <div className="flex shrink-0 opacity-70 group-hover:opacity-100">
                                  <Button
                                    type="button"
                                    variant="ghost"
                                    size="icon"
                                    className="h-8 w-8"
                                    onClick={() => {
                                      setEditingSkillId(sk.id!)
                                      setEditingSkillName(sk.name ?? '')
                                    }}
                                  >
                                    <Pencil className="h-3.5 w-3.5" />
                                  </Button>
                                  <Button
                                    type="button"
                                    variant="ghost"
                                    size="icon"
                                    className="h-8 w-8 text-destructive"
                                    onClick={() => void onDeleteSkill(sk.id!, sk.name)}
                                  >
                                    <Trash2 className="h-3.5 w-3.5" />
                                  </Button>
                                </div>
                              ) : null}
                            </>
                          )}
                        </li>
                      ))}
                      {catalogSkills.length === 0 ? (
                        <li className="text-xs text-muted-foreground">
                          {t('employees.skills.empty_skills', 'Cap skill')}
                        </li>
                      ) : null}
                    </ul>
                    {canManage ? (
                      <div className="flex gap-2">
                        <Input
                          value={skillName}
                          onChange={(e) => setSkillName(e.target.value)}
                          placeholder={t('employees.skills.skill_placeholder', 'Nova skill')}
                        />
                        <Button
                          type="button"
                          size="sm"
                          disabled={!skillName.trim()}
                          onClick={() => void onCreateSkill()}
                        >
                          <Plus className="h-4 w-4" />
                        </Button>
                      </div>
                    ) : null}
                  </div>
                </>
              ) : null}
            </section>
          </div>
        )
      ) : null}

      {tab === 'overview' ? (
        summaryLoading ? (
          <div className="flex justify-center py-10">
            <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
          </div>
        ) : summaryError ? (
          <div className="rounded-lg border border-destructive/40 bg-destructive/5 px-4 py-3 text-sm text-destructive">
            {t('employees.skills.summary_error', 'No s’ha pogut carregar l’overview.')}
          </div>
        ) : summary ? (
          <div className="space-y-6">
            <div className="flex flex-wrap gap-3">
              <KpiTile
                label={t('employees.skills.kpi_headcount', 'Headcount visible')}
                value={summary.kpis.headcount_visible}
              />
              <KpiTile
                label={t('employees.skills.kpi_with_skills', 'Amb ≥1 skill')}
                value={summary.kpis.employees_with_skills}
                hint={`${summary.kpis.coverage_pct}%`}
              />
              <KpiTile
                label={t('employees.skills.kpi_catalog', 'Skills al catàleg')}
                value={summary.kpis.skills_in_catalog}
              />
              <KpiTile
                label={t('employees.skills.kpi_assignments', 'Assignacions')}
                value={summary.kpis.assignments}
              />
            </div>

            <section className="rounded-xl border p-4">
              <h3 className="text-sm font-semibold flex items-center gap-2 mb-3">
                <BarChart3 className="h-4 w-4" />
                {t('employees.skills.chart_coverage', 'Cobertura per skill (top 12)')}
              </h3>
              {coverageChart.length === 0 ? (
                <p className="text-sm text-muted-foreground">{t('employees.skills.no_chart', 'Sense dades')}</p>
              ) : (
                <div className="h-64 w-full">
                  <ResponsiveContainer width="100%" height="100%">
                    <BarChart data={coverageChart} margin={{ left: 0, right: 8, top: 8, bottom: 48 }}>
                      <CartesianGrid strokeDasharray="3 3" className="stroke-border" />
                      <XAxis dataKey="label" angle={-35} textAnchor="end" interval={0} height={60} tick={{ fontSize: 11 }} />
                      <YAxis allowDecimals={false} tick={{ fontSize: 11 }} />
                      <Tooltip />
                      <Bar dataKey="count" name={t('employees.skills.employees', 'Empleats')} fill="hsl(var(--primary))" radius={[4, 4, 0, 0]} />
                    </BarChart>
                  </ResponsiveContainer>
                </div>
              )}
            </section>

            <section className="rounded-xl border p-4 space-y-2">
              <h3 className="text-sm font-semibold">
                {t('employees.skills.gaps_title', 'Habilitats a potenciar')}
              </h3>
              <p className="text-xs text-muted-foreground">
                {t(
                  'employees.skills.gaps_hint',
                  'Pocs titulars (<2) o nivell mitjà baix (<2). Insight per formació interna; sense LMS.',
                )}
              </p>
              {(summary.gaps ?? []).length === 0 ? (
                <p className="text-sm text-muted-foreground py-2">
                  {t('employees.skills.gaps_empty', 'Cap gap destacat')}
                </p>
              ) : (
                <ul className="divide-y">
                  {summary.gaps.slice(0, 20).map((g) => (
                    <li key={g.skill_id} className="flex items-center justify-between gap-3 py-2.5 text-sm">
                      <div className="min-w-0">
                        <p className="font-medium truncate">{g.skill_name}</p>
                        <p className="text-xs text-muted-foreground">
                          {g.skill_type_name} · {g.employee_count}{' '}
                          {t('employees.skills.employees', 'empleats')} · avg {g.avg_rank}
                          {g.reason === 'low_coverage'
                            ? ` · ${t('employees.skills.gap_low_coverage', 'poca cobertura')}`
                            : ` · ${t('employees.skills.gap_low_rank', 'nivell baix')}`}
                        </p>
                      </div>
                      <Button
                        type="button"
                        variant="ghost"
                        size="sm"
                        onClick={() => {
                          setDrafts([
                            {
                              key: crypto.randomUUID(),
                              skillId: g.skill_id,
                              minLevelRank: '',
                            },
                          ])
                          setSearchArmed(true)
                          setTab('search')
                        }}
                      >
                        {t('employees.skills.gap_search', 'Cercar')}
                      </Button>
                    </li>
                  ))}
                </ul>
              )}
            </section>
          </div>
        ) : null
      ) : null}
      <Dialog
        open={deleteTarget !== null}
        onOpenChange={(open) => {
          if (!open && !deletePending) setDeleteTarget(null)
        }}
      >
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>{deleteConfirmCopy.title}</DialogTitle>
            <DialogDescription>{deleteConfirmCopy.body}</DialogDescription>
          </DialogHeader>
          <DialogFooter className="gap-2">
            <Button
              type="button"
              variant="outline"
              disabled={deletePending}
              onClick={() => setDeleteTarget(null)}
            >
              {t('employees.skills.cancel', 'Cancel·lar')}
            </Button>
            <Button
              type="button"
              variant="destructive"
              disabled={deletePending}
              onClick={() => void confirmDelete()}
            >
              {deletePending ? (
                <>
                  <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                  {t('employees.skills.deleting', 'Eliminant…')}
                </>
              ) : (
                t('employees.skills.delete', 'Eliminar')
              )}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}

function SkillCriterionRow({
  draft,
  allSkills,
  skillById,
  onChange,
  onRemove,
  canRemove,
}: {
  draft: DraftCriterion
  allSkills: Array<{ id: string | null; name: string | null; skill_type_id: string | null }>
  skillById: Map<string, { id: string | null; skill_type_id: string | null }>
  onChange: (next: DraftCriterion) => void
  onRemove: () => void
  canRemove: boolean
}) {
  const { t } = useTranslation('employees')
  const typeId = skillById.get(draft.skillId)?.skill_type_id ?? null
  const { data: levels = [] } = useSkillLevels(typeId)

  return (
    <div className="flex flex-wrap items-center gap-2 rounded-lg border bg-background p-2">
      <select
        className="flex-1 min-w-[10rem] rounded-md border border-input bg-background px-3 py-2 text-sm"
        value={draft.skillId}
        onChange={(e) =>
          onChange({ ...draft, skillId: e.target.value, minLevelRank: '' })
        }
      >
        <option value="">{t('employees.skills.select_skill', 'Selecciona skill')}</option>
        {allSkills.map((sk) => (
          <option key={sk.id!} value={sk.id!}>
            {sk.name}
          </option>
        ))}
      </select>
      <select
        className="w-44 rounded-md border border-input bg-background px-3 py-2 text-sm"
        value={draft.minLevelRank}
        disabled={!draft.skillId}
        onChange={(e) => onChange({ ...draft, minLevelRank: e.target.value })}
      >
        <option value="">{t('employees.skills.any_level', 'Qualsevol nivell')}</option>
        {levels.map((lv) => (
          <option key={lv.id!} value={String(lv.rank ?? 0)}>
            {`>= ${lv.rank}. ${lv.name}`}
          </option>
        ))}
      </select>
      {canRemove ? (
        <Button type="button" variant="ghost" size="icon" className="h-9 w-9" onClick={onRemove}>
          <Trash2 className="h-4 w-4" />
        </Button>
      ) : (
        <span className="w-9" />
      )}
    </div>
  )
}
