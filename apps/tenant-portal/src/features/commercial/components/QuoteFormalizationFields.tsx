import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router-dom'
import type { DocumentTemplateWithLocales } from '@/features/signing/api/signingService'
import { useTenant } from '@/contexts/TenantContext'
import { useEffectiveSettings } from '@/hooks/useSettings'
import {
  COMMERCIAL_QUOTE_TEMPLATE_ID_KEY,
  FORMALIZATION_MODES,
  resolveActiveCommercialFullBodyTemplateId,
  type FormalizationMode,
} from '../utils/deviationApprovalThreshold'
import { QUOTE_TEMPLATES_HREF, commercialTemplatesHref } from '../utils/commercialTemplatePaths'
import { DocumentTemplateSelect } from './AgreementTemplateSelect'
import { DocumentTemplatePreviewPane } from './DocumentTemplatePreviewPane'

interface QuoteFormalizationFieldsProps {
  mode: FormalizationMode
  templateId: string
  templates: DocumentTemplateWithLocales[]
  disabled?: boolean
  onModeChange: (mode: FormalizationMode) => void
  onTemplateChange: (templateId: string) => void
}

export function QuoteFormalizationFields({
  mode,
  templateId,
  templates,
  disabled,
  onModeChange,
  onTemplateChange,
}: QuoteFormalizationFieldsProps) {
  const { t } = useTranslation('projects')
  const { activeTenant } = useTenant()
  const { data: effective } = useEffectiveSettings(
    { tenantId: activeTenant?.id ?? '' },
    { enabled: !!activeTenant?.id },
  )

  const quoteTemplates = useMemo(
    () =>
      templates.filter(
        (tpl) =>
          tpl.category === 'quote' &&
          (tpl.template_type === 'html' || tpl.template_type === 'docx') &&
          !!tpl.id,
      ),
    [templates],
  )

  const activeTenantTemplateId = useMemo(
    () =>
      resolveActiveCommercialFullBodyTemplateId(
        effective,
        COMMERCIAL_QUOTE_TEMPLATE_ID_KEY,
        'quote',
        quoteTemplates.map((tpl) => ({
          id: tpl.id!,
          category: tpl.category,
          tenant_id: tpl.tenant_id,
          is_platform_default: tpl.is_platform_default,
          is_active: tpl.is_active,
          template_type: tpl.template_type,
          created_at: tpl.created_at,
        })),
        activeTenant?.id,
      ),
    [effective, quoteTemplates, activeTenant?.id],
  )

  const previewTemplateId = templateId || activeTenantTemplateId || ''
  const previewTemplate = useMemo(
    () => quoteTemplates.find((tpl) => tpl.id === previewTemplateId) ?? null,
    [quoteTemplates, previewTemplateId],
  )

  return (
    <div className="space-y-3">
      <label className="flex flex-col gap-1.5">
        <span className="text-sm font-medium">
          {t('projects.commercial.formalization_label', 'Formalització')}
        </span>
        <select
          className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm"
          value={mode}
          disabled={disabled}
          onChange={(e) => onModeChange(e.target.value as FormalizationMode)}
        >
          {FORMALIZATION_MODES.map((value) => (
            <option key={value} value={value}>
              {value === 'separate_agreement'
                ? t(
                    'projects.commercial.formalization_separate',
                    'Després d’acceptar, preparar contracte',
                  )
                : t(
                    'projects.commercial.formalization_signed',
                    'Un document: l’acceptació és el contracte',
                  )}
            </option>
          ))}
        </select>
        <span className="text-xs text-muted-foreground">
          {mode === 'separate_agreement'
            ? t(
                'projects.commercial.formalization_separate_help',
                'El pressupost queda com a annex. El contracte es prepara després, amb una segona firma. Acceptar no el crea sol.',
              )
            : t(
                'projects.commercial.formalization_signed_help',
                'El pressupost acceptat és l’encàrrec. No es generarà un segon document.',
              )}
        </span>
      </label>

      <div className="space-y-2">
        <span className="text-sm font-medium">
          {t('projects.commercial.formalization_template', 'Plantilla d’aquest pressupost')}
        </span>
        <DocumentTemplateSelect
          templates={quoteTemplates.map((tpl) => ({
            id: tpl.id!,
            name: tpl.name,
            is_platform_default: tpl.is_platform_default,
            template_type: tpl.template_type,
            default_block_mapping:
              (tpl.default_block_mapping as Record<string, string> | null | undefined) ?? null,
          }))}
          value={templateId}
          onChange={onTemplateChange}
          disabled={disabled}
          emptyOptionLabel={t(
            'projects.commercial.formalization_template_default',
            'La plantilla activa del tenant',
          )}
          noTemplatesLabel={t(
            'projects.quotes.create_no_quote_template',
            'No hi ha plantilles de pressupost pròpies',
          )}
          searchPlaceholder={t(
            'projects.quotes.create_template_search',
            'Cerca plantilla de pressupost…',
          )}
          pickerTitle={t('projects.quotes.template_picker_title', 'Plantilla de pressupost')}
          pickerDescription={t(
            'projects.quotes.template_picker_help',
            'Cerca i previsualitza la plantilla que s’usarà per a aquest pressupost.',
          )}
          emptyPreviewTemplateId={activeTenantTemplateId}
          emptyPreviewMessage={
            activeTenantTemplateId
              ? t(
                  'projects.commercial.template_preview_tenant_default_resolved',
                  'Aquesta és la plantilla activa del tenant que s’usarà si no en tries cap altra.',
                )
              : t(
                  'projects.commercial.template_preview_tenant_default_system',
                  'No hi ha plantilla full-body activa: s’usarà el format per defecte del sistema.',
                )
          }
          emptySystemDefaultDocType="quote"
        />
        <span className="text-xs text-muted-foreground">
          <Link to={QUOTE_TEMPLATES_HREF} className="text-indigo-600 hover:underline">
            {t('projects.quotes.manage_templates', 'Gestionar plantilles')}
          </Link>
          {' · '}
          <Link
            to={commercialTemplatesHref('quote', { create: true })}
            className="text-indigo-600 hover:underline"
          >
            {t('projects.quotes.templates_new', 'Nova plantilla')}
          </Link>
        </span>

        <div className="space-y-1.5 pt-1">
          <p className="text-xs font-medium text-muted-foreground">
            {t('projects.commercial.template_preview_label', 'Vista prèvia')}
            {previewTemplate?.name ? `: ${previewTemplate.name}` : ''}
            {!templateId && activeTenantTemplateId
              ? ` (${t('projects.commercial.template_preview_active_badge', 'activa del tenant')})`
              : ''}
            {!templateId && !activeTenantTemplateId
              ? ` (${t('projects.commercial.template_preview_system_badge', 'format sistema')})`
              : ''}
          </p>
          <DocumentTemplatePreviewPane
            templateId={previewTemplateId || null}
            templateType={previewTemplate?.template_type}
            blockMapping={
              (previewTemplate?.default_block_mapping as
                | Record<string, string>
                | null
                | undefined) ?? null
            }
            systemDefaultDocType={!previewTemplateId ? 'quote' : null}
            compact
          />
        </div>
      </div>
    </div>
  )
}
