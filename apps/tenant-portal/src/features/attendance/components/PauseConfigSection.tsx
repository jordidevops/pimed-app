import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Info, Plus, Pencil, Check, X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Switch } from '@/components/ui/switch'
import { supabase } from '@/lib/supabase'
import { useToast } from '@/hooks/use-toast'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { usePauseConfigs, pauseLabel, type PauseConfig } from '../api/usePauseConfigs'
import { useTenant } from '@/contexts/TenantContext'

interface PauseFormState {
  key: string
  label: string
  label_i18n_extra: Record<string, string>
  counts_as_work: boolean
  default_duration_min: string
  max_duration_minutes: string
}

const emptyForm = (): PauseFormState => ({
  key: '',
  label: '',
  label_i18n_extra: {},
  counts_as_work: false,
  default_duration_min: '',
  max_duration_minutes: '',
})

function PauseForm({
  form,
  setForm,
  isPending,
  onSave,
  onCancel,
  t,
}: {
  form: PauseFormState
  setForm: (f: PauseFormState) => void
  isPending: boolean
  onSave: () => void
  onCancel: () => void
  t: ReturnType<typeof useTranslation>['t']
}) {
  return (
    <div className="space-y-2">
      <div className="grid grid-cols-2 gap-2">
        <div className="col-span-2">
          <label className="text-xs font-medium mb-0.5 block">
            {t('planificacio.pause_name', 'Nom')}
          </label>
          <input
            value={form.label}
            onChange={(e) =>
              setForm({
                ...form,
                label: e.target.value,
                key: form.key || e.target.value.toLowerCase().replace(/\s+/g, '_'),
              })
            }
            className="w-full border rounded px-2 py-1 text-xs bg-background"
            required
          />
        </div>
        <div>
          <label className="text-xs font-medium mb-0.5 block">
            {t('planificacio.pause_default_min', 'Durada per defecte (min)')}
          </label>
          <input
            type="number"
            min="1"
            value={form.default_duration_min}
            onChange={(e) => setForm({ ...form, default_duration_min: e.target.value })}
            className="w-full border rounded px-2 py-1 text-xs bg-background"
          />
        </div>
        <div>
          <label className="text-xs font-medium mb-0.5 block">
            {t('planificacio.pause_max_min', 'Durada màxima (min)')}
          </label>
          <input
            type="number"
            min="1"
            value={form.max_duration_minutes}
            onChange={(e) => setForm({ ...form, max_duration_minutes: e.target.value })}
            className="w-full border rounded px-2 py-1 text-xs bg-background"
          />
        </div>
      </div>
      <div className="flex items-center gap-2">
        <Switch
          id="counts-work"
          checked={form.counts_as_work}
          onCheckedChange={(v) => setForm({ ...form, counts_as_work: v })}
        />
        <label htmlFor="counts-work" className="text-xs cursor-pointer">
          {t('planificacio.counts_as_work', 'Compta com a temps treballat')}
        </label>
      </div>
      <div className="flex gap-2 justify-end">
        <button
          type="button"
          onClick={onCancel}
          className="px-2.5 py-1 text-xs rounded border hover:bg-accent"
        >
          <X className="h-3 w-3" />
        </button>
        <button
          type="button"
          disabled={isPending || !form.label}
          onClick={onSave}
          className="flex items-center gap-1 px-3 py-1 text-xs rounded bg-primary text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
        >
          <Check className="h-3 w-3" />
          {isPending ? t('planificacio.saving', 'Desant...') : t('planificacio.save', 'Desar')}
        </button>
      </div>
    </div>
  )
}

