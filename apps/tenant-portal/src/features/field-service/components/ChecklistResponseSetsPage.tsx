import { useMemo, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router-dom'
import { ArrowLeft, Copy, ListChecks, Plus } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import {
  clonePlatformResponseSet,
  createTenantResponseSet,
  listPlatformResponseSets,
  listTenantResponseSetsDetailed,
  setTenantResponseSetActive,
  updateTenantResponseSet,
  type AnswerSemantic,
  type ChecklistLocale,
  type TenantResponseSetDetail,
} from '../api/checklistTemplatesService'

const SEMANTICS: AnswerSemantic[] = ['pass', 'warning', 'fail', 'na', 'neutral']
const COLORS = ['green', 'yellow', 'orange', 'red', 'neutral'] as const

type OptionDraft = {
  key: string
  id: string | null
  label: string
  semantics: AnswerSemantic
  blocks_closeout: boolean
  requires_note: boolean
  color_token: string
  locked: boolean
}

type FormState = {
  name: string
  code: string
  locale: ChecklistLocale
  category: string
  vertical: string
  is_active: boolean
  published_locked: boolean
  options: OptionDraft[]
}

let seq = 0
function nextKey() {
  seq += 1
  return `o-${seq}`
}

function emptyOption(partial?: Partial<OptionDraft>): OptionDraft {
  return {
    key: nextKey(),
    id: null,
    label: '',
    semantics: 'pass',
    blocks_closeout: false,
    requires_note: false,
    color_token: 'green',
    locked: false,
    ...partial,
  }
}

function emptyForm(): FormState {
  return {
    name: '',
    code: '',
    locale: 'ca',
    category: 'general',
    vertical: 'generic',
    is_active: true,
    published_locked: false,
    options: [
      emptyOption({ label: 'Conforme', semantics: 'pass', color_token: 'green' }),
      emptyOption({
        label: 'No conforme',
        semantics: 'fail',
        blocks_closeout: true,
        requires_note: true,
        color_token: 'red',
      }),
    ],
  }
}

function formFromSet(set: TenantResponseSetDetail): FormState {
  return {
    name: set.name,
    code: set.code ?? '',
    locale: set.locale,
    category: set.category,
    vertical: set.vertical,
    is_active: set.is_active,
    published_locked: set.published_locked,
    options: set.options.map((opt) => ({
      key: opt.id,
      id: opt.id,
      label: opt.label,
      semantics: opt.semantics,
      blocks_closeout: opt.blocks_closeout,
      requires_note: opt.requires_note,
      color_token: opt.color_token ?? 'neutral',
      locked: opt.locked,
    })),
  }
}

export function ChecklistResponseSetsPage() {
  const { t } = useTranslation('field-service')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const queryClient = useQueryClient()
  const tenantId = activeTenant?.id

  const [tab, setTab] = useState<'tenant' | 'platform'>('tenant')
  const [includeInactive, setIncludeInactive] = useState(false)
  const [editingId, setEditingId] = useState<string | null>(null)
  const [formOpen, setFormOpen] = useState(false)
  const [form, setForm] = useState<FormState>(emptyForm())
  const [saving, setSaving] = useState(false)

  const tenantQuery = useQuery({
    queryKey: ['checklist_response_sets_detailed', tenantId, includeInactive],
    queryFn: () => listTenantResponseSetsDetailed(tenantId!, includeInactive),
    enabled: !!tenantId,
  })

  const platformQuery = useQuery({
    queryKey: ['checklist_response_sets_platform_all'],
    queryFn: () => listPlatformResponseSets(),
  })

  const tenantSets = tenantQuery.data ?? []
  const platformSets = platformQuery.data ?? []

  const semanticHint = useMemo(
    () => ({
      pass: t('response_sets.hint_pass', 'OK. No bloqueja el tancament.'),
      warning: t('response_sets.hint_warning', 'Avís. Per defecte no bloqueja.'),
      fail: t('response_sets.hint_fail', 'No conforme. Bloqueja el tancament de la visita.'),
      na: t('response_sets.hint_na', 'No aplicable.'),
      neutral: t('response_sets.hint_neutral', 'Neutre.'),
    }),
    [t],
  )

  async function invalidate() {
    await queryClient.invalidateQueries({ queryKey: ['checklist_response_sets'] })
    await queryClient.invalidateQueries({ queryKey: ['checklist_response_sets_detailed'] })
    await queryClient.invalidateQueries({ queryKey: ['checklist_response_sets_platform_all'] })
  }

  function openCreate() {
    setEditingId(null)
    setForm(emptyForm())
    setFormOpen(true)
  }

  function openEdit(set: TenantResponseSetDetail) {
    setEditingId(set.id)
    setForm(formFromSet(set))
    setFormOpen(true)
  }

  async function handleSave() {
    if (!tenantId) return
    setSaving(true)
    try {
      const payload = {
        name: form.name,
        code: form.code || null,
        locale: form.locale,
        category: form.category,
        vertical: form.vertical,
        is_active: form.is_active,
        options: form.options.map((opt, index) => ({
          id: opt.id,
          label: opt.label,
          semantics: opt.semantics,
          position: index,
          blocks_closeout: opt.blocks_closeout,
          requires_note: opt.requires_note,
          color_token: opt.color_token,
        })),
      }
      if (editingId) await updateTenantResponseSet(tenantId, editingId, payload)
      else await createTenantResponseSet(tenantId, payload)
      await invalidate()
      setFormOpen(false)
      toast({ description: t('response_sets.saved', 'Conjunt desat') })
    } catch {
      toast({
        variant: 'destructive',
        description: t('response_sets.save_failed', 'No s\'ha pogut desar el conjunt'),
      })
    } finally {
      setSaving(false)
    }
  }

  async function handleClone(sourceId: string) {
    if (!tenantId) return
    setSaving(true)
    try {
      await clonePlatformResponseSet(sourceId, tenantId)
      await invalidate()
      setTab('tenant')
      toast({ description: t('response_sets.cloned', 'Conjunt clonat al teu catàleg') })
    } catch {
      toast({
        variant: 'destructive',
        description: t('response_sets.clone_failed', 'No s\'ha pogut clonar'),
      })
    } finally {
      setSaving(false)
    }
  }

  async function handleToggleActive(set: TenantResponseSetDetail) {
    if (!tenantId) return
    try {
      await setTenantResponseSetActive(tenantId, set.id, !set.is_active)
      await invalidate()
      toast({
        description: set.is_active
          ? t('response_sets.deactivated', 'Conjunt desactivat')
          : t('response_sets.activated', 'Conjunt activat'),
      })
    } catch {
      toast({
        variant: 'destructive',
        description: t('response_sets.save_failed', 'No s\'ha pogut desar el conjunt'),
      })
    }
  }

  return (
    <div className="mx-auto max-w-5xl space-y-6 px-4 py-6 pb-24">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <Link
            to="/field/more"
            className="mb-2 inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground"
          >
            <ArrowLeft className="h-4 w-4" />
            {t('more.title', 'Més')}
          </Link>
          <h1 className="flex items-center gap-2 text-2xl font-bold">
            <ListChecks className="h-6 w-6" />
            {t('response_sets.title', 'Conjunts de respostes')}
          </h1>
          <p className="mt-1 max-w-2xl text-sm text-muted-foreground">
            {t(
              'response_sets.subtitle',
              'Defineix les escales (Conforme/No conforme, semàfor…) i la semàntica de cada opció.',
            )}
          </p>
        </div>
        <Button className="gap-1" onClick={openCreate}>
          <Plus className="h-4 w-4" />
          {t('response_sets.new', 'Nou conjunt')}
        </Button>
      </div>

      <Tabs value={tab} onValueChange={(v) => setTab(v as 'tenant' | 'platform')}>
        <TabsList>
          <TabsTrigger value="tenant">{t('response_sets.tab_tenant', 'Els teus')}</TabsTrigger>
          <TabsTrigger value="platform">{t('response_sets.tab_platform', 'Plataforma')}</TabsTrigger>
        </TabsList>

        <TabsContent value="tenant" className="mt-4 space-y-3">
          <label className="flex items-center gap-2 text-sm text-muted-foreground">
            <input
              type="checkbox"
              checked={includeInactive}
              onChange={(e) => setIncludeInactive(e.target.checked)}
            />
            {t('response_sets.include_inactive', 'Incloure inactius')}
          </label>

          {tenantQuery.isLoading ? (
            <p className="text-sm text-muted-foreground">{t('response_sets.loading', 'Carregant…')}</p>
          ) : tenantSets.length === 0 ? (
            <p className="rounded-lg border border-dashed border-border px-4 py-8 text-center text-sm text-muted-foreground">
              {t('response_sets.empty', 'Encara no tens conjunts propis. Crea’n un o clona de plataforma.')}
            </p>
          ) : (
            <ul className="space-y-2">
              {tenantSets.map((set) => (
                <li
                  key={set.id}
                  className="flex flex-wrap items-start justify-between gap-3 rounded-xl border border-border bg-card p-3"
                >
                  <div className="min-w-0 space-y-1">
                    <p className="font-medium">
                      {set.name}
                      {!set.is_active && (
                        <Badge variant="outline" className="ml-2 text-[10px]">
                          {t('response_sets.inactive', 'Inactiu')}
                        </Badge>
                      )}
                    </p>
                    <div className="flex flex-wrap gap-1">
                      {set.options.map((opt) => (
                        <Badge key={opt.id} variant="secondary" className="text-[10px] font-normal">
                          {opt.label}
                        </Badge>
                      ))}
                    </div>
                  </div>
                  <div className="flex gap-2">
                    <Button size="sm" variant="outline" onClick={() => openEdit(set)}>
                      {t('response_sets.edit', 'Editar')}
                    </Button>
                    <Button size="sm" variant="ghost" onClick={() => void handleToggleActive(set)}>
                      {set.is_active
                        ? t('response_sets.deactivate', 'Desactivar')
                        : t('response_sets.activate', 'Activar')}
                    </Button>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </TabsContent>

        <TabsContent value="platform" className="mt-4 space-y-3">
          <p className="text-xs text-muted-foreground">
            {t(
              'response_sets.platform_hint',
              'Només lectura. Clona un conjunt per personalitzar-lo al teu tenant.',
            )}
          </p>
          {platformQuery.isLoading ? (
            <p className="text-sm text-muted-foreground">{t('response_sets.loading', 'Carregant…')}</p>
          ) : (
            <ul className="space-y-2">
              {platformSets.map((set) => (
                <li
                  key={set.id}
                  className="flex flex-wrap items-start justify-between gap-3 rounded-xl border border-border bg-card p-3"
                >
                  <div className="min-w-0 space-y-1">
                    <p className="font-medium">{set.name}</p>
                    <div className="flex flex-wrap gap-1">
                      {(set.options ?? []).map((opt) => (
                        <Badge key={opt.id} variant="secondary" className="text-[10px] font-normal">
                          {opt.label}
                        </Badge>
                      ))}
                    </div>
                  </div>
                  <Button
                    size="sm"
                    variant="outline"
                    className="gap-1"
                    disabled={saving}
                    onClick={() => void handleClone(set.id)}
                  >
                    <Copy className="h-3.5 w-3.5" />
                    {t('response_sets.clone', 'Clonar')}
                  </Button>
                </li>
              ))}
            </ul>
          )}
        </TabsContent>
      </Tabs>

      {formOpen && (
        <section className="space-y-4 rounded-2xl border border-border bg-card p-4 shadow-sm">
          <div className="flex items-center justify-between gap-2">
            <h2 className="text-base font-semibold">
              {editingId
                ? t('response_sets.edit_title', 'Editar conjunt')
                : t('response_sets.new', 'Nou conjunt')}
            </h2>
            <Button variant="ghost" size="sm" onClick={() => setFormOpen(false)}>
              {t('common:cancel', 'Cancel·lar')}
            </Button>
          </div>

          {form.published_locked && (
            <p className="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800 dark:border-amber-900 dark:bg-amber-950/40 dark:text-amber-200">
              {t(
                'response_sets.locked_hint',
                'Usat en plantilles publicades: les opcions existents són immutables. Pots afegir-ne de noves.',
              )}
            </p>
          )}

          <div className="grid gap-3 sm:grid-cols-2">
            <label className="space-y-1 text-sm sm:col-span-2">
              <span className="font-medium">{t('response_sets.name', 'Nom')}</span>
              <Input value={form.name} onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))} />
            </label>
            <label className="space-y-1 text-sm">
              <span className="font-medium">{t('response_sets.code', 'Codi')}</span>
              <Input value={form.code} onChange={(e) => setForm((f) => ({ ...f, code: e.target.value }))} />
            </label>
            <label className="space-y-1 text-sm">
              <span className="font-medium">{t('response_sets.locale', 'Idioma')}</span>
              <Select
                value={form.locale}
                onValueChange={(v) => setForm((f) => ({ ...f, locale: v as ChecklistLocale }))}
              >
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  <SelectItem value="ca">Català</SelectItem>
                  <SelectItem value="es">Castellà</SelectItem>
                  <SelectItem value="en">English</SelectItem>
                </SelectContent>
              </Select>
            </label>
          </div>

          <div className="space-y-2">
            <div className="flex items-center justify-between">
              <p className="text-sm font-medium">{t('response_sets.options', 'Opcions')}</p>
              <Button
                size="sm"
                variant="outline"
                onClick={() => setForm((f) => ({ ...f, options: [...f.options, emptyOption()] }))}
              >
                {t('response_sets.add_option', 'Afegir opció')}
              </Button>
            </div>

            {form.options.map((opt, index) => (
              <div key={opt.key} className="space-y-2 rounded-lg border border-border p-3">
                <div className="grid gap-2 sm:grid-cols-3">
                  <Input
                    value={opt.label}
                    disabled={opt.locked}
                    placeholder={t('response_sets.option_label', 'Etiqueta')}
                    onChange={(e) =>
                      setForm((f) => ({
                        ...f,
                        options: f.options.map((o, i) =>
                          i === index ? { ...o, label: e.target.value } : o,
                        ),
                      }))
                    }
                  />
                  <Select
                    value={opt.semantics}
                    disabled={opt.locked}
                    onValueChange={(v) =>
                      setForm((f) => ({
                        ...f,
                        options: f.options.map((o, i) =>
                          i === index ? { ...o, semantics: v as AnswerSemantic } : o,
                        ),
                      }))
                    }
                  >
                    <SelectTrigger><SelectValue /></SelectTrigger>
                    <SelectContent>
                      {SEMANTICS.map((s) => (
                        <SelectItem key={s} value={s}>
                          {s}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <Select
                    value={opt.color_token}
                    disabled={opt.locked}
                    onValueChange={(v) =>
                      setForm((f) => ({
                        ...f,
                        options: f.options.map((o, i) =>
                          i === index ? { ...o, color_token: v } : o,
                        ),
                      }))
                    }
                  >
                    <SelectTrigger><SelectValue /></SelectTrigger>
                    <SelectContent>
                      {COLORS.map((c) => (
                        <SelectItem key={c} value={c}>
                          {c}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
                <p className="text-[11px] text-muted-foreground">{semanticHint[opt.semantics]}</p>
                <div className="flex flex-wrap items-center gap-3 text-xs">
                  <label className="flex items-center gap-1.5">
                    <input
                      type="checkbox"
                      checked={opt.blocks_closeout}
                      disabled={opt.locked}
                      onChange={(e) =>
                        setForm((f) => ({
                          ...f,
                          options: f.options.map((o, i) =>
                            i === index ? { ...o, blocks_closeout: e.target.checked } : o,
                          ),
                        }))
                      }
                    />
                    {t('response_sets.blocks_closeout', 'Bloqueja closeout')}
                  </label>
                  <label className="flex items-center gap-1.5">
                    <input
                      type="checkbox"
                      checked={opt.requires_note}
                      disabled={opt.locked}
                      onChange={(e) =>
                        setForm((f) => ({
                          ...f,
                          options: f.options.map((o, i) =>
                            i === index ? { ...o, requires_note: e.target.checked } : o,
                          ),
                        }))
                      }
                    />
                    {t('response_sets.requires_note', 'Requereix nota')}
                  </label>
                  {opt.locked && (
                    <Badge variant="outline" className="text-[10px]">
                      {t('response_sets.option_locked', 'Bloquejada')}
                    </Badge>
                  )}
                  {!opt.locked && form.options.length > 1 && (
                    <Button
                      size="sm"
                      variant="ghost"
                      className="text-destructive"
                      onClick={() =>
                        setForm((f) => ({
                          ...f,
                          options: f.options.filter((_, i) => i !== index),
                        }))
                      }
                    >
                      {t('response_sets.remove_option', 'Treure')}
                    </Button>
                  )}
                </div>
              </div>
            ))}
          </div>

          <div className="flex justify-end gap-2">
            <Button variant="outline" onClick={() => setFormOpen(false)} disabled={saving}>
              {t('common:cancel', 'Cancel·lar')}
            </Button>
            <Button onClick={() => void handleSave()} disabled={saving || !form.name.trim()}>
              {t('response_sets.save', 'Desar')}
            </Button>
          </div>
        </section>
      )}
    </div>
  )
}
