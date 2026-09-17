import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { SaveIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useTenant } from '@/contexts/TenantContext'
import { useEffectiveSettings, useTenantSettingsMutation } from '@/hooks/useSettings'
import { useToast } from '@/hooks/use-toast'
import { useDocumentTemplates } from '@/features/signing/api/useDocumentTemplates'
import {
  COMMERCIAL_DELIVERY_NOTE_TEMPLATE_ID_KEY,
  COMMERCIAL_QUOTE_TEMPLATE_ID_KEY,
  commercialSettingsPatchWithFullBodyTemplates,
  commercialSettingsPatchWithThreshold,
  parseCommercialSettingId,
  parseDeviationApprovalThresholdEur,
} from '@/features/commercial/utils/deviationApprovalThreshold'

const NONE = ''

export function CommercialDocumentTemplatesSection() {
  const { t } = useTranslation('settings')
  const { toast } = useToast()
  const { activeTenant, activeRole } = useTenant()
  const tenantId = activeTenant?.id ?? ''
  const canManage = activeRole === 'owner' || activeRole === 'manager'

  const { data: effective } = useEffectiveSettings(
    { tenantId },
    { enabled: !!tenantId },
  )
  const { data: templates = [] } = useDocumentTemplates(tenantId || undefined)
  const mutation = useTenantSettingsMutation()

  const [quoteId, setQuoteId] = useState(NONE)
  const [deliveryId, setDeliveryId] = useState(NONE)

  const ownQuotes = useMemo(
    () =>
      templates.filter(
        (tpl) =>
          !tpl.is_platform_default &&
          tpl.tenant_id === tenantId &&
          tpl.category === 'quote',
      ),
    [templates, tenantId],
  )
  const ownDeliveryNotes = useMemo(
    () =>
      templates.filter(
        (tpl) =>
          !tpl.is_platform_default &&
          tpl.tenant_id === tenantId &&
          tpl.category === 'delivery_note',
      ),
    [templates, tenantId],
  )

  useEffect(() => {
    setQuoteId(parseCommercialSettingId(effective, COMMERCIAL_QUOTE_TEMPLATE_ID_KEY) ?? NONE)
    setDeliveryId(
      parseCommercialSettingId(effective, COMMERCIAL_DELIVERY_NOTE_TEMPLATE_ID_KEY) ?? NONE,
    )
  }, [effective])

  async function handleSave() {
    try {
      await mutation.mutateAsync(
        commercialSettingsPatchWithFullBodyTemplates(effective?.commercial, {
          quote_template_id: quoteId || null,
          delivery_note_template_id: deliveryId || null,
        }),
      )
      toast({ description: t('templates.commercial_saved', 'Plantilles comercials desades') })
    } catch (err) {
      toast({
        variant: 'destructive',
        description:
          err instanceof Error
            ? err.message
            : t('templates.commercial_save_error', 'No s’han pogut desar les plantilles comercials'),
      })
    }
  }

  if (!canManage) return null

  return (
    <section className="rounded-2xl border bg-card p-6 space-y-5">
      <div className="space-y-1">
        <h3 className="text-base font-semibold">
          {t('templates.commercial_title', 'Plantilles comercials actives')}
        </h3>
        <p className="text-sm text-muted-foreground">
          {t(
            'templates.commercial_help',
            'Si n’hi ha una d’activa, s’usa com a format del pressupost o l’albarà. Si no en configureu cap, el sistema usa el format per defecte (no editable).',
          )}
        </p>
        <p className="text-xs text-muted-foreground">
          {t(
            'templates.commercial_none_help',
            '«Cap» deixa el selector sense preferència explícita: s’usa la plantilla pròpia més antiga d’aquesta categoria, o el format per defecte si no n’hi ha cap. Clona una plantilla de sistema a Documents → Plantilles abans de triar-la aquí.',
          )}
        </p>
      </div>

      <div className="space-y-4">
        <label className="flex flex-col gap-1.5">
          <span className="text-sm font-medium">
            {t('templates.commercial_quote', 'Plantilla de pressupost activa')}
          </span>
          <select
            className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm"
            value={quoteId}
            onChange={(e) => setQuoteId(e.target.value)}
            disabled={mutation.isPending}
          >
            <option value={NONE}>
              {t('templates.commercial_none', 'Cap (usar format per defecte)')}
            </option>
            {ownQuotes.map((tpl) => (
              <option key={tpl.id ?? tpl.name} value={tpl.id ?? ''}>
                {tpl.name}
                {tpl.template_type === 'docx'
                  ? ` (${t('templates.commercial_type_docx', 'DOCX')})`
                  : ` (${t('templates.commercial_type_html', 'HTML')})`}
              </option>
            ))}
          </select>
        </label>

        <label className="flex flex-col gap-1.5">
          <span className="text-sm font-medium">
            {t('templates.commercial_delivery', "Plantilla d'albarà activa")}
          </span>
          <select
            className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm"
            value={deliveryId}
            onChange={(e) => setDeliveryId(e.target.value)}
            disabled={mutation.isPending}
          >
            <option value={NONE}>
              {t('templates.commercial_none', 'Cap (usar format per defecte)')}
            </option>
            {ownDeliveryNotes.map((tpl) => (
              <option key={tpl.id ?? tpl.name} value={tpl.id ?? ''}>
                {tpl.name}
                {tpl.template_type === 'docx'
                  ? ` (${t('templates.commercial_type_docx', 'DOCX')})`
                  : ` (${t('templates.commercial_type_html', 'HTML')})`}
              </option>
            ))}
          </select>
        </label>
      </div>

      <p className="text-xs text-muted-foreground">
        {t('templates.category.quote', 'Pressupost')} / {t('templates.category.delivery_note', 'Albarà')}
        {' · '}
        <Link to="/documents/templates" className="underline underline-offset-2 hover:text-foreground">
          {t('templates.commercial_open_catalog', 'Obrir catàleg de plantilles')}
        </Link>
      </p>

      <div className="flex justify-end pt-2 border-t">
        <Button size="sm" onClick={() => void handleSave()} disabled={mutation.isPending}>
          <SaveIcon className="h-4 w-4 mr-1.5" />
          {mutation.isPending
            ? t('saving', 'Desant...')
            : t('save', 'Desar')}
        </Button>
      </div>
    </section>
  )
}