export function PauseConfigSection() {
  const { t, i18n } = useTranslation('attendance')
  const lang = i18n.language?.slice(0, 2) ?? 'ca'
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()
  const { data: pauseConfigs = [], isLoading } = usePauseConfigs()
  const [editing, setEditing] = useState<string | null>(null)
  const [showNew, setShowNew] = useState(false)
  const [form, setForm] = useState<PauseFormState>(emptyForm())

  const invalidatePauses = () => {
    void queryClient.invalidateQueries({
      queryKey: ['attendance', 'pause-configs', activeTenant?.id],
    })
  }

  const { mutate: save, isPending } = useMutation({
    mutationFn: async (cfg: PauseFormState & { id?: string }) => {
      const label_i18n = { ...cfg.label_i18n_extra }
      ;['ca', 'es', 'en', 'fr', 'de', 'pt', 'it'].forEach((l) => {
        if (!label_i18n[l] || l === lang) label_i18n[l] = cfg.label
      })
      const { error } = await supabase.rpc(
        'upsert_pause_config' as never,
        {
          p_key: cfg.key,
          p_label_i18n: label_i18n,
          p_counts_as_work: cfg.counts_as_work,
          p_max_duration_minutes: cfg.max_duration_minutes ? Number(cfg.max_duration_minutes) : null,
          p_default_duration_min: cfg.default_duration_min ? Number(cfg.default_duration_min) : null,
          p_is_active: true,
        } as never,
      )
      if (error) throw error
    },
    onSuccess: () => {
      invalidatePauses()
      toast({ title: t('planificacio.pause_saved', 'Pausa desada') })
      setEditing(null)
      setShowNew(false)
      setForm(emptyForm())
    },
    onError: (err: Error) => {
      toast({ title: err.message, variant: 'destructive' })
    },
  })

  const { mutate: applyTemplate, isPending: applyingTemplate } = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc(
        'apply_pause_config_template' as never,
        { p_archetype_key: 'generic' } as never,
      )
      if (error) throw error
    },
    onSuccess: () => {
      invalidatePauses()
      toast({
        title: t('planificacio.pause_template_applied', 'Plantilla de pauses aplicada'),
      })
    },
    onError: (err: Error) => {
      toast({ title: err.message, variant: 'destructive' })
    },
  })

  function startEdit(cfg: PauseConfig) {
    setEditing(cfg.id)
    setForm({
      key: cfg.key,
      label: pauseLabel(cfg, lang),
      label_i18n_extra: cfg.label_i18n ?? {},
      counts_as_work: cfg.counts_as_work,
      default_duration_min: '',
      max_duration_minutes: cfg.max_duration_minutes?.toString() ?? '',
    })
  }

  return (
    <section className="max-w-2xl">
      <div className="flex items-center justify-between mb-3">
        <div>
          <h3 className="text-sm font-semibold">{t('planificacio.tab_pauses', 'Tipus de pausa')}</h3>
          <p className="text-xs text-muted-foreground mt-0.5">
            {t(
              'planificacio.pauses_help',
              'Defineix els tipus de pausa que els empleats poden registrar al fitxar (dinar, descans, etc.).',
            )}
          </p>
        </div>
        <Button
          size="sm"
          variant="outline"
          onClick={() => {
            setShowNew(true)
            setEditing(null)
            setForm(emptyForm())
          }}
          className="gap-1 h-7 text-xs shrink-0"
        >
          <Plus className="h-3 w-3" />
          {t('planificacio.new_pause', 'Nova pausa')}
        </Button>
      </div>

      {isLoading ? (
        <p className="text-xs text-muted-foreground">{t('planificacio.loading_pauses', 'Carregant pauses…')}</p>
      ) : pauseConfigs.length === 0 && !showNew ? (
        <div className="rounded-lg border border-dashed p-6 text-center space-y-3">
          <p className="text-sm text-muted-foreground">
            {t(
              'planificacio.no_pauses',
              'Encara no hi ha cap tipus de pausa configurat per a aquesta organització.',
            )}
          </p>
          <Button
            size="sm"
            variant="secondary"
            disabled={applyingTemplate}
            onClick={() => applyTemplate()}
          >
            {t('planificacio.apply_pause_template', 'Aplicar plantilla per defecte')}
          </Button>
          <p className="text-[11px] text-muted-foreground">
            {t('planificacio.apply_pause_template_hint', 'Inclou esmorzar i dinar (arquetip genèric).')}
          </p>
        </div>
      ) : (
        <div className="space-y-2">
          {pauseConfigs.map((config) => (
            <div key={config.id} className="rounded-lg border p-3">
              {editing === config.id ? (
                <PauseForm
                  form={form}
                  setForm={setForm}
                  isPending={isPending}
                  onSave={() => save({ ...form, id: config.id })}
                  onCancel={() => {
                    setEditing(null)
                    setForm(emptyForm())
                  }}
                  t={t}
                />
              ) : (
                <div className="flex items-center gap-3">
                  <div className="flex-1 min-w-0">
                    <p className="font-medium text-sm">{pauseLabel(config, lang)}</p>
                    <p className="text-xs text-muted-foreground">
                      {config.counts_as_work
                        ? t('planificacio.counts_as_work', 'Compta com a temps treballat')
                        : t('planificacio.counts_as_break', 'No compta com a temps treballat')}
                      {config.max_duration_minutes ? ` · max ${config.max_duration_minutes} min` : ''}
                    </p>
                  </div>
                  <Switch
                    checked={config.counts_as_work}
                    onCheckedChange={(v) => {
                      save({
                        key: config.key,
                        label: pauseLabel(config, lang),
                        label_i18n_extra: config.label_i18n ?? {},
                        counts_as_work: v,
                        default_duration_min: '',
                        max_duration_minutes: config.max_duration_minutes?.toString() ?? '',
                      })
                    }}
                  />
                  <button
                    type="button"
                    onClick={() => startEdit(config)}
                    className="text-muted-foreground hover:text-foreground p-1"
                  >
                    <Pencil className="h-3.5 w-3.5" />
                  </button>
                </div>
              )}
            </div>
          ))}
          {showNew && (
            <div className="rounded-lg border p-3 bg-muted/30">
              <p className="text-xs font-medium text-muted-foreground mb-2">
                {t('planificacio.new_pause_form', 'Nova pausa')}
              </p>
              <PauseForm
                form={form}
                setForm={setForm}
                isPending={isPending}
                onSave={() => save(form)}
                onCancel={() => {
                  setShowNew(false)
                  setForm(emptyForm())
                }}
                t={t}
              />
            </div>
          )}
        </div>
      )}

      {pauseConfigs.length > 0 && (
        <div className="mt-4 flex items-start gap-2 rounded-md border bg-muted/30 px-3 py-2 text-xs text-muted-foreground">
          <Info className="mt-0.5 h-3.5 w-3.5 shrink-0" />
          <span>
            {t(
              'planificacio.pauses_visible_hint',
              'Els empleats veuen aquests botons a la pantalla de fitxatge quan estan treballant.',
            )}
          </span>
        </div>
      )}
    </section>
  )
}
