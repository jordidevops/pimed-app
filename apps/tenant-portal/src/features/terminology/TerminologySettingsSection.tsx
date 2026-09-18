import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { SaveIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useEffectiveSettings, useTenantSettingsMutation } from '@/hooks/useSettings'
import { usePermission } from '@/hooks/usePermission'
import { TERM_KEYS, TERM_MAX_LEN, termBadges, type TermKey } from './termCatalog'
import {
  resolveTerm,
  sanitizeTermValue,
  sanitizeTerminologyMap,
  termOrigin,
  type TermOrigin,
} from './resolveTerm'

const EMPTY_DRAFT: Record<TermKey, string> = {
  project: '',
  project_plural: '',
  contact: '',
  contacts: '',
  price_sheet: '',
}

export function TerminologySettingsSection() {
  const { t } = useTranslation('settings')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const canManage = usePermission('settings.manage', null)
  const tenantId = activeTenant?.id ?? null
  const { data: effective = {} } = useEffectiveSettings(
    { tenantId },
    { enabled: !!tenantId },
  )
  const mutation = useTenantSettingsMutation()
  const [draft, setDraft] = useState<Record<TermKey, string>>(EMPTY_DRAFT)

  const overlay = useMemo(
    () => sanitizeTerminologyMap(effective.terminology),
    [effective.terminology],
  )
  const sector = activeTenant?.sector_labels
  const archetype = activeTenant?.archetype ?? 'generic'

  useEffect(() => {
    setDraft({
      project: overlay.project ?? '',
      project_plural: overlay.project_plural ?? '',
      contact: overlay.contact ?? '',
      contacts: overlay.contacts ?? '',
      price_sheet: overlay.price_sheet ?? '',
    })
  }, [overlay])

  const errors = useMemo(() => {
    const next: Partial<Record<TermKey, string>> = {}
    for (const key of TERM_KEYS) {
      const value = draft[key]
      if (!value.trim()) continue
      if (!sanitizeTermValue(value)) {
        next[key] = t(
          'config.terminology.invalid',
          'Nom no vàlid (2–40 caràcters; no pot ser Pressupost, Albarà ni Factura).',
        )
      }
    }
    return next
  }, [draft, t])

  function i18nFallback(key: TermKey): string {
    if (key === 'price_sheet') return t('config.terminology.price_sheet_default', 'Full de preus')
    if (key === 'project_plural') return t('config.terminology.project_plural_default', 'Projectes')
    if (key === 'contacts') return t('config.terminology.contacts_default', 'Contactes')
    if (key === 'contact') return t('config.terminology.contact_default', 'Contacte')
    return t('config.terminology.project_default', 'Projecte')
  }

  function currentName(key: TermKey): string {
    return resolveTerm(key, { tenant: overlay, sector, fallback: i18nFallback(key) })
  }

  function originLabel(origin: TermOrigin): string {
    if (origin === 'tenant') {
      return t('config.terminology.source_tenant', "configurat per l'organització")
    }
    if (origin === 'sector') {
      return t('config.terminology.source_sector', 'nom del sector')
    }
    return t('config.terminology.source_platform', 'nom de la plataforma')
  }

  function inUseText(keys: TermKey[]): string {
    const parts = keys.map((key) => ({
      name: currentName(key),
      origin: termOrigin(key, { tenant: overlay, sector }),
    }))
    const sameOrigin = parts.every((part) => part.origin === parts[0]?.origin)
    if (parts.length === 2) {
      if (sameOrigin) {
        return t(
          'config.terminology.in_use_pair',
          'En ús ara: {{singular}} / {{plural}} · {{source}}',
          {
            singular: parts[0].name,
            plural: parts[1].name,
            source: originLabel(parts[0].origin),
          },
        )
      }
      return t(
        'config.terminology.in_use_pair_mixed',
        'En ús ara: {{singular}} ({{singularSource}}) · {{plural}} ({{pluralSource}})',
        {
          singular: parts[0].name,
          singularSource: originLabel(parts[0].origin),
          plural: parts[1].name,
          pluralSource: originLabel(parts[1].origin),
        },
      )
    }
    return t('config.terminology.in_use', 'En ús ara: {{name}} · {{source}}', {
      name: parts[0].name,
      source: originLabel(parts[0].origin),
    })
  }

  function handleSave() {
    if (Object.keys(errors).length > 0) return
    mutation.mutate(
      { terminology: sanitizeTerminologyMap(draft) },
      {
        onSuccess: () => {
          toast({ title: t('saved', 'Desat') })
        },
        onError: () => {
          toast({
            variant: 'destructive',
            title: t('error', 'Error en desar la configuració'),
          })
        },
      },
    )
  }

  function handleRestore() {
    mutation.mutate(
      { terminology: {} },
      {
        onSuccess: () => {
          setDraft(EMPTY_DRAFT)
          toast({ title: t('config.terminology.restored', 'S’han restaurat els noms del sector') })
        },
        onError: () => {
          toast({
            variant: 'destructive',
            title: t('error', 'Error en desar la configuració'),
          })
        },
      },
    )
  }

  function renderField(key: TermKey, label: string) {
    return (
      <div className="space-y-2 min-w-0">
        <label className="text-sm font-medium text-foreground" htmlFor={`term-${key}`}>
          {label}
        </label>
        <Input
          id={`term-${key}`}
          value={draft[key]}
          maxLength={TERM_MAX_LEN}
          placeholder={currentName(key)}
          disabled={!canManage || mutation.isPending}
          onChange={(e) => setDraft((prev) => ({ ...prev, [key]: e.target.value }))}
        />
        <div className="space-y-1">
          <p className="text-xs text-muted-foreground">
            {t('config.terminology.suggestions', 'Suggeriments')}
          </p>
          <div className="flex flex-wrap gap-1.5">
            {termBadges(key, archetype).map((badge) => (
              <button
                key={badge}
                type="button"
                disabled={!canManage || mutation.isPending}
                onClick={() => setDraft((prev) => ({ ...prev, [key]: badge }))}
                className="rounded-full border border-dashed border-border bg-background px-2.5 py-0.5 text-xs text-muted-foreground hover:bg-muted hover:text-foreground disabled:opacity-50"
              >
                {badge}
              </button>
            ))}
          </div>
        </div>
        {errors[key] && <p className="text-xs text-destructive">{errors[key]}</p>}
      </div>
    )
  }

  return (
    <section className="rounded-2xl border bg-card p-6 space-y-5">
      <div className="space-y-0.5">
        <div className="flex items-center gap-2">
          <h2 className="text-base font-semibold text-foreground">
            {t('config.terminology.title', 'Noms a l’aplicació')}
          </h2>
          <span className="inline-flex items-center gap-1 rounded-full bg-muted text-muted-foreground text-xs font-medium px-2 py-0.5">
            Tenant
          </span>
        </div>
        <p className="text-sm text-muted-foreground">
          {t(
            'config.terminology.description',
            'Canvia com es diuen el projecte i el contacte. El camp buit deixa el nom del sector. Els xips són només suggeriments.',
          )}
        </p>
      </div>

      <div className="space-y-4">
        <div className="rounded-xl border bg-muted/20 p-4 space-y-3">
          <div className="space-y-1">
            <h3 className="text-sm font-semibold text-foreground">
              {t('config.terminology.group_project', 'Projecte')}
            </h3>
            <p className="text-xs text-muted-foreground">{inUseText(['project', 'project_plural'])}</p>
          </div>
          <div className="grid gap-4 sm:grid-cols-2">
            {renderField('project', t('config.terminology.singular', 'Singular'))}
            {renderField('project_plural', t('config.terminology.plural', 'Plural'))}
          </div>
        </div>

        <div className="rounded-xl border bg-muted/20 p-4 space-y-3">
          <div className="space-y-1">
            <h3 className="text-sm font-semibold text-foreground">
              {t('config.terminology.group_contact', 'Contacte')}
            </h3>
            <p className="text-xs text-muted-foreground">{inUseText(['contact', 'contacts'])}</p>
          </div>
          <div className="grid gap-4 sm:grid-cols-2">
            {renderField('contact', t('config.terminology.singular', 'Singular'))}
            {renderField('contacts', t('config.terminology.plural', 'Plural'))}
          </div>
        </div>

        <div className="rounded-xl border bg-muted/20 p-4 space-y-3">
          <div className="space-y-1">
            <h3 className="text-sm font-semibold text-foreground">
              {t('config.terminology.group_price_sheet', 'Full de preus')}
            </h3>
            <p className="text-xs text-muted-foreground">{inUseText(['price_sheet'])}</p>
          </div>
          {renderField(
            'price_sheet',
            t('config.terminology.price_sheet', 'Títol intern de la secció'),
          )}
          <p className="text-xs text-muted-foreground">
            {t(
              'config.terminology.price_sheet_help',
              'Només el títol intern de la secció. El client continua veient el pressupost.',
            )}
          </p>
        </div>
      </div>

      {canManage && (
        <div className="flex flex-wrap justify-end gap-2 pt-2 border-t">
          <Button
            size="sm"
            variant="outline"
            onClick={handleRestore}
            disabled={mutation.isPending}
          >
            {t('config.terminology.restore', 'Restaura els noms del sector')}
          </Button>
          <Button
            size="sm"
            onClick={handleSave}
            disabled={mutation.isPending || Object.keys(errors).length > 0}
          >
            <SaveIcon className="h-4 w-4 mr-1.5" />
            {mutation.isPending ? t('saving', 'Desant...') : t('save', 'Desar')}
          </Button>
        </div>
      )}
    </section>
  )
}