export function CommercialDeviationThresholdSection() {
  const { t } = useTranslation('settings')
  const { activeTenant, activeRole } = useTenant()
  const tenantId = activeTenant?.id ?? ''
  const canManage = activeRole === 'owner' || activeRole === 'manager'
  const { data: effective } = useEffectiveSettings(
    { tenantId },
    { enabled: !!tenantId },
  )
  const mutation = useTenantSettingsMutation()
  const deviationThreshold = parseDeviationApprovalThresholdEur(effective)
  const [thresholdDraft, setThresholdDraft] = useState<string | null>(null)
  const thresholdInput = thresholdDraft ?? String(deviationThreshold)

  if (!canManage) return null

  return (
    <section className="rounded-2xl border bg-card p-6 space-y-3">
      <h3 className="text-base font-semibold">
        {t('templates.deviation_title', 'Ampliacions de pressupost')}
      </h3>
      <label className="flex flex-col gap-1.5">
        <span className="text-sm font-medium">
          {t('templates.deviation_threshold', 'Llindar d’aprovació d’ampliacions (€)')}
        </span>
        <Input
          type="number"
          min="0"
          step="1"
          className="h-10"
          value={thresholdInput}
          disabled={mutation.isPending}
          onChange={(e) => setThresholdDraft(e.target.value)}
          onBlur={() => {
            const parsed = Number(thresholdDraft ?? deviationThreshold)
            const next = Number.isFinite(parsed) && parsed >= 0 ? parsed : 0
            setThresholdDraft(null)
            if (next === deviationThreshold) return
            void mutation.mutateAsync(
              commercialSettingsPatchWithThreshold(effective?.commercial, next),
            )
          }}
          aria-describedby="deviation-threshold-help"
        />
        <span id="deviation-threshold-help" className="text-xs text-muted-foreground">
          {t(
            'templates.deviation_threshold_help',
            'Si el sobrecost supera aquest import, el tècnic només pot proposar l’ampliació i l’oficina l’ha d’aprovar. 0 = sense cerimònia per a qui pot editar preus.',
          )}
        </span>
      </label>
    </section>
  )
}
